part of 'core_lifecycle_service.dart';

/// Native runtime state reported by the HarmonyOS VPN Extension through the
/// `getRuntimeSnapshot` request and the `runtime_snapshot` event.
///
/// The Extension owns TUN startup, retention and route refresh in its own
/// process, so a snapshot is the only evidence a new or resumed UI session has
/// about the runtime that outlived its frozen predecessor.
class OhosRuntimeSnapshot {
  const OhosRuntimeSnapshot({
    required this.configServerConnected,
    required this.activeVpnInstanceName,
    required this.activeVpnInstanceId,
    required this.instances,
  });

  /// Parses the snapshot JSON contract, either still encoded or already
  /// decoded. Returns `null` when the payload cannot be trusted (no
  /// control-plane flag), so callers keep the runtime state unknown instead of
  /// reading a broken payload as a stopped runtime.
  static OhosRuntimeSnapshot? parse(Object? value) {
    final map = CoreJsonValue.readMap(value);
    if (map == null) {
      return null;
    }
    final connected = map['configServerConnected'];
    if (connected is! bool) {
      return null;
    }
    return OhosRuntimeSnapshot(
      configServerConnected: connected,
      activeVpnInstanceName: CoreJsonValue.readString(
        map['activeVpnInstanceName'],
      ),
      activeVpnInstanceId: CoreJsonValue.readString(map['activeVpnInstanceId']),
      instances: Map.unmodifiable(_readInstanceAliases(map['instances'])),
    );
  }

  /// Whether the native config server (control plane) client is connected.
  final bool configServerConnected;

  /// Instance whose TUN is attached right now; empty when none is.
  final String activeVpnInstanceName;

  /// Core instance id backing [activeVpnInstanceName].
  final String activeVpnInstanceId;

  /// Runtime/network label to Core instance id, the authoritative instance map
  /// of the native runtime.
  final Map<String, String> instances;

  static Map<String, String> _readInstanceAliases(Object? value) {
    final aliases = <String, String>{};
    final map = CoreJsonValue.readMap(value);
    if (map == null) {
      return aliases;
    }
    for (final entry in map.entries) {
      final label = entry.key.trim();
      final instanceId = CoreJsonValue.readScalarString(entry.value) ?? '';
      if (label.isNotEmpty && instanceId.isNotEmpty) {
        aliases[label] = instanceId;
      }
    }
    return aliases;
  }
}

class OhosCoreRuntime extends AndroidCoreRuntime {
  OhosCoreRuntime({super.methodChannel, super.eventChannel})
    : super(platformLabel: 'HarmonyOS', fallbackHostname: 'harmony-device');

  /// The `runtime_snapshot` event carries the same JSON document as the
  /// `getRuntimeSnapshot` request.
  static const String _runtimeSnapshotEvent = 'runtime_snapshot';

  /// The VPN Extension runs in its own process and owns TUN, so this process
  /// never starts, retains or re-routes an interface.
  @override
  bool get drivesVpnInterfaceFromUi => false;

  /// A resume never restarts the native control session: the Extension keeps
  /// running while this process is frozen. The snapshot reconnects the
  /// transport; only an authoritative disconnected snapshot asks for a
  /// reconnect, while a snapshot that cannot be read stays an observable error
  /// and leaves the native side alone.
  @override
  Future<bool> shouldRecoverAfterAppResume() async {
    final OhosRuntimeSnapshot? snapshot;
    try {
      snapshot = await _readSnapshot();
    } on Object catch (error) {
      _emitUnknownStateError(error);
      return false;
    }
    _applySnapshot(snapshot);
    return !snapshot.configServerConnected;
  }

