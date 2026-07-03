part of 'core_lifecycle_service.dart';

class OhosCoreRuntime extends AndroidCoreRuntime {
  OhosCoreRuntime({
    super.methodChannel,
    super.eventChannel,
    @visibleForTesting super.vpnRouteRefreshFastInterval,
    @visibleForTesting super.vpnRouteRefreshSteadyInterval,
    @visibleForTesting super.vpnRouteRefreshFastLimit,
  }) : super(platformLabel: 'HarmonyOS', fallbackHostname: 'harmony-device');

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

    final vpnPrepared = await _prepareVpn();
    _vpnPrepared = vpnPrepared;
    if (!vpnPrepared) {
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
    unawaited(_startPendingVpns());

    return CoreRuntimeStartResult(
      phase: CoreRunPhase.running,
      message: 'HarmonyOS 连接引擎运行中',
      machineId: machineId,
      details: 'EasyTier ${bootstrap.version}',
      coreVersion: bootstrap.version,
    );
  }
}
