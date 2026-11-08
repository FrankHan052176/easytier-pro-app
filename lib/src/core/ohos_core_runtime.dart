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
    required this.vpnConfigAddresses,
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
      vpnConfigAddresses: _readVpnAddresses(map['vpnConfig']),
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

  /// Addresses installed on the interface the snapshot reports as attached.
  /// Empty while no interface is attached.
  final List<String> vpnConfigAddresses;

  static List<String> _readVpnAddresses(Object? value) {
    final config = CoreJsonValue.readMap(value);
    return CoreJsonValue.readStringList(config?['addresses']);
  }

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

  /// The OS starts the Extension in its own process as the result of the
  /// grant, so the permission phase can be reported before the Extension's IPC
  /// is reachable and before the control session it owns exists: a resume must
  /// re-check the snapshot instead of treating that phase as terminal. An
  /// unreachable snapshot keeps the reported phase unchanged, which is also the
  /// outcome a refused authorization produces.
  @override
  bool get supportsVpnPermissionResumeRecovery => true;

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
    if (!snapshot.configServerConnected) {
      return true;
    }
    _emitSnapshotRecoveredTunnel(snapshot);
    return false;
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
    // A successful prepare is the same permission evidence Android records in
    // its start path; the join wait relies on it.
    _vpnPrepared = true;

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

  /// Waits for the Extension snapshot to report this network's interface.
  ///
  /// The shared Android implementation waits for the console node's instance
  /// id and re-reads the interface through JSON-RPC. On HarmonyOS the console
  /// assignment and the local runtime are decoupled, so that match can time out
  /// even though the Extension already attached the correct TUN. The snapshot
  /// names the attached instance and the addresses it installed, which is the
  /// local data path the caller needs.
  @override
  Future<String?> waitForNetworkConnection(
    String runtimeNetworkName, {
    required Future<String?> Function() readInstanceId,
  }) async {
    final networkName = runtimeNetworkName.trim();
    if (networkName.isEmpty) {
      return null;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    String? consoleInstanceId;
    var readConsoleId = false;
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed || !_vpnPrepared) {
        throw StateError('HarmonyOS VPN 未获得授权或已停止');
      }
      final OhosRuntimeSnapshot snapshot;
      try {
        snapshot = await _readSnapshot();
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      _applySnapshot(snapshot);
      final activeId = snapshot.activeVpnInstanceId.trim();
      var expectedId = snapshot.instances[networkName] ?? '';
      if (expectedId.isEmpty && !readConsoleId) {
        readConsoleId = true;
        try {
          consoleInstanceId = (await readInstanceId())?.trim();
        } on Object {
          consoleInstanceId = null;
        }
        expectedId = consoleInstanceId ?? '';
      } else if (expectedId.isEmpty && consoleInstanceId != null) {
        expectedId = consoleInstanceId;
      }
      final attached =
          activeId.isNotEmpty &&
          (snapshot.activeVpnInstanceName == networkName ||
              (expectedId.isNotEmpty && activeId == expectedId));
      if (attached) {
        for (final cidr in snapshot.vpnConfigAddresses) {
          final address = cidr.split('/').first.trim();
          if (address.isNotEmpty) {
            return address;
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('等待 HarmonyOS 网络接入 VPN 超时');
  }

  @override
  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName) async {
    final networkName = runtimeNetworkName.trim();
    if (networkName.isEmpty) {
      return false;
    }
    try {
      final snapshot = await _readSnapshot();
      _applySnapshot(snapshot);
      final activeId = snapshot.activeVpnInstanceId.trim();
      if (activeId.isEmpty || snapshot.vpnConfigAddresses.isEmpty) {
        return false;
      }
      final expectedId = snapshot.instances[networkName] ?? '';
      return snapshot.activeVpnInstanceName == networkName ||
          (expectedId.isNotEmpty && activeId == expectedId);
    } on Object {
      return false;
    }
  }

  /// Suspends the native tunnel while the user leaves a network. The Extension
  /// owns the interface, so the stop is a native request — and it must be sent
  /// even when this process lost the active-VPN state to a frozen or recreated
  /// UI, because the native suspension is idempotent.
  @override
  Future<void> preemptActiveVpnForExit() async {
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

  /// Reports the tunnel the snapshot proves is attached right now.
  ///
  /// A connected control client on its own says nothing about the interface, so
  /// this needs the Extension's authoritative identity for the instance whose
  /// TUN is attached. The Extension can bring the interface back after a
  /// failure whose `vpn_started` was lost with the frozen process; without this
  /// event the UI would keep that stale failure forever. A disconnected
  /// control plane still belongs to the reconnect path of
  /// [shouldRecoverAfterAppResume], and a snapshot without an attached tunnel
  /// leaves the reported failure in place.
  void _emitSnapshotRecoveredTunnel(OhosRuntimeSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    final instanceName = snapshot.activeVpnInstanceName;
    final instanceId = snapshot.activeVpnInstanceId;
    if (instanceName.isEmpty || instanceId.isEmpty) {
      return;
    }
    _events.add(
      CoreRuntimeEvent(
        type: CoreRuntimeEventTypes.vpnRecoveredFromSnapshot,
        data: {
          'instance_name': instanceName,
          'instance_id': instanceId,
          // The lifecycle helper owns the status text of a recovered runtime,
          // and this runtime owns its platform wording.
          'message': 'HarmonyOS 连接引擎运行中',
          'source': 'getRuntimeSnapshot',
        },
      ),
    );
  }

  /// Reports the interface the Extension owns in the shape the shared Android
  /// readiness code consumes. The Android method channel has `getVpnState`,
  /// but HarmonyOS keeps that state in the authoritative runtime snapshot;
  /// asking the bridge for it would only produce a MissingPluginException.
  @override
  Future<Map<String, Object?>> _readVpnState() async {
    try {
      final snapshot = await _readSnapshot();
      _applySnapshot(snapshot);
      final activeId = snapshot.activeVpnInstanceId.trim();
      return <String, Object?>{
        'instance_ids': activeId.isEmpty ? const <String>[] : <String>[activeId],
        'addresses': snapshot.vpnConfigAddresses,
      };
    } on Object {
      return const <String, Object?>{};
    }
  }

  void _applySnapshot(OhosRuntimeSnapshot snapshot) {
    // The Extension re-reads the current Core state for every tunnel change, so
    // this process keeps no VPN config that a later change could replay stale.
    // The instance map of the snapshot is authoritative: rebuild the runtime
    // label aliases from it and drop name aliases that events taught before a
    // frozen UI, so a label can never resolve through an obsolete network.
    _instanceIdsByRuntimeName
      ..clear()
      ..addAll(snapshot.instances);
    _instanceNamesByRuntimeName.clear();
  }
}
