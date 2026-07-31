import { common, Context, Want } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { JSON } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
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
  RUNTIME_IPC_ERROR_REMOTE,
  RuntimeIpcError,
  RuntimeIpcClient,
  RuntimeParams,
  RuntimeValue,
  RuntimeVpnConfig,
  runtimeSocketPath,
} from './OhosCoreRuntimeIpc';
import { getOhosBackgroundTaskService } from './OhosBackgroundTaskService';

const METHOD_CHANNEL_NAME = 'net.easytier.pro/core_runtime';
const EVENT_CHANNEL_NAME = 'net.easytier.pro/core_runtime_events';
const BUNDLE_NAME = 'net.easytier.pro';
const VPN_ABILITY_NAME = 'EasyTierVpnAbility';
const PREFERENCES_NAME = 'EasyTierProCoreRuntime';
const MACHINE_ID_KEY = 'machine_id';
const MACHINE_ID_UUID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const RUNTIME_ACTIVITY_POLL_INTERVAL_MS: number = 5000;
const RUNTIME_READY_PROBE_TIMEOUT_MS: number = 2000;

let nextRuntimeBridgeGeneration: number = 0;
let activeRuntimeBridgeGeneration: number = 0;

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

class DeviceEnvironmentPayload {
  displayVersion: string;
  osFullName: string;
  distributionOSVersion: string;
  deviceModel: string;
  hostname: string;

