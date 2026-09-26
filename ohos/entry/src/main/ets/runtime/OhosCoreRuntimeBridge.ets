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
const RUNTIME_READY_PROBE_TIMEOUT_MS: number = 2000;

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
  private channel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private context: Context | null = null;
  private abilityContext: common.UIAbilityContext | null = null;
  private diagnosticsExportDirectory: string = '';
  private lastError: string = '';
  private snapshotGeneration: number = 0;
  private runtimeReadyInFlight: Promise<void> | null = null;
  private runtimeReadyGeneration: number = 0;
  private runtimeClient: RuntimeIpcClient = new RuntimeIpcClient(
    (type: string, payload: RuntimeValue) => {
      this.emitEvent(type, payload);
    },
    () => {
      // Losing the UI transport says nothing about the child runtime's health.
      this.emitEvent('runtime_disconnected', new EmptyPayload());
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
    this.snapshotGeneration++;
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
    this.snapshotGeneration++;
    this.abilityContext = null;
  }

  onListen(args: Object, events: EventSink): void {
    this.eventSink = events;
    this.refreshRuntimeSnapshot();
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
        case 'getRuntimeSnapshot':
          this.forwardRuntimeCall('getRuntimeSnapshot', new RuntimeParams(), result);
          return;
        case 'isConfigServerClientConnected':
          this.forwardRuntimeCall('isConfigServerClientConnected', new RuntimeParams(), result);
          return;
        case 'listInstances':
          this.forwardRuntimeCall('listInstances', new RuntimeParams(), result);
          return;
        case 'callJsonRpc':
          this.forwardRuntimeCall('callJsonRpc', this.readJsonRpcParams(call), result);
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
        case 'resumeVpn':
          this.forwardRuntimeCall('resumeVpn', new RuntimeParams(), result);
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
    this.ensureRuntimeExtensionConnected(filesDir)
      .then(() => this.runtimeClient.request('startConfigServerClient', startParams)
        .catch((error: Error) => {
          throw this.runtimeRequestStageError('core_start', error);
        }))
      .then(() => {
        this.refreshRuntimeSnapshot();
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
        result.success(value);
      })
      .catch((error: Error): void => {
        this.completeRuntimeFailure('stopConfigServerClient', error, result);
      });
  }

  private stopRuntime(result: MethodResult): void {
    this.snapshotGeneration++;
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
        this.emitEvent('config_server_stopped', new EmptyPayload());
        result.success(null);
      })
      .catch((error: Error) => {
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
    let abilityStartSettled = false;
    this.assertRuntimeReadyGeneration(generation);
    const abilityStart = Promise.resolve()
      .then(() => {
        this.assertRuntimeReadyGeneration(generation);
        return vpnExtension.startVpnExtensionAbility(want);
      })
      .then((): void => {
        abilityStartSettled = true;
      }, (error: Error): void => {
        abilityStartError = this.errorMessage(error);
        abilityStartSettled = true;
      });
    // The first authorization can start the Extension before the system call
    // returns to the UIAbility. Probe IPC concurrently so that successful
    // authorization is not blocked by that pending Promise.
    const probeWhileStarting = (): Promise<void> => this.probeRuntimeIpc(socketPath)
      .catch((_probeError: Error): Promise<void> => {
        this.assertRuntimeReadyGeneration(generation);
        if (!abilityStartSettled) {
          return probeWhileStarting();
        }
        // A surviving singleton may reject another start while its IPC listener is
        // still becoming ready. Always perform the longer wait before failing.
        return abilityStart.then(() => this.probeRuntimeIpc(socketPath));
      });
    return probeWhileStarting()
      .then((): void => {
        this.assertRuntimeReadyGeneration(generation);
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
  ): void {
    if (!this.runtimeClient.isConnected()) {
      const filesDir = this.filesDir();
      if (filesDir.length > 0) {
        this.runtimeClient.connect(runtimeSocketPath(filesDir))
          .then(() => this.forwardRuntimeCall(method, params, result))
          .catch((error: Error) => this.completeRuntimeFailure(method, error, result));
        return;
      }
    }
    this.runtimeClient.request(method, params)
      .then((value: RuntimeValue) => {
        result.success(value);
      })
      .catch((error: Error) => this.completeRuntimeFailure(method, error, result));
  }

  private completeRuntimeFailure(method: string, error: Error, result: MethodResult): void {
    const stage = this.isRemoteRuntimeError(error) ? 'core_request' : 'ipc_request';
    this.lastError = this.errorMessage(this.runtimeStageError(stage, error));
    result.error('OHOS_RUNTIME_IPC_FAILED', `HarmonyOS core runtime ${method} failed: ${this.lastError}`, null);
  }

  onForeground(): void {
    // Resume may deliver expired timers before buffered socket messages. Fence
    // the old transport, then read truth instead of replaying missed events.
    if (this.runtimeReadyInFlight === null) {
      this.refreshRuntimeSnapshot(true);
    }
  }

  private refreshRuntimeSnapshot(resetTransport: boolean = false): void {
    const filesDir = this.filesDir();
    if (this.abilityContext === null || filesDir.length === 0) {
      return;
    }
    const generation = ++this.snapshotGeneration;
    const ready = resetTransport ? this.runtimeClient.close() : Promise.resolve();
    ready.then((): Promise<void> => {
      if (generation !== this.snapshotGeneration || this.abilityContext === null) {
        throw new Error('HarmonyOS runtime snapshot request was superseded');
      }
      // Reattach only; opening/resuming a view must never start a VPN Extension.
      return this.runtimeClient.connect(runtimeSocketPath(filesDir), 3);
    }).then((): Promise<RuntimeValue> => {
      if (generation !== this.snapshotGeneration || this.abilityContext === null) {
        throw new Error('HarmonyOS runtime snapshot request was superseded');
      }
      return this.runtimeClient.request('getRuntimeSnapshot', new RuntimeParams());
    })
      .then((value: RuntimeValue): void => {
        if (generation === this.snapshotGeneration) {
          this.emitEvent('runtime_snapshot', value);
        }
      }).catch((error: Error): void => {
        if (generation === this.snapshotGeneration) {
          this.emitEvent('runtime_disconnected', new ErrorPayload(this.errorMessage(error)));
        }
      });
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


  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    const message = businessError.message ?? `${error}`;
    return typeof businessError.code === 'number' ?
      `code=${businessError.code}, message=${message}` : message;
  }
}
