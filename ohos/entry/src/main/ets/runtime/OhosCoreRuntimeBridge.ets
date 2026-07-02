import { Context, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { vpnExtension } from '@kit.NetworkKit';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

const METHOD_CHANNEL_NAME = 'net.easytier.pro/core_runtime';
const BUNDLE_NAME = 'net.easytier.pro';
const VPN_ABILITY_NAME = 'EasyTierVpnAbility';
const PREFERENCES_NAME = 'EasyTierProCoreRuntime';
const MACHINE_ID_KEY = 'machine_id';

export default class OhosCoreRuntimeBridge implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: Context | null = null;
  private configServerClientConnected: boolean = false;
  private lastError: string = '';

  getUniqueClassName(): string {
    return 'OhosCoreRuntimeBridge';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      switch (call.method) {
        case 'getMachineId':
          result.success(this.getMachineId());
          return;
        case 'getHostname':
          result.success(this.getHostname());
          return;
        case 'startConfigServerClient':
          this.configServerClientConnected = true;
          result.success(null);
          return;
        case 'stopConfigServerClient':
          this.configServerClientConnected = false;
          result.success(null);
          return;
        case 'stopRuntime':
          this.configServerClientConnected = false;
          result.success(null);
          return;
        case 'isConfigServerClientConnected':
          result.success(this.configServerClientConnected);
          return;
        case 'listInstances':
          result.success('{}');
          return;
        case 'callJsonRpc':
          result.success('{}');
          return;
        case 'retainNetworkInstance':
        case 'stopNetworkInstances':
        case 'stopVpn':
          result.success(null);
          return;
        case 'prepareNotifications':
          result.success(true);
          return;
        case 'prepareVpn':
          this.prepareVpn(result);
          return;
        case 'startVpn':
          this.lastError = 'HarmonyOS EasyTier-Core VPN bridge is not connected yet';
          result.success(null);
          return;
        case 'shareFile':
          result.success(false);
          return;
        case 'getLastError':
          result.success(this.lastError);
          return;
        default:
          result.notImplemented();
      }
    } catch (error) {
      this.lastError = `${error}`;
      result.error('OHOS_RUNTIME_ERROR', this.lastError, null);
    }
  }

  private getMachineId(): string {
    if (this.context === null) {
      return `harmony-${util.generateRandomUUID()}`;
    }
    const store = preferences.getPreferencesSync(this.context, { name: PREFERENCES_NAME });
    const existing = `${store.getSync(MACHINE_ID_KEY, '')}`;
    if (existing.length > 0) {
      return existing;
    }
    const machineId = `harmony-${util.generateRandomUUID()}`;
    store.putSync(MACHINE_ID_KEY, machineId);
    store.flushSync();
    return machineId;
  }

  private getHostname(): string {
    const deviceName = deviceInfo.marketName || deviceInfo.productModel || deviceInfo.deviceType;
    return deviceName.length > 0 ? deviceName : 'HarmonyOS';
  }

  private prepareVpn(result: MethodResult): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.startVpnExtensionAbility(want)
      .then(() => vpnExtension.stopVpnExtensionAbility(want))
      .then(() => {
        result.success(true);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS VPN permission failed: ${error.message ?? JSON.stringify(error)}`;
        result.success(false);
      });
  }
}
