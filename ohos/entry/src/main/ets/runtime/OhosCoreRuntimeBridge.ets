import { common, Context, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { connection, vpnExtension } from '@kit.NetworkKit';
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
import easytier from 'easytier-ohrs';

const METHOD_CHANNEL_NAME = 'net.easytier.pro/core_runtime';
const EVENT_CHANNEL_NAME = 'net.easytier.pro/core_runtime_events';
const BUNDLE_NAME = 'net.easytier.pro';
const VPN_ABILITY_NAME = 'EasyTierVpnAbility';
const PREFERENCES_NAME = 'EasyTierProCoreRuntime';
const MACHINE_ID_KEY = 'machine_id';
const IPV4_FAMILY = 1;
const DEFAULT_MTU = 1380;
const DEFAULT_DNS = '223.5.5.5';
const EVENT_POLL_INTERVAL_MS = 500;
const MACHINE_ID_UUID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

interface CidrParts {
  address: string;
  prefix: number;
}

class RuntimeEvent {
  type: string;
  payload: Object;

  constructor(type: string, payload: Object) {
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

class VpnStartedPayload {
  instanceName: string;
  instance_name: string;
  instanceId: string;
  instance_id: string;
  fd: number;

  constructor(instanceName: string, instanceId: string, fd: number) {
    this.instanceName = instanceName;
    this.instance_name = instanceName;
    this.instanceId = instanceId;
    this.instance_id = instanceId;
    this.fd = fd;
  }
}

class VpnStoppedPayload {
  instanceName: string;
  instance_name: string;
  instanceId: string;
  instance_id: string;

  constructor(instanceName: string, instanceId: string) {
    this.instanceName = instanceName;
    this.instance_name = instanceName;
    this.instanceId = instanceId;
    this.instance_id = instanceId;
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
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private eventTimer: number | null = null;
  private lastError: string = '';
  private coreInitialized: boolean = false;
  private processNetProtected: boolean = false;
  private activeVpnInstanceId: string = '';
  private activeVpnInstanceName: string = '';

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
    this.stopEventPolling();
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
    this.startEventPolling();
  }

  onCancel(args: Object): void {
    this.eventSink = null;
    this.stopEventPolling();
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
          easytier.stopConfigServerClient();
          this.emitEvent('config_server_stopped', new EmptyPayload());
          result.success(null);
          return;
        case 'stopRuntime':
          this.stopRuntime(result);
          return;
        case 'isConfigServerClientConnected':
          result.success(easytier.isConfigServerClientConnected());
          return;
        case 'listInstances':
          result.success(easytier.listInstancesJson());
          return;
        case 'callJsonRpc':
          result.success(easytier.callJsonRpc(
            this.readStringArgument(call, 'serviceName'),
            this.readStringArgument(call, 'methodName'),
            this.readStringArgument(call, 'payloadJson'),
          ));
          return;
        case 'retainNetworkInstance':
          result.success(null);
          return;
        case 'stopNetworkInstances':
          this.stopNetworkInstances(call);
          result.success(null);
          return;
        case 'stopVpn':
          this.stopVpn(result);
          return;
        case 'prepareNotifications':
          result.success(true);
          return;
        case 'prepareVpn':
          this.prepareVpn(result);
          return;
        case 'startVpn':
          this.startVpn(call, result);
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

  private ensureCoreInitialized(): void {
    if (this.coreInitialized) {
      return;
    }
    const filesDir = this.context?.filesDir ?? this.abilityContext?.filesDir;
    if (filesDir && filesDir.length > 0) {
      easytier.initLogManager(filesDir, 'entry');
      easytier.configureLogManager(true, true);
      easytier.initConfigStore(filesDir);
    }
    easytier.initPanicHook();
    this.coreInitialized = true;
  }

  private startConfigServerClient(call: MethodCall, result: MethodResult): void {
    this.ensureCoreInitialized();
    const url = this.readStringArgument(call, 'url');
    const hostname = this.readStringArgument(call, 'hostname');
    const machineId = this.readStringArgument(call, 'machineId');
    const secureMode = this.readBoolArgument(call, 'secureMode');
    const ok = easytier.startConfigServerClient(url, hostname, machineId, secureMode);
    if (!ok) {
      this.lastError = 'HarmonyOS EasyTier config server client start failed';
      result.error('OHOS_CORE_START_FAILED', this.lastError, null);
      return;
    }
    this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
    this.startEventPolling();
    result.success(null);
  }

  private stopRuntime(result: MethodResult): void {
    easytier.stopRuntime();
    this.destroyVpnConnection()
      .then(() => {
        this.activeVpnInstanceId = '';
        this.activeVpnInstanceName = '';
        this.emitEvent('config_server_stopped', new EmptyPayload());
        result.success(null);
      })
      .catch((error: Error) => {
        this.lastError = this.errorMessage(error);
        result.error('OHOS_VPN_STOP_FAILED', this.lastError, null);
      });
  }

  private stopNetworkInstances(call: MethodCall): void {
    const instanceNames = this.readStringArrayArgument(call, 'instanceNames');
    const instanceIds = instanceNames
      .map((name: string) => easytier.resolveInstanceId(name) ?? name)
      .filter((id: string) => id.length > 0);
    if (instanceIds.length > 0) {
      easytier.stopNetworkInstance(instanceIds);
    }
  }

  private prepareVpn(result: MethodResult): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.startVpnExtensionAbility(want)
      .then(() => vpnExtension.stopVpnExtensionAbility(want))
      .then(() => this.protectProcessNetwork())
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

  private startVpn(call: MethodCall, result: MethodResult): void {
    this.ensureCoreInitialized();
    const instanceName = this.readStringArgument(call, 'instanceName');
    const vpnConfig = this.readMethodCallArgument(call, 'vpnConfig');
    const instanceId = easytier.resolveInstanceId(instanceName) ?? instanceName;
    if (instanceId.length === 0) {
      this.lastError = 'HarmonyOS VPN instance id is empty';
      result.error('OHOS_VPN_INSTANCE_MISSING', this.lastError, null);
      return;
    }

    const config = this.buildVpnConfig(vpnConfig);
    this.createVpnConnection()
      .then((connection) => this.protectProcessNetwork().then(() => connection))
      .then((connection) => connection.destroy().then(() => connection.create(config)))
      .then((fd: number) => {
        if (!easytier.setTunFd(instanceId, fd)) {
          this.lastError = `HarmonyOS setTunFd failed for ${instanceId}`;
          result.error('OHOS_SET_TUN_FD_FAILED', this.lastError, null);
          return;
        }
        this.activeVpnInstanceId = instanceId;
        this.activeVpnInstanceName = instanceName;
        this.emitEvent('vpn_started', new VpnStartedPayload(instanceName, instanceId, fd));
        result.success(null);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS VPN start failed: ${this.errorMessage(error)}`;
        result.error('OHOS_VPN_START_FAILED', this.lastError, null);
      });
  }

  private stopVpn(result: MethodResult): void {
    const instanceName = this.activeVpnInstanceName;
    const instanceId = this.activeVpnInstanceId;
    this.destroyVpnConnection()
      .then(() => {
        this.activeVpnInstanceName = '';
        this.activeVpnInstanceId = '';
        this.emitEvent('vpn_stopped', new VpnStoppedPayload(instanceName, instanceId));
        result.success(null);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS VPN stop failed: ${this.errorMessage(error)}`;
        result.error('OHOS_VPN_STOP_FAILED', this.lastError, null);
      });
  }

  private createVpnConnection(): Promise<vpnExtension.VpnConnection> {
    if (this.vpnConnection !== null) {
      return Promise.resolve(this.vpnConnection);
    }
    const context = this.abilityContext;
    if (context === null) {
      return Promise.reject(new Error('HarmonyOS ability context is unavailable'));
    }
    this.vpnConnection = vpnExtension.createVpnConnection(context as Object as vpnExtension.VpnExtensionContext);
    return Promise.resolve(this.vpnConnection);
  }

  private protectProcessNetwork(): Promise<void> {
    if (this.processNetProtected) {
      return Promise.resolve();
    }
    return this.createVpnConnection()
      .then((connection) => connection.protectProcessNet())
      .then(() => {
        this.processNetProtected = true;
      });
  }

  private destroyVpnConnection(): Promise<void> {
    if (this.vpnConnection === null) {
      return Promise.resolve();
    }
    const connection = this.vpnConnection;
    this.vpnConnection = null;
    this.processNetProtected = false;
    return connection.destroy();
  }

  private buildVpnConfig(input: MethodCall): vpnExtension.VpnConfig {
    const addresses = this.readStringArrayFromValue(
      this.readConfigValue(input, 'addresses') ?? this.readConfigValue(input, 'address'),
    );
    if (addresses.length === 0) {
      throw new Error('HarmonyOS VPN config missing address');
    }
    const primaryAddress = this.parseCidr(addresses[0], 24);
    const routes = this.readStringArrayFromValue(
      this.readConfigValue(input, 'routes') ?? this.readConfigValue(input, 'route'),
    )
      .map((route: string): connection.RouteInfo | null => this.buildRouteInfo(route, primaryAddress.address))
      .filter((route: connection.RouteInfo | null): boolean => route !== null) as connection.RouteInfo[];
    const dns = this.readStringArrayFromValue(
      this.readConfigValue(input, 'dns') ??
        this.readConfigValue(input, 'dns_servers') ??
        this.readConfigValue(input, 'dnsServers'),
    );
    const disallowedApplications = this.readStringArrayFromValue(
      this.readConfigValue(input, 'disallowedApplications') ??
        this.readConfigValue(input, 'disallowed_applications') ??
        this.readConfigValue(input, 'disallowedPackages') ??
        this.readConfigValue(input, 'disallowed_packages'),
    );
    const mtu = this.readNumberFromValue(this.readConfigValue(input, 'mtu'), DEFAULT_MTU);

    return {
      addresses: [
        {
          address: {
            address: primaryAddress.address,
            family: IPV4_FAMILY,
          },
          prefixLength: primaryAddress.prefix,
        },
      ],
      routes,
      dnsAddresses: dns.length > 0 ? dns : [DEFAULT_DNS],
      blockedApplications: disallowedApplications,
      trustedApplications: [],
      mtu,
    };
  }

  private buildRouteInfo(route: string, gateway: string): connection.RouteInfo | null {
    try {
      const cidr = this.parseCidr(route, 32);
      return {
        interface: 'vpn-tun',
        destination: {
          address: {
            address: cidr.address,
            family: IPV4_FAMILY,
          },
          prefixLength: cidr.prefix,
        },
        gateway: {
          address: gateway,
          family: IPV4_FAMILY,
        },
        hasGateway: true,
        isDefaultRoute: cidr.address === '0.0.0.0' && cidr.prefix === 0,
      };
    } catch (_) {
      return null;
    }
  }

  private parseCidr(value: string, defaultPrefix: number): CidrParts {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      throw new Error('empty cidr');
    }
    const parts = trimmed.split('/');
    const address = parts[0].trim();
    const prefix = parts.length > 1 ? Number.parseInt(parts[1], 10) : defaultPrefix;
    if (address.length === 0 || Number.isNaN(prefix) || prefix < 0 || prefix > 32) {
      throw new Error(`invalid cidr: ${value}`);
    }
    return { address, prefix };
  }

  private startEventPolling(): void {
    if (this.eventTimer !== null) {
      return;
    }
    this.eventTimer = setInterval(() => {
      this.drainConfigServerEvents();
    }, EVENT_POLL_INTERVAL_MS);
  }

  private stopEventPolling(): void {
    if (this.eventTimer === null) {
      return;
    }
    clearInterval(this.eventTimer);
    this.eventTimer = null;
  }

  private drainConfigServerEvents(): void {
    if (this.eventSink === null) {
      return;
    }
    try {
      const raw = easytier.drainConfigServerEvents();
      const events = JSON.parse(raw) as Array<Object>;
      for (const event of events) {
        this.emitEvent('config_server', event);
      }
    } catch (error) {
      this.lastError = `HarmonyOS config server event drain failed: ${this.errorMessage(error)}`;
      this.emitEvent('error', new ErrorPayload(this.lastError));
    }
  }

  private emitEvent(type: string, payload: Object): void {
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
    // The Rust core resolves this id with uuid::Uuid::parse_str and registers it
    // to the console verbatim only when it is a canonical UUID. Any other string
    // (including a legacy "harmony-<uuid>" value persisted by older builds) is
    // hashed into a different UUID, so the device registered to the console can
    // never be matched back by machineId and joining a network stays stuck at
    // "waiting for device to register". Persist a lowercase canonical UUID so it
    // matches uuid::Uuid::to_string() as reported back by the console.
    const machineId = util.generateRandomUUID().toLowerCase();
    store.putSync(MACHINE_ID_KEY, machineId);
    store.flushSync();
    return machineId;
  }

  private getHostname(): string {
    const deviceName = deviceInfo.marketName || deviceInfo.productModel || deviceInfo.deviceType;
    return deviceName.length > 0 ? deviceName : 'HarmonyOS';
  }

  private readStringArgument(call: MethodCall, key: string): string {
    const value: Object | null = call.argument(key) as Object | null;
    return value === null || value === undefined ? '' : `${value}`;
  }

  private readBoolArgument(call: MethodCall, key: string): boolean {
    const value: boolean | null = call.argument(key) as boolean | null;
    return value === true;
  }

  private readMethodCallArgument(call: MethodCall, key: string): MethodCall {
    return new MethodCall(key, call.argument(key));
  }

  private readConfigValue(call: MethodCall, key: string): Object | undefined {
    const value = call.argument(key) as Object | null;
    return value === null || value === undefined ? undefined : value;
  }

  private readStringArrayArgument(call: MethodCall, key: string): Array<string> {
    const value = call.argument(key) as Array<string> | null;
    return value ?? [];
  }

  private readStringArrayFromValue(value: Object | undefined): Array<string> {
    if (value === undefined || value === null) {
      return [];
    }
    if (Array.isArray(value)) {
      return value.map((item: Object): string => `${item}`).filter((item: string): boolean => item.length > 0);
    }
    const text = `${value}`;
    return text.length > 0 ? [text] : [];
  }

  private readNumberFromValue(value: Object | undefined, fallback: number): number {
    if (typeof value === 'number') {
      return value;
    }
    const parsed = Number.parseInt(`${value ?? ''}`, 10);
    return Number.isNaN(parsed) ? fallback : parsed;
  }

  private errorMessage(error: Object): string {
    const typed = error as Error;
    return typed.message ?? `${error}`;
  }
}
