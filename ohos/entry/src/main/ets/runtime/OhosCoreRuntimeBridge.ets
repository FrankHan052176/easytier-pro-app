import { common, Context, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { vpnExtension } from '@kit.NetworkKit';
import {
  AbilityAware,
  AbilityPluginBinding,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler,
} from '@ohos/flutter_ohos';
import {
  RuntimeIpcClient,
  RuntimeParams,
  RuntimeValue,
  RuntimeVpnConfig,
  runtimeSocketPath,
} from './OhosCoreRuntimeIpc';

const METHOD_CHANNEL_NAME = 'net.easytier.pro/core_runtime';
const EVENT_CHANNEL_NAME = 'net.easytier.pro/core_runtime_events';
const BUNDLE_NAME = 'net.easytier.pro';
const VPN_ABILITY_NAME = 'EasyTierVpnAbility';
const PREFERENCES_NAME = 'EasyTierProCoreRuntime';
const MACHINE_ID_KEY = 'machine_id';
const MACHINE_ID_UUID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

class RuntimeEvent {
  type: string;
  payload: RuntimeValue;

  constructor(type: string, payload: RuntimeValue) {
    this.type = type;
    this.payload = payload;
  }
}

class EmptyPayload {
}

class ErrorPayload {
  error: string;

  constructor(error: string) {
    this.error = error;
  }
}

class ConfigServerStartedPayload {
  url: string;
  hostname: string;
  machine_id: string;

  constructor(url: string, hostname: string, machineId: string) {
    this.url = url;
    this.hostname = hostname;
    this.machine_id = machineId;
  }
}

class DetachedStreamHandler implements StreamHandler {
  onListen(args: Object, events: EventSink): void {
    events.endOfStream();
  }

  onCancel(args: Object): void {
  }
}

export default class OhosCoreRuntimeBridge implements FlutterPlugin, MethodCallHandler, StreamHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private context: Context | null = null;
  private abilityContext: common.UIAbilityContext | null = null;
  private lastError: string = '';
  private runtimeClient: RuntimeIpcClient = new RuntimeIpcClient((type: string, payload: RuntimeValue) => {
    this.emitEvent(type, payload);
  });

  getUniqueClassName(): string {
    return 'OhosCoreRuntimeBridge';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL_NAME);
    this.eventChannel.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.runtimeClient.close();
    this.channel?.setMethodCallHandler(null);
    this.eventChannel?.setStreamHandler(new DetachedStreamHandler());
    this.channel = null;
    this.eventChannel = null;
    this.eventSink = null;
    this.context = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityContext = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.abilityContext = null;
  }

  onListen(args: Object, events: EventSink): void {
    this.eventSink = events;
  }

  onCancel(args: Object): void {
    this.eventSink = null;
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
          this.startConfigServerClient(call, result);
          return;
        case 'stopConfigServerClient':
          this.forwardRuntimeCall('stopConfigServerClient', new RuntimeParams(), result);
          return;
        case 'stopRuntime':
          this.stopRuntime(result);
          return;
        case 'isConfigServerClientConnected':
          this.forwardRuntimeCall('isConfigServerClientConnected', new RuntimeParams(), result, false);
          return;
        case 'listInstances':
          this.forwardRuntimeCall('listInstances', new RuntimeParams(), result, '{}');
          return;
        case 'callJsonRpc':
          this.forwardRuntimeCall('callJsonRpc', this.readJsonRpcParams(call), result, '{}');
          return;
        case 'retainNetworkInstance':
          result.success(null);
          return;
        case 'stopNetworkInstances':
          this.forwardRuntimeCall('stopNetworkInstances', this.readStopNetworkInstancesParams(call), result);
          return;
        case 'stopVpn':
          this.forwardRuntimeCall('stopVpn', new RuntimeParams(), result);
          return;
        case 'prepareNotifications':
          result.success(true);
          return;
        case 'prepareVpn':
          this.prepareVpn(result);
          return;
        case 'startVpn':
          this.forwardRuntimeCall('startVpn', this.readStartVpnParams(call), result);
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
      const message = this.errorMessage(error);
      this.lastError = message;
      result.error('OHOS_RUNTIME_ERROR', message, null);
    }
  }

  private startConfigServerClient(call: MethodCall, result: MethodResult): void {
    const url = this.readStringArgument(call, 'url');
    const hostname = this.readStringArgument(call, 'hostname');
    const machineId = this.readStringArgument(call, 'machineId');
    const secureMode = this.readBoolArgument(call, 'secureMode');
    const filesDir = this.filesDir();
    if (filesDir.length === 0) {
      this.lastError = 'HarmonyOS filesDir is unavailable';
      result.error('OHOS_RUNTIME_CONTEXT_MISSING', this.lastError, null);
      return;
    }
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        url,
        hostname,
        machineId,
        secureMode,
        socketFilesDir: filesDir,
      },
    };
    vpnExtension.startVpnExtensionAbility(want)
      .then(() => this.runtimeClient.connect(runtimeSocketPath(filesDir)))
      .then(() => {
        this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
        result.success(null);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS EasyTier VPN extension start failed: ${this.errorMessage(error)}`;
        result.error('OHOS_CORE_START_FAILED', this.lastError, null);
      });
  }

  private stopRuntime(result: MethodResult): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
    };
    const stopCore = this.runtimeClient.isConnected()
      ? this.runtimeClient.request('stopRuntime', new RuntimeParams()).catch((_error: Error) => null)
      : Promise.resolve(null);
    stopCore
      .then(() => vpnExtension.stopVpnExtensionAbility(want))
      .then(() => {
        this.runtimeClient.close();
        this.emitEvent('config_server_stopped', new EmptyPayload());
        result.success(null);
      })
      .catch((error: Error) => {
        this.runtimeClient.close();
        this.lastError = this.errorMessage(error);
        result.error('OHOS_RUNTIME_STOP_FAILED', this.lastError, null);
      });
  }

  private prepareVpn(result: MethodResult): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.startVpnExtensionAbility(want)
      .then(() => vpnExtension.stopVpnExtensionAbility(want))
      .then(() => {
        this.emitEvent('vpn_permission_granted', new EmptyPayload());
        result.success(true);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS VPN permission failed: ${this.errorMessage(error)}`;
        this.emitEvent('vpn_permission_denied', new ErrorPayload(this.lastError));
        result.success(false);
      });
  }

  private forwardRuntimeCall(
    method: string,
    params: RuntimeParams,
    result: MethodResult,
    fallback?: RuntimeValue,
  ): void {
    if (!this.runtimeClient.isConnected()) {
      const filesDir = this.filesDir();
      if (filesDir.length > 0) {
        this.runtimeClient.connect(runtimeSocketPath(filesDir))
          .then(() => this.forwardRuntimeCall(method, params, result, fallback))
          .catch((error: Error) => this.completeRuntimeFailure(method, error, result, fallback));
        return;
      }
    }
    this.runtimeClient.request(method, params)
      .then((value: RuntimeValue) => {
        result.success(value);
      })
      .catch((error: Error) => this.completeRuntimeFailure(method, error, result, fallback));
  }

  private completeRuntimeFailure(method: string, error: Error, result: MethodResult, fallback?: RuntimeValue): void {
    this.lastError = this.errorMessage(error);
    if (fallback !== undefined) {
      result.success(fallback);
      return;
    }
    result.error('OHOS_RUNTIME_IPC_FAILED', `HarmonyOS core runtime ${method} failed: ${this.lastError}`, null);
  }

  private emitEvent(type: string, payload: RuntimeValue): void {
    this.eventSink?.success(new RuntimeEvent(type, payload));
  }

  private getMachineId(): string {
    if (this.context === null) {
      return util.generateRandomUUID().toLowerCase();
    }
    const store = preferences.getPreferencesSync(this.context, { name: PREFERENCES_NAME });
    const existing = `${store.getSync(MACHINE_ID_KEY, '')}`;
    if (MACHINE_ID_UUID_PATTERN.test(existing)) {
      return existing.toLowerCase();
    }
    const machineId = util.generateRandomUUID().toLowerCase();
    store.putSync(MACHINE_ID_KEY, machineId);
    store.flushSync();
    return machineId;
  }

  private getHostname(): string {
    const deviceName = deviceInfo.marketName || deviceInfo.productModel || deviceInfo.deviceType;
    return deviceName.length > 0 ? deviceName : 'HarmonyOS';
  }

  private filesDir(): string {
    return this.context?.filesDir ?? this.abilityContext?.filesDir ?? '';
  }

  private readStringArgument(call: MethodCall, key: string): string {
    const value: Object | null = call.argument(key) as Object | null;
    return value === null || value === undefined ? '' : `${value}`;
  }

  private readBoolArgument(call: MethodCall, key: string): boolean {
    const value: boolean | null = call.argument(key) as boolean | null;
    return value === true;
  }

  private readStringArrayArgument(call: MethodCall, key: string): Array<string> {
    const value = call.argument(key) as Array<string> | null;
    return value ?? [];
  }

  private readJsonRpcParams(call: MethodCall): RuntimeParams {
    const params = new RuntimeParams();
    params.serviceName = this.readStringArgument(call, 'serviceName');
    params.methodName = this.readStringArgument(call, 'methodName');
    params.domainName = this.readStringArgument(call, 'domainName');
    params.payloadJson = this.readStringArgument(call, 'payloadJson');
    return params;
  }

  private readStopNetworkInstancesParams(call: MethodCall): RuntimeParams {
    const params = new RuntimeParams();
    params.instanceNames = this.readStringArrayArgument(call, 'instanceNames');
    return params;
  }

  private readStartVpnParams(call: MethodCall): RuntimeParams {
    const params = new RuntimeParams();
    params.instanceName = this.readStringArgument(call, 'instanceName');
    params.vpnConfig = this.readVpnConfigArgument(call, 'vpnConfig');
    return params;
  }

  private readVpnConfigArgument(call: MethodCall, key: string): RuntimeVpnConfig {
    const configCall = new MethodCall(key, call.argument(key));
    const config = new RuntimeVpnConfig();
    config.addresses = this.readStringArrayArgument(configCall, 'addresses');
    config.address = this.readStringArgument(configCall, 'address');
    config.routes = this.readStringArrayArgument(configCall, 'routes');
    config.route = this.readStringArgument(configCall, 'route');
    config.dns = this.readStringArrayArgument(configCall, 'dns');
    config.dns_servers = this.readStringArrayArgument(configCall, 'dns_servers');
    config.dnsServers = this.readStringArrayArgument(configCall, 'dnsServers');
    config.disallowedApplications = this.readStringArrayArgument(configCall, 'disallowedApplications');
    config.disallowed_applications = this.readStringArrayArgument(configCall, 'disallowed_applications');
    config.disallowedPackages = this.readStringArrayArgument(configCall, 'disallowedPackages');
    config.disallowed_packages = this.readStringArrayArgument(configCall, 'disallowed_packages');
    config.mtu = this.readNumberArgument(configCall, 'mtu');
    return config;
  }

  private readNumberArgument(call: MethodCall, key: string): number {
    const value = call.argument(key) as Object | null;
    if (typeof value === 'number') {
      return value;
    }
    const parsed = Number.parseInt(`${value ?? ''}`, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  private errorMessage(error: Object): string {
    const typed = error as Error;
    return typed.message ?? `${error}`;
  }
}