  constructor(
    displayVersion: string,
    osFullName: string,
    distributionOSVersion: string,
    deviceModel: string,
    hostname: string,
  ) {
    this.displayVersion = displayVersion;
    this.osFullName = osFullName;
    this.distributionOSVersion = distributionOSVersion;
    this.deviceModel = deviceModel;
    this.hostname = hostname;
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
  private bridgeGeneration: number = ++nextRuntimeBridgeGeneration;
  private channel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private context: Context | null = null;
  private abilityContext: common.UIAbilityContext | null = null;
  private diagnosticsExportDirectory: string = '';
  private lastError: string = '';
  private runtimeActivityRefreshInFlight: boolean = false;
  private runtimeActivityRefreshRequested: boolean = false;
  private runtimeActivitySession: number = 0;
  private runtimeActivityRefreshSession: number = 0;
  private runtimeActivityMonitoring: boolean = false;
  private runtimeActivityPollTimer: number = -1;
  private runtimeActivityActive: boolean | null = null;
  private runtimeReadyInFlight: Promise<void> | null = null;
  private runtimeReadyGeneration: number = 0;
  private runtimeClient: RuntimeIpcClient = new RuntimeIpcClient(
    (type: string, payload: RuntimeValue) => {
      this.handleRuntimeEvent(type, payload);
      this.emitEvent(type, payload);
    },
    () => {
      this.handleRuntimeSocketClosed();
    },
  );

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
    this.stopRuntimeActivityPolling(true);
    this.cancelRuntimeReadyCheck().then(() => {
    });
    this.runtimeClient.close().catch((error: Error): void => {
      console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(error)}`);
    });
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
    this.stopRuntimeActivityPolling(true);
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
        case 'getDeviceEnvironment':
          result.success(this.getDeviceEnvironment());
          return;
        case 'getFilesDir':
          result.success(this.filesDir());
          return;
        case 'prepareDiagnosticsExportDirectory':
          this.prepareDiagnosticsExportDirectory(result);
          return;
        case 'startConfigServerClient':
          this.startConfigServerClient(call, result);
          return;
        case 'stopConfigServerClient':
          this.stopConfigServerClient(result);
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

  private prepareDiagnosticsExportDirectory(result: MethodResult): void {
    if (this.abilityContext === null) {
      this.lastError = 'HarmonyOS UIAbility context is unavailable';
      result.error('OHOS_DIAGNOSTICS_CONTEXT_MISSING', this.lastError, null);
      return;
    }
    if (this.diagnosticsExportDirectory.length > 0) {
      try {
        fileIo.listFileSync(this.diagnosticsExportDirectory);
        result.success(this.diagnosticsExportDirectory);
        return;
      } catch (_) {
        this.diagnosticsExportDirectory = '';
      }
    }

    const documentPicker = new picker.DocumentViewPicker(this.abilityContext);
    const options = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    documentPicker.save(options)
      .then((uris: Array<string>): void => {
        if (uris.length === 0 || uris[0].trim().length === 0) {
          throw new Error('HarmonyOS download directory URI is unavailable');
        }
        const directory = new fileUri.FileUri(uris[0]).path.trim();
        if (directory.length === 0) {
          throw new Error('HarmonyOS download directory path is unavailable');
        }
        fileIo.listFileSync(directory);
        this.diagnosticsExportDirectory = directory;
        result.success(directory);
      })
      .catch((error: Error): void => {
        this.lastError = `HarmonyOS diagnostics directory preparation failed: ${this.errorMessage(error)}`;
        result.error('OHOS_DIAGNOSTICS_DIRECTORY_FAILED', this.lastError, null);
      });
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
    const startParams = new RuntimeParams();
    startParams.url = url;
    startParams.hostname = hostname;
    startParams.machineId = machineId;
    startParams.secureMode = secureMode;
    startParams.socketFilesDir = filesDir;
    this.stopRuntimeActivityPolling(true);
    this.ensureRuntimeExtensionConnected(filesDir)
      .then(() => this.runtimeClient.request('startConfigServerClient', startParams)
        .catch((error: Error) => {
          throw this.runtimeRequestStageError('core_start', error);
        }))
      .then(() => {
        this.startRuntimeActivityPolling();
        this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
        result.success(null);
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS EasyTier runtime start failed: ${this.errorMessage(error)}`;
        result.error('OHOS_CORE_START_FAILED', this.lastError, null);
      });
  }

  private stopConfigServerClient(result: MethodResult): void {
    this.runtimeClient.request('stopConfigServerClient', new RuntimeParams())
      .then((value: RuntimeValue): void => {
        this.stopRuntimeActivityPolling(true);
        result.success(value);
      })
      .catch((error: Error): void => {
        this.stopRuntimeActivityPolling(true);
        this.completeRuntimeFailure('stopConfigServerClient', error, result);
      });
  }

  private stopRuntime(result: MethodResult): void {
    const readyCheck = this.cancelRuntimeReadyCheck();
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
    };
    const stopCore = readyCheck.then((): Promise<RuntimeValue> => {
      return this.runtimeClient.isConnected()
        ? this.runtimeClient.request('stopRuntime', new RuntimeParams()).catch((_error: Error) => null)
        : Promise.resolve(null);
    });
    stopCore
      .then(() => vpnExtension.stopVpnExtensionAbility(want))
      .then(() => this.runtimeClient.close())
      .then(() => {
        this.stopRuntimeActivityPolling(true);
        this.emitEvent('config_server_stopped', new EmptyPayload());
        result.success(null);
      })
      .catch((error: Error) => {
        this.stopRuntimeActivityPolling(true);
        this.runtimeClient.close().catch((closeError: Error): void => {
          console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(closeError)}`);
        });
        this.lastError = this.errorMessage(error);
        result.error('OHOS_RUNTIME_STOP_FAILED', this.lastError, null);
      });
  }

  private prepareVpn(result: MethodResult): void {
    const filesDir = this.filesDir();
    if (filesDir.length === 0) {
      this.lastError = 'HarmonyOS filesDir is unavailable';
      this.emitEvent('vpn_permission_denied', new ErrorPayload(this.lastError));
      result.success(false);
      return;
    }
    // 权限探测拉起的 Extension 同时就是后续 Core 的运行容器。
    // 将它保留并等待 IPC 就绪，避免 stop→start→stop 后立即再 start
    // 造成 Extension 销毁与重建竞态。
    this.ensureRuntimeExtensionConnected(filesDir)
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

  private ensureRuntimeExtensionConnected(filesDir: string): Promise<void> {
    if (this.runtimeReadyInFlight !== null) {
      return this.runtimeReadyInFlight;
    }
    const socketPath = runtimeSocketPath(filesDir);
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        socketFilesDir: filesDir,
      },
    };
    const generation = ++this.runtimeReadyGeneration;
    const request = this.probeRuntimeIpc(socketPath, 3)
      .catch((_probeError: Error) => this.startRuntimeExtensionAndWait(want, socketPath, generation));
    const trackedRequest = request.then((): void => {
      this.clearRuntimeReadyCheck(generation);
    }).catch((error: Error) => {
      this.clearRuntimeReadyCheck(generation);
      throw error;
    });
    this.runtimeReadyInFlight = trackedRequest;
    return trackedRequest;
  }

  private startRuntimeExtensionAndWait(want: Want, socketPath: string, generation: number): Promise<void> {
    let abilityStartError = '';
    return Promise.resolve()
      .then(() => {
        this.assertRuntimeReadyGeneration(generation);
        return vpnExtension.startVpnExtensionAbility(want);
      })
      .catch((error: Error): void => {
        abilityStartError = this.errorMessage(error);
      })
      .then(() => {
        this.assertRuntimeReadyGeneration(generation);
        // A surviving singleton may reject another start while its IPC listener is
        // still becoming ready. Always perform the longer wait before failing.
        return this.probeRuntimeIpc(socketPath);
      })
      .catch((error: Error) => {
        const abilityDetail = abilityStartError.length > 0 ?
          `; ability_start=${abilityStartError}` : '';
        throw new Error(`[ipc_connect] ${this.errorMessage(error)}${abilityDetail}`);
      });
  }

  private probeRuntimeIpc(socketPath: string, maxAttempts?: number): Promise<void> {
    const connectRequest = maxAttempts === undefined ?
      this.runtimeClient.connect(socketPath) : this.runtimeClient.connect(socketPath, maxAttempts);
    return connectRequest
      .then(() => this.runtimeClient.request(
        'isConfigServerClientConnected',
        new RuntimeParams(),
        RUNTIME_READY_PROBE_TIMEOUT_MS,
      ))
      .then((_value: RuntimeValue): void => {
      })
      .catch((error: Error): void => {
        // A structured remote rejection still proves that the socket transport
        // is alive. It must not invalidate or restart the Extension.
        if (this.isRemoteRuntimeError(error)) {
          return;
        }
        throw error;
      });
  }

  private clearRuntimeReadyCheck(generation: number): void {
    if (generation !== this.runtimeReadyGeneration) {
      return;
    }
    this.runtimeReadyInFlight = null;
  }

  private cancelRuntimeReadyCheck(): Promise<void> {
    const inFlight = this.runtimeReadyInFlight;
    this.runtimeReadyGeneration += 1;
    this.runtimeReadyInFlight = null;
    if (inFlight === null) {
      return Promise.resolve();
    }
    return inFlight.catch((_error: Error): void => {
    });
  }

  private assertRuntimeReadyGeneration(generation: number): void {
    if (generation !== this.runtimeReadyGeneration) {
      throw new Error('HarmonyOS core runtime readiness check was superseded');
    }
  }

  private runtimeStageError(stage: string, error: Object): Error {
    return new Error(`[${stage}] ${this.errorMessage(error)}`);
  }

  private runtimeRequestStageError(coreStage: string, error: Error): Error {
    return this.isRemoteRuntimeError(error) ?
      this.runtimeStageError(coreStage, error) : this.runtimeStageError('ipc_request', error);
  }

  private isRemoteRuntimeError(error: Error): boolean {
    return error instanceof RuntimeIpcError && (error as RuntimeIpcError).kind === RUNTIME_IPC_ERROR_REMOTE;
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
    const stage = this.isRemoteRuntimeError(error) ? 'core_request' : 'ipc_request';
    this.lastError = this.errorMessage(this.runtimeStageError(stage, error));
    if (fallback !== undefined) {
      result.success(fallback);
      return;
    }
    result.error('OHOS_RUNTIME_IPC_FAILED', `HarmonyOS core runtime ${method} failed: ${this.lastError}`, null);
  }

  private handleRuntimeEvent(type: string, payload: RuntimeValue): void {
    if (this.abilityContext === null) {
      return;
    }
    if (type === 'config_server_stopped') {
      if (this.isCurrentRuntimeBridge()) {
        this.stopRuntimeActivityPolling(true);
      }
      return;
    }
    if (type === 'vpn_started' || type === 'vpn_stopped' || type === 'config_server' || type === 'runtime_instances_changed') {
      this.refreshRuntimeActivity();
    }
  }

  private handleRuntimeSocketClosed(): void {
    if (!this.runtimeActivityMonitoring) {
      return;
    }
    this.stopRuntimeActivityPolling(true);
  }

  private startRuntimeActivityPolling(): void {
    this.runtimeActivitySession++;
    this.runtimeActivityMonitoring = true;
    activeRuntimeBridgeGeneration = this.bridgeGeneration;
    this.runtimeActivityRefreshInFlight = false;
    this.runtimeActivityRefreshRequested = false;
    this.refreshRuntimeActivity();
    if (this.runtimeActivityPollTimer !== -1) {
      return;
    }
    this.runtimeActivityPollTimer = setInterval((): void => {
      this.refreshRuntimeActivity();
    }, RUNTIME_ACTIVITY_POLL_INTERVAL_MS);
  }

  private stopRuntimeActivityPolling(forceInactive: boolean): void {
    this.runtimeActivitySession++;
    this.runtimeActivityMonitoring = false;
    if (this.runtimeActivityPollTimer !== -1) {
      clearInterval(this.runtimeActivityPollTimer);
    }
    this.runtimeActivityPollTimer = -1;
    this.runtimeActivityRefreshRequested = false;
    this.runtimeActivityRefreshInFlight = false;
    if (!forceInactive || this.abilityContext === null || !this.isCurrentRuntimeBridge()) {
      return;
    }
    this.runtimeActivityActive = false;
    getOhosBackgroundTaskService(this.abilityContext).setRuntimeActive(false);
    activeRuntimeBridgeGeneration = 0;
  }

  private refreshRuntimeActivity(): void {
    if (!this.runtimeActivityMonitoring || this.abilityContext === null || this.filesDir().length === 0) {
      return;
    }
    if (this.runtimeActivityRefreshInFlight) {
      this.runtimeActivityRefreshRequested = true;
      return;
    }
    const session = this.runtimeActivitySession;
    this.runtimeActivityRefreshSession = session;
    this.runtimeActivityRefreshInFlight = true;
    this.runtimeClient.request('listInstances', new RuntimeParams())
      .then((value: RuntimeValue): void => {
        if (session !== this.runtimeActivitySession || !this.runtimeActivityMonitoring) {
          return;
        }
        const anyRunning = this.hasRunningInstances(value);
        if (!this.isCurrentRuntimeBridge() || this.abilityContext === null) {
          return;
        }
        if (this.runtimeActivityActive !== anyRunning) {
          this.runtimeActivityActive = anyRunning;
          getOhosBackgroundTaskService(this.abilityContext).setRuntimeActive(anyRunning);
        }
      })
      .catch((_error: Error): void => {
        if (session !== this.runtimeActivitySession || !this.runtimeActivityMonitoring) {
          return;
        }
        // Retain the prior aggregate activity state until a later event or poll succeeds.
      })
      .then((): void => {
        if (session !== this.runtimeActivitySession || !this.runtimeActivityMonitoring) {
          return;
        }
        this.finishRuntimeActivityRefresh(session);
      });
  }

  private finishRuntimeActivityRefresh(session: number): void {
    if (session !== this.runtimeActivitySession || session !== this.runtimeActivityRefreshSession
      || !this.runtimeActivityMonitoring) {
      return;
    }
    this.runtimeActivityRefreshInFlight = false;
    if (this.runtimeActivityRefreshRequested) {
      this.runtimeActivityRefreshRequested = false;
      this.refreshRuntimeActivity();
    }
  }

  private hasRunningInstances(value: RuntimeValue): boolean {
    if (typeof value !== 'string') {
      throw new Error('HarmonyOS runtime listInstances response is not a JSON string');
    }
    const trimmed = value.trim();
    if (trimmed.length === 0 || trimmed.charAt(0) !== '{' || trimmed.charAt(trimmed.length - 1) !== '}') {
      throw new Error('HarmonyOS runtime listInstances response is not a JSON object');
    }
    const instances = JSON.parse(trimmed) as Record<string, string>;
    return Object.keys(instances).length > 0;
  }

  private isCurrentRuntimeBridge(): boolean {
    return this.bridgeGeneration === activeRuntimeBridgeGeneration;
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

  private getDeviceEnvironment(): string {
    const deviceModel = deviceInfo.marketName || deviceInfo.productModel;
    const payload = new DeviceEnvironmentPayload(
      deviceInfo.displayVersion,
      deviceInfo.osFullName,
      deviceInfo.distributionOSVersion,
      deviceModel,
      this.getHostname(),
    );
    return `${JSON.stringify(payload)}`;
  }

  private filesDir(): string {
    // The UIAbility and VpnExtension run in different sandboxes, so the
    // Extension must bind its IPC socket to the UIAbility directory that is
    // passed in the start Want. The application context is only a fallback
    // for calls made before AbilityAware attachment completes.
    const abilityFilesDir = this.abilityContext?.filesDir ?? '';
    return abilityFilesDir.length > 0 ? abilityFilesDir : (this.context?.filesDir ?? '');
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
    const businessError = error as BusinessError;
    const message = businessError.message ?? `${error}`;
    return typeof businessError.code === 'number' ?
      `code=${businessError.code}, message=${message}` : message;
  }
}