  @override
  Future<CoreRuntimeStartResult?> readStatus(
    CoreBootstrapConfig bootstrap,
  ) async {
    final OhosRuntimeSnapshot snapshot;
    try {
      snapshot = await _readSnapshot();
    } on Object catch (error) {
      // Unreadable means unknown: neither stopped nor failed. Ensuring the
      // runtime again cannot tear down a healthy child, because the Extension
      // ignores a repeated start of the same bootstrap, so nothing is at risk
      // by letting the caller continue with an unknown runtime.
      _emitUnknownStateError(error);
      return null;
    }
    _applySnapshot(snapshot);
    if (!snapshot.configServerConnected) {
      return null;
    }
    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'HarmonyOS 连接引擎运行中',
      machineId: await _getMachineId(),
      details: 'EasyTier ${bootstrap.version}',
      coreVersion: bootstrap.version,
    );
  }

  @override
  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  }) async {
    if (forceReinstall) {
      await stop();
    }

    final machineId = await _getMachineId();
    final hostname = await _getHostname();
    final fullUrl = AndroidCoreRuntime.buildConfigServerClientUrl(
      bootstrap.configServer,
      bootstrap.bootstrapToken,
    );

    await _prepareNotifications();

    if (!await _prepareVpn()) {
      return CoreRuntimeStartResult(
        phase: CoreRunPhase.needsVpnPermission,
        message: '需要授权 VPN 连接',
        machineId: machineId,
        details: 'EasyTier ${bootstrap.version}',
        lastError: 'HarmonyOS 需要用户授权后才能启动 VPN Extension',
        coreVersion: bootstrap.version,
      );
    }

    await _methodChannel.invokeMethod<void>('startConfigServerClient', {
      'url': fullUrl,
      'hostname': hostname,
      'machineId': machineId,
      'secureMode': true,
    });

    // Starting the control session is all this process owes the runtime: the
    // Extension brings TUN up for whatever that session owns, so no instance
    // VPN is started from here. A snapshot that cannot be read yet leaves the
    // identity unknown, which is not a failed start.
    try {
      _applySnapshot(await _readSnapshot());
    } on Object catch (error) {
      _emitUnknownStateError(error);
    }

    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'HarmonyOS 连接引擎运行中',
      machineId: machineId,
      details: 'EasyTier ${bootstrap.version}',
      coreVersion: bootstrap.version,
    );
  }

  /// Suspends the native tunnel while the user leaves a network. The Extension
  /// owns the interface, so the stop is a native request — and it must be sent
  /// even when this process lost the active-VPN state to a frozen or recreated
  /// UI, because the native suspension is idempotent.
  @override
  Future<void> preemptActiveVpnForExit() async {
    _activeVpnInstanceName = null;
    _activeVpnInstanceId = null;
    _activeVpnConfigSignature = null;
    _activeVpnFallbackConfig = null;
    await _methodChannel.invokeMethod<void>('stopVpn');
  }

  /// Lifts the suspension after a failed exit. The native side reconciles the
  /// current Core state itself, so no VPN config of this process is replayed.
  @override
  Future<void> restoreActiveVpnAfterFailedExit() async {
    await _methodChannel.invokeMethod<void>('resumeVpn');
  }

  @override
  void _handlePlatformRuntimeEvent(CoreRuntimeEvent event) {
    if (event.type == CoreRuntimeEventTypes.vpnPermissionDenied ||
        event.type == CoreRuntimeEventTypes.configServerStopped) {
      // The native runtime is gone: this process resolves its identity from the
      // next snapshot instead of trusting pre-freeze events.
      return;
    }
    if (event.type != _runtimeSnapshotEvent) {
      return;
    }
    final snapshot = OhosRuntimeSnapshot.parse(
      event.data['payload'] ?? event.data,
    );
    if (snapshot == null) {
      return;
    }
    _applySnapshot(snapshot);
  }

  /// Reads the snapshot, or throws when the native runtime is unreachable or
  /// answers with something that is not a snapshot.
  Future<OhosRuntimeSnapshot> _readSnapshot() async {
    final snapshot = OhosRuntimeSnapshot.parse(
      await _methodChannel.invokeMethod<Object?>('getRuntimeSnapshot'),
    );
    if (snapshot == null) {
      throw StateError('HarmonyOS 运行状态快照不可用');
    }
    return snapshot;
  }

  /// Unknown state is reported as [CoreRuntimeEventTypes.runtimeUnknown]: the
  /// native runtime may still be healthy, so this must never be published as a
  /// failure that asks for a restart.
  void _emitUnknownStateError(Object error) {
    if (_disposed) {
      return;
    }
    _events.add(
      CoreRuntimeEvent(
        type: CoreRuntimeEventTypes.runtimeUnknown,
        data: {
          'error': 'HarmonyOS 运行状态未知：$error',
          'source': 'getRuntimeSnapshot',
        },
      ),
    );
  }

  void _applySnapshot(OhosRuntimeSnapshot snapshot) {
    _activeVpnInstanceName = snapshot.activeVpnInstanceName.isEmpty
        ? null
        : snapshot.activeVpnInstanceName;
    _activeVpnInstanceId = snapshot.activeVpnInstanceId.isEmpty
        ? null
        : snapshot.activeVpnInstanceId;
    // The Extension re-reads the current Core state for every tunnel change, so
    // this process keeps no VPN config that a later change could replay stale.
    _activeVpnConfigSignature = null;
    _activeVpnFallbackConfig = null;
    // The instance map of the snapshot is authoritative: rebuild the runtime
    // label aliases from it and drop name aliases that events taught before a
    // frozen UI, so a label can never resolve through an obsolete network.
    _instanceIdsByRuntimeName
      ..clear()
      ..addAll(snapshot.instances);
    _instanceNamesByRuntimeName.clear();
  }
}
