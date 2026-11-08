part of 'core_lifecycle_service.dart';

abstract class CorePlatformRuntime {
  const CorePlatformRuntime();

  factory CorePlatformRuntime.current(CoreLifecycleService owner) {
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidCoreRuntime();
    }
    if (!kIsWeb && Platform.operatingSystem == 'ohos') {
      return OhosCoreRuntime();
    }
    if (!kIsWeb && Platform.isIOS) {
      return IosCoreRuntime();
    }
    return DesktopCoreRuntime(owner);
  }

  bool get supportsElevationRepair => false;

  /// Whether this process drives the VPN interface itself. A platform whose
  /// tunnel is owned by a separate extension reports false so shared runtime
  /// event handling does not try to start or stop it here.
  bool get drivesVpnInterfaceFromUi => true;

  /// Whether a resume may still recover a runtime whose reported phase is
  /// [CoreRunPhase.needsVpnPermission]. A platform whose authorization is
  /// applied outside this process can report that phase before its runtime is
  /// reachable, so the phase must not stay terminal there.
  bool get supportsVpnPermissionResumeRecovery => false;

  /// Re-checks the native runtime after the app resumes. Returns true when the
  /// caller must re-drive the connection.
  Future<bool> shouldRecoverAfterAppResume() async => false;

  /// Extension point for runtime events whose state lives outside the shared
  /// Android VPN state machine.
  void _handlePlatformRuntimeEvent(CoreRuntimeEvent event) {}

  Duration get networkTrafficPollInterval => const Duration(seconds: 2);

  Duration get peerStatusPollInterval => const Duration(seconds: 5);

  Stream<CoreRuntimeEvent> get events => const Stream<CoreRuntimeEvent>.empty();

  Future<CoreRuntimeStartResult?> readStatus(CoreBootstrapConfig bootstrap);

  Future<CoreRuntimeStartResult> ensureRunning(
    CoreBootstrapConfig bootstrap, {
    required bool forceReinstall,
  });

  Future<String?> readInstalledVersion() async => null;

  Future<bool> shouldUninstallBeforeElevatedInstall(
    CoreBootstrapConfig bootstrap,
  ) async {
    return false;
  }

  Future<void> stop();

  /// Tears the active VPN interface down before the control plane confirms a
  /// network exit; no-op on platforms without a managed VPN interface.
  Future<void> preemptActiveVpnForExit() async {}

  /// Brings back the interface [preemptActiveVpnForExit] took down when that
  /// exit turned out to fail.
  Future<void> restoreActiveVpnAfterFailedExit() async {}

  Future<void> beginNetworkConnection() async {}

  Future<String?> waitForNetworkConnection(
    String runtimeNetworkName, {
    required Future<String?> Function() readInstanceId,
  }) async => null;

  Future<void> endNetworkConnection() async {}

  Future<Map<String, CoreNetworkTrafficTotals>> readNetworkTrafficTotals();

  Future<bool> isNetworkInstanceRunning(String runtimeNetworkName);

  Future<Map<String, CorePeerStatus>> readNetworkPeerStatuses(
    String runtimeNetworkName,
  );

  Future<void> dispose() async {}
}

class CoreRuntimeStartResult {
  const CoreRuntimeStartResult({
    required this.phase,
    required this.message,
    this.machineId,
    this.details,
    this.lastError,
    this.coreVersion,
  });

  final CoreRunPhase phase;
  final String message;
  final String? machineId;
  final String? details;
  final String? lastError;
  final String? coreVersion;

  CoreRunStatus toStatus() {
    return CoreRunStatus(
      phase: phase,
      message: message,
      machineId: machineId,
      details: details,
      lastError: lastError,
    );
  }
}

class CoreRuntimeEvent {
  const CoreRuntimeEvent({
    required this.type,
    this.data = const <String, Object?>{},
  });

  final String type;
  final Map<String, Object?> data;
}

class CoreRuntimeEventTypes {
  const CoreRuntimeEventTypes._();

  static const String vpnPermissionGranted = 'vpn_permission_granted';
  static const String vpnPermissionDenied = 'vpn_permission_denied';
  static const String vpnStarted = 'vpn_started';
  static const String vpnStopped = 'vpn_stopped';
  static const String vpnConfigRefreshed = 'vpn_config_refreshed';
  static const String vpnRouteDiagnostic = 'vpn_route_diagnostic';
  static const String notificationPermissionGranted =
      'notification_permission_granted';
  static const String notificationPermissionDenied =
      'notification_permission_denied';
  static const String configServer = 'config_server';
  static const String configServerStarted = 'config_server_started';
  static const String configServerStopped = 'config_server_stopped';
  static const String error = 'error';

  /// An authoritative runtime snapshot reported an attached tunnel that this
  /// process never observed starting: the native side recovered on its own
  /// while the UI was frozen, so the lifecycle reconciles its failure state
  /// from that snapshot instead of replaying the `vpn_started` event the
  /// frozen process never received.
  static const String vpnRecoveredFromSnapshot = 'vpn_recovered_from_snapshot';

  /// The runtime could not be read: its state is unknown. That is not a
  /// failure, so it must not move the UI into an error phase.
  static const String runtimeUnknown = 'runtime_unknown';
}
