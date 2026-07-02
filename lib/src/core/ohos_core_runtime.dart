part of 'core_lifecycle_service.dart';

class OhosCoreRuntime extends AndroidCoreRuntime {
  OhosCoreRuntime({
    super.methodChannel,
    super.eventChannel,
    @visibleForTesting super.vpnRouteRefreshFastInterval,
    @visibleForTesting super.vpnRouteRefreshSteadyInterval,
    @visibleForTesting super.vpnRouteRefreshFastLimit,
  }) : super(platformLabel: 'HarmonyOS', fallbackHostname: 'harmony-device');
}
