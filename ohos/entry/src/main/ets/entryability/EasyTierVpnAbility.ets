import { Want } from '@kit.AbilityKit';
import { JSON } from '@kit.ArkTS';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import easytier from 'easytier-ohrs';
import { NativeSocketProtectionService } from '../runtime/NativeSocketProtectionService';
import {
  readArrayParam,
  readBoolParam,
  readStringParam,
  RuntimeIpcServer,
  RuntimeParams,
  RuntimeSnapshot,
  RuntimeValue,
  RuntimeVpnConfig,
} from '../runtime/OhosCoreRuntimeIpc';

const IPV4_FAMILY = 1;
const DEFAULT_MTU = 1380;
const DEFAULT_ADDRESS_PREFIX = 24;
const DEFAULT_ROUTE_PREFIX = 32;
// The extension owns the TUN lifecycle, so its supervision loop keeps polling
// Core state even when no UI client is connected. UI clients only observe.
const RUNTIME_POLL_INTERVAL_MS = 500;

interface CidrParts {
  address: string;
  prefix: number;
}

// collectRuntimeStateJson serializes Core state with #[serde(rename_all =
// "camelCase")] (verified at the packaged commit c96b6c19), so every field below
// keeps the camelCase spelling Core emits.
interface CoreMyNodeInfo {
  virtualIpv4?: string;
  virtualIpv4Cidr?: string;
  hostname?: string;
}

interface CoreRuntimeInstanceState {
  configId: string;
  instanceId: string;
  displayName: string;
  running: boolean;
  tunRequired: boolean;
  tunAttached: boolean;
  myNodeInfo?: CoreMyNodeInfo;
}

interface CoreTunAggregateState {
  active: boolean;
  attachedInstanceIds: Array<string>;
  aggregatedRoutes: Array<string>;
  dnsServers: Array<string>;
  needRebuild: boolean;
}

interface CoreRuntimeAggregateState {
  instances: Array<CoreRuntimeInstanceState>;
  tun: CoreTunAggregateState;
}

// Event objects drained from the Pro config server client; Core builds them with
// serde_json::json!, so these inner keys stay snake_case.
interface CoreConfigServerEvent {
  event?: string;
  success?: boolean;
  instance_id?: string;
  instance_name?: string;
  network_name?: string;
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

// One entry of listProInstancesJson: the console network name labels the
// instance uuid Core assigned to it.
class ProInstanceEntry {
  label: string;
  instanceId: string;

  constructor(label: string, instanceId: string) {
    this.label = label;
    this.instanceId = instanceId;
  }
}

// Everything the platform needs for one TUN interface, derived from Core state.
class VpnRuntimeTarget {
  instanceId: string = '';
  instanceLabel: string = '';
  address: string = '';
  routes: Array<string> = [];
  dns: Array<string> = [];
  mtu: number = DEFAULT_MTU;
}

export default class EasyTierVpnAbility extends VpnExtensionAbility {
  private ipcServer: RuntimeIpcServer | null = null;
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private runtimeTimer: number | null = null;
  private reconcileScheduled: boolean = false;
  private lastError: string = '';
  private coreInitialized: boolean = false;
  private runtimeOperationQueue: Promise<void> = Promise.resolve();
  private shuttingDown: boolean = false;
  private socketProtection: NativeSocketProtectionService = new NativeSocketProtectionService(
    () => this.vpnConnection,
    (error: Error) => this.handleSocketProtectionFailure(error),
  );
  // State of the TUN interface this extension successfully attached, not the
  // state it merely wants to attach.
  private activeVpnInstanceId: string = '';
  private activeVpnInstanceName: string = '';
  private activeTunSignature: string = '';
  private activeTunConfig: RuntimeVpnConfig | null = null;
  // stopVpn suppression: automatic re-creation stays off while this instance is
  // still running, so the next joined instance is not blocked.
  private suspendedInstanceId: string = '';
  // Last instance Core reported as successfully started, preferred over the
  // deterministic fallback when the platform has to pick an interface owner.
  private lastRunInstanceId: string = '';
  private waitingAddressInstanceId: string = '';
  private lastSnapshotJson: string = '';
  // Private identity of the config server client this process owns, compared
  // exactly and kept out of runtime snapshots.
  private clientOwned: boolean = false;
  private ownedClientUrl: string = '';
  private ownedClientHostname: string = '';
  private ownedClientMachineId: string = '';
  private ownedClientSecureMode: boolean = false;
  // Bumped on every supervision start/stop so a reconcile that was queued before
  // an explicit stop cannot run against the stopped runtime.
  private supervisionGeneration: number = 0;

  onCreate(want: Want): void {
    let params = new RuntimeParams();
    if (want.parameters !== undefined) {
      params = want.parameters as Object as RuntimeParams;
    }
    const requestedFilesDir = readStringParam(params, 'socketFilesDir').trim();
    const filesDir = requestedFilesDir.length > 0 ? requestedFilesDir : this.context.filesDir.trim();
    if (filesDir.length === 0) {
      this.lastError = 'HarmonyOS UIAbility socket files directory is missing';
      console.error(`[EasyTierProVpn] ${this.lastError}`);
      return;
    }
    if (requestedFilesDir.length === 0) {
      console.info('[EasyTierProVpn] using VPN Extension files directory for runtime IPC');
    }
    this.ensureCoreInitialized(filesDir);
    // 关键修复：无论本次拉起是否携带 url（权限探测拉起不带 url），
    // 都必须启动 IPC 服务器。VpnExtensionAbility 是进程单例，二次
    // startVpnExtensionAbility 不会再触发 onCreate——如果探测拉起的
    // 裸实例没有 IPC 服务器，被杀后台后重进 App 将永远连不上运行时，
    // 表现为“无法重启 VPN”。启动参数改由主进程通过 IPC 显式下发。
    this.ipcServer = new RuntimeIpcServer((method: string, requestParams: RuntimeParams) => {
      return this.handleRuntimeRequest(method, requestParams);
    });
    this.ipcServer.start(filesDir)
      .then(() => {
        console.info('[EasyTierProVpn] runtime IPC server ready');
      })
      .catch((error: Error) => {
        this.lastError = this.errorMessage(error);
        console.error(`[EasyTierProVpn] ${this.lastError}`);
      });
    if (readStringParam(params, 'url').length === 0) {
      console.info('[EasyTierProVpn] created without url (permission probe or IPC-driven start)');
      return;
    }
    this.handleRuntimeRequest('startConfigServerClient', params).catch((error: Error) => {
      this.lastError = this.errorMessage(error);
      console.error(`[EasyTierProVpn] ${this.lastError}`);
      this.emitEvent('error', new ErrorPayload(this.lastError));
    });
  }

  onDestroy(): void {
    this.shuttingDown = true;
    this.stopRuntimeSupervision();
    this.runtimeOperationQueue.then(() => this.stopRuntime()).catch((error: Error) => {
      console.error(`[EasyTierProVpn] runtime shutdown failed: ${this.errorMessage(error)}`);
    });
    const ipcServer = this.ipcServer;
    this.ipcServer = null;
    if (ipcServer !== null) {
      ipcServer.close().catch((error: Error): void => {
        console.error(`[EasyTierProVpn] runtime IPC close failed: ${this.errorMessage(error)}`);
      });
    }
  }

  private handleRuntimeRequest(method: string, params: RuntimeParams): Promise<RuntimeValue> {
    if (this.shuttingDown) {
      return Promise.reject(new Error('HarmonyOS VPN runtime is shutting down'));
    }
    const operation = this.runtimeOperationQueue.then(() => {
      if (this.shuttingDown) {
        throw new Error('HarmonyOS VPN runtime is shutting down');
      }
      return this.dispatchRuntimeRequest(method, params);
    });
    this.runtimeOperationQueue = operation.then(() => {}, () => {});
    return operation;
  }

  private dispatchRuntimeRequest(method: string, params: RuntimeParams): Promise<RuntimeValue> {
    try {
      switch (method) {
        case 'startConfigServerClient':
          return this.startConfigServerClient(params);
        case 'stopConfigServerClient':
          return this.socketProtection.runNativeTeardown(() => {
            easytier.stopConfigServerClient();
            // An explicit stop releases ownership, so the same bootstrap may be
            // started again by a later client request.
            this.clearOwnedClient();
            this.emitEvent('config_server_stopped', new EmptyPayload());
            return null;
          });
        case 'stopRuntime':
          return this.stopRuntime();
        case 'isConfigServerClientConnected':
          return Promise.resolve(easytier.isConfigServerClientConnected());
        case 'listInstances':
          return Promise.resolve(easytier.listProInstancesJson());
        case 'callJsonRpc':
          return Promise.resolve(easytier.callProJsonRpc(
            readStringParam(params, 'serviceName'),
            readStringParam(params, 'methodName'),
            readStringParam(params, 'payloadJson'),
          ));
        case 'stopNetworkInstances':
          return this.stopNetworkInstances(params);
        case 'getRuntimeSnapshot':
          return this.getRuntimeSnapshot();
        case 'stopVpn':
          return this.stopVpn();
        case 'resumeVpn':
          return this.resumeVpn();
        case 'getLastError':
          return Promise.resolve(this.lastError);
        default:
          return Promise.reject(new Error(`Unsupported HarmonyOS runtime IPC method: ${method}`));
      }
    } catch (error) {
      this.lastError = this.errorMessage(error);
      return Promise.reject(new Error(this.lastError));
    }
  }

  private ensureCoreInitialized(filesDir: string): void {
    if (this.coreInitialized) {
      return;
    }
    if (filesDir.length > 0) {
      easytier.initLogManager(filesDir, 'vpn');
      easytier.configureLogManager(true, true);
      easytier.initConfigStore(filesDir);
    }
    easytier.initPanicHook();
    this.coreInitialized = true;
  }

  private startConfigServerClient(params: RuntimeParams): Promise<RuntimeValue> {
    const url = readStringParam(params, 'url');
    const hostname = readStringParam(params, 'hostname');
    const machineId = readStringParam(params, 'machineId');
    const secureMode = readBoolParam(params, 'secureMode');
    if (this.clientOwned && this.ownsClientBootstrap(url, hostname, machineId, secureMode)) {
      // This process already owns exactly this client, so a repeated start (a UI
      // readStatus transport failure, or a reconnect probe re-running
      // ensureRunning) must not synchronously tear down the healthy control client
      // and the TUN that depends on it. No native call is made here.
      console.info('[EasyTierProVpn] config server client already owned by this runtime; start ignored');
      this.startRuntimeSupervision();
      return Promise.resolve(null);
    }
    // Native start replaces any prior client synchronously. Stop it while ACKs
    // can still settle, then enable protection before starting its replacement.
    // Ownership is dropped before the native call: the previous client is gone
    // even if the replacement fails.
    this.clearOwnedClient();
    return this.socketProtection.runNativeTeardown(() => {
      easytier.stopConfigServerClient();
    }).then(() => this.prepareSocketProtection()).then(() => {
      const ok = easytier.startConfigServerClient(url, hostname, machineId, secureMode);
      if (!ok) {
        this.lastError = 'HarmonyOS EasyTier config server client start failed';
        return Promise.reject(new Error(this.lastError));
      }
      this.clientOwned = true;
      this.ownedClientUrl = url;
      this.ownedClientHostname = hostname;
      this.ownedClientMachineId = machineId;
      this.ownedClientSecureMode = secureMode;
      // A client start is an explicit runtime start: it clears a suspension that
      // stopVpn left behind for an earlier session.
      this.suspendedInstanceId = '';
      this.lastRunInstanceId = '';
      this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
      this.startRuntimeSupervision();
      return null;
    });
  }

  private ownsClientBootstrap(url: string, hostname: string, machineId: string, secureMode: boolean): boolean {
    return this.ownedClientSecureMode === secureMode && this.ownedClientUrl === url &&
      this.ownedClientHostname === hostname && this.ownedClientMachineId === machineId;
  }

  private clearOwnedClient(): void {
    this.clientOwned = false;
    this.ownedClientUrl = '';
    this.ownedClientHostname = '';
    this.ownedClientMachineId = '';
    this.ownedClientSecureMode = false;
  }

  private async stopRuntime(): Promise<RuntimeValue> {
    this.stopRuntimeSupervision();
    this.clearOwnedClient();
    this.suspendedInstanceId = '';
    this.lastRunInstanceId = '';
    this.waitingAddressInstanceId = '';
    // Resolve/reject dispatched protection requests before calling synchronous
    // native teardown, which may otherwise wait for this ArkTS thread's ACK.
    await this.socketProtection.stop();
    try {
      easytier.stopRuntime();
    } finally {
      await this.destroyVpnConnection();
      this.clearActiveTun();
    }
    this.emitEvent('config_server_stopped', new EmptyPayload());
    this.refreshRuntimeSnapshot(null);
    return null;
  }

  private async stopNetworkInstances(params: RuntimeParams): Promise<RuntimeValue> {
    const instanceNames = readArrayParam(params, 'instanceNames');
    const instanceIds = instanceNames
      .map((name: string) => easytier.resolveInstanceId(name) ?? name)
      .filter((id: string) => id.length > 0);
    if (instanceIds.length > 0) {
      await this.socketProtection.runNativeTeardown(() => {
        easytier.stopNetworkInstance(instanceIds);
      });
    }
    return null;
  }

  private getRuntimeSnapshot(): Promise<RuntimeValue> {
    try {
      return Promise.resolve(this.buildSnapshotJson(null));
    } catch (error) {
      // An unreadable snapshot is unknown state, not a runtime failure: the
      // rejected request already tells the client that, so this must not also
      // publish the error event that moves the UI into its restart flow.
      const message = this.errorMessage(error);
      this.recordObservationProblem(message);
      return Promise.reject(new Error(message));
    }
  }

  // Suppresses automatic TUN re-creation for the instance that is being stopped
  // so a UI exit cannot be undone by the supervision loop, then detaches the
  // interface immediately. When nothing is attached yet, the instance the loop
  // would attach next is suppressed instead.
  private async stopVpn(): Promise<RuntimeValue> {
    const stoppedInstanceId = this.activeVpnInstanceId;
    if (this.suspendedInstanceId.length === 0) {
      this.suspendedInstanceId = stoppedInstanceId.length > 0 ? stoppedInstanceId : this.readSelectedInstanceId();
    }
    await this.detachTun();
    if (stoppedInstanceId.length === 0) {
      // Nothing was attached; still report the stop so a client that lost its
      // local state sees an explicit stop instead of silence.
      this.emitEvent('vpn_stopped', new VpnStoppedPayload('', ''));
    }
    this.refreshRuntimeSnapshot(null);
    return null;
  }

  // Select even before an interface exists. If Core cannot be read, the stop
  // request fails instead of falsely acknowledging an unsuppressed interface.
  private readSelectedInstanceId(): string {
    const entries = this.readProInstances();
    const state = this.readAggregateState();
    const entry = this.selectRuntimeEntry(entries, state);
    return entry === null ? '' : entry.instanceId;
  }

  // Clears the stopVpn suppression and reconciles the current Core state, so a
  // failed exit restores the latest routes without any UI-supplied config. A
  // runtime that was explicitly stopped is not resurrected: only a new
  // startConfigServerClient starts supervision again.
  private async resumeVpn(): Promise<RuntimeValue> {
    this.suspendedInstanceId = '';
    try {
      await this.performReconcile(this.supervisionGeneration);
    } catch (error) {
      const message = this.errorMessage(error);
      this.recordError(message);
      throw new Error(message);
    }
    return null;
  }

  private startRuntimeSupervision(): void {
    if (this.runtimeTimer !== null) {
      return;
    }
    this.supervisionGeneration += 1;
    this.runtimeTimer = setInterval(() => {
      this.scheduleReconcile();
    }, RUNTIME_POLL_INTERVAL_MS);
  }

  private stopRuntimeSupervision(): void {
    // Bump before clearing so a reconcile that is already queued observes the
    // stopped generation instead of running against a stopped runtime.
    this.supervisionGeneration += 1;
    if (this.runtimeTimer === null) {
      return;
    }
    clearInterval(this.runtimeTimer);
    this.runtimeTimer = null;
  }

  private isSupervisionActive(generation: number): boolean {
    return !this.shuttingDown && this.runtimeTimer !== null && generation === this.supervisionGeneration;
  }

  // Poll ticks only enqueue work on the shared runtime operation queue; a slow
  // attach therefore coalesces ticks instead of nesting reconciliations.
  private scheduleReconcile(): void {
    if (this.reconcileScheduled || !this.isSupervisionActive(this.supervisionGeneration)) {
      return;
    }
    const generation = this.supervisionGeneration;
    this.reconcileScheduled = true;
    const operation = this.runtimeOperationQueue
      .then(() => this.runReconcileTick(generation))
      .then((): void => {
        this.reconcileScheduled = false;
      });
    this.runtimeOperationQueue = operation.then(() => {}, () => {});
  }

  private async runReconcileTick(generation: number): Promise<void> {
    if (!this.isSupervisionActive(generation)) {
      return;
    }
    try {
      await this.performReconcile(generation);
    } catch (error) {
      this.recordError(this.errorMessage(error));
    }
  }

  private async performReconcile(generation: number): Promise<void> {
    if (!this.isSupervisionActive(generation)) {
      return;
    }
    let entries: Record<string, string> | null = null;
    try {
      this.drainRuntimeEvents();
      entries = this.readProInstances();
      const state = this.readAggregateState();
      const entry = this.selectRuntimeEntry(entries, state);
      if (entry === null) {
        if (this.activeVpnInstanceId.length > 0) {
          await this.detachTun();
        }
        return;
      }
      const target = this.buildRuntimeTarget(entry, state);
      if (target === null) {
        // Keep an address-less owner only if it is still the same live Core
        // instance. A removed/restarted owner must not retain stale routes.
        if (this.activeVpnInstanceId.length > 0 &&
          (this.activeVpnInstanceId !== entry.instanceId || this.activeTunSignature.length === 0)) {
          await this.detachTun();
        }
        return;
      }
      const appliedConfig = this.coreTunConfig(target);
      const signature = this.tunSignature(target.instanceId, appliedConfig);
      if (signature === this.activeTunSignature) {
        // Unchanged config for the attached instance: strictly no-op.
        this.activeVpnInstanceName = target.instanceLabel;
        return;
      }
      await this.attachTun(target, appliedConfig, signature);
    } finally {
      this.refreshRuntimeSnapshot(entries);
    }
  }

  private drainRuntimeEvents(): void {
    let events: Array<CoreConfigServerEvent> = [];
    try {
      const raw = easytier.drainConfigServerEvents();
      const parsed = JSON.parse(raw) as Array<CoreConfigServerEvent>;
      if (!Array.isArray(parsed)) {
        throw new Error('HarmonyOS config server events are not a JSON array');
      }
      events = parsed;
    } catch (error) {
      this.recordError(`HarmonyOS config server event drain failed: ${this.errorMessage(error)}`);
      return;
    }
    if (events.length > 0) {
      console.info(`[EasyTierProVpn] drain config events count=${events.length}`);
    }
    for (const event of events) {
      this.rememberRunEvent(event);
      this.emitEvent('config_server', event);
    }
  }

  private rememberRunEvent(event: CoreConfigServerEvent): void {
    if (event.event !== 'run_network_instance' || event.success !== true) {
      return;
    }
    const instanceId = typeof event.instance_id === 'string' ? event.instance_id.trim() : '';
    if (instanceId.length > 0) {
      this.lastRunInstanceId = instanceId;
      if (instanceId === this.activeVpnInstanceId) {
        // Core overwrite can replace an instance without changing its UUID or
        // routes. Its new generation still needs a newly attached TUN fd.
        this.activeTunSignature = '';
      }
    }
  }

  // listProInstancesJson is the authoritative Pro identity list: it only maps
  // running instances the Pro config server client actually deployed.
  private readProInstances(): Record<string, string> {
    const raw = easytier.listProInstancesJson();
    let parsed: Record<string, string>;
    try {
      parsed = JSON.parse(raw) as Record<string, string>;
    } catch (error) {
      throw new Error(`HarmonyOS Pro instance list is not valid JSON: ${this.errorMessage(error)}`);
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('HarmonyOS Pro instance list is not a JSON object');
    }
    const labels = Object.keys(parsed);
    for (const label of labels) {
      const instanceId = parsed[label];
      if (typeof instanceId !== 'string' || instanceId.length === 0) {
        throw new Error(`HarmonyOS Pro instance entry ${label} is not a non-empty instance id`);
      }
    }
    // Preserve JSON own properties, including legal labels such as __proto__.
    return parsed;
  }

  private readAggregateState(): CoreRuntimeAggregateState {
    const raw = easytier.collectRuntimeStateJson();
    let parsed: CoreRuntimeAggregateState;
    try {
      parsed = JSON.parse(raw) as CoreRuntimeAggregateState;
    } catch (error) {
      throw new Error(`HarmonyOS Core runtime state is not valid JSON: ${this.errorMessage(error)}`);
    }
    if (parsed === null || parsed === undefined || !Array.isArray(parsed.instances)) {
      throw new Error('HarmonyOS Core runtime state is missing the instance list');
    }
    const tun = parsed.tun;
    if (tun === undefined || tun === null || !Array.isArray(tun.aggregatedRoutes) || !Array.isArray(tun.dnsServers)) {
      throw new Error('HarmonyOS Core runtime state is missing the TUN aggregate state');
    }
    return parsed;
  }

  // Selects the Pro instance that should own the TUN, independent of whether its
  // address is published yet (buildRuntimeTarget decides that).
  private selectRuntimeEntry(
    entries: Record<string, string>,
    state: CoreRuntimeAggregateState,
  ): ProInstanceEntry | null {
    // collectRuntimeStateJson also lists Core-internal instances (the Pro config
    // server client itself, which never carries a TUN). Only listProInstancesJson
    // identities may own the interface, so candidates are built from that map.
    const candidates: Array<ProInstanceEntry> = [];
    for (const label of Object.keys(entries).sort()) {
      const instanceId = entries[label];
      if (instanceId !== undefined && this.findRunningInstance(state, instanceId) !== null) {
        candidates.push(new ProInstanceEntry(label, instanceId));
      }
    }
    if (this.suspendedInstanceId.length > 0 &&
      this.findCandidateEntry(candidates, this.suspendedInstanceId) === null) {
      // The stopped instance is gone: release the suppression so the same
      // identity (or another instance) may use the interface again.
      this.suspendedInstanceId = '';
    }
    if (candidates.length === 0) {
      return null;
    }
    if (this.suspendedInstanceId.length > 0) {
      // The suspended instance still runs: stay stopped until resumeVpn or until
      // it disappears.
      return null;
    }
    // Keep an existing attachment while it is still a valid Pro instance. When
    // its address is not published yet, wait instead of switching instances.
    if (this.activeVpnInstanceId.length > 0) {
      const activeEntry = this.findCandidateEntry(candidates, this.activeVpnInstanceId);
      if (activeEntry !== null) {
        return activeEntry;
      }
    }
    // Prefer the instance Core most recently started successfully.
    if (this.lastRunInstanceId.length > 0) {
      const runEntry = this.findCandidateEntry(candidates, this.lastRunInstanceId);
      if (runEntry !== null) {
        return runEntry;
      }
    }
    return candidates[0];
  }

  private findRunningInstance(state: CoreRuntimeAggregateState, instanceId: string): CoreRuntimeInstanceState | null {
    for (const instance of state.instances) {
      if (instance.instanceId === instanceId && instance.running === true && instance.tunRequired === true) {
        return instance;
      }
    }
    return null;
  }

  private findCandidateEntry(candidates: Array<ProInstanceEntry>, instanceId: string): ProInstanceEntry | null {
    for (const candidate of candidates) {
      if (candidate.instanceId === instanceId) {
        return candidate;
      }
    }
    return null;
  }

  private buildRuntimeTarget(
    entry: ProInstanceEntry,
    state: CoreRuntimeAggregateState,
  ): VpnRuntimeTarget | null {
    const instance = this.findRunningInstance(state, entry.instanceId);
    if (instance === null) {
      return null;
    }
    const address = this.instanceTunAddress(instance);
    if (address.length === 0) {
      // Core publishes the virtual address and the requested routes from the same
      // running info, so waiting for the address also keeps the first interface
      // from coming up without its routes.
      if (this.waitingAddressInstanceId !== entry.instanceId) {
        this.waitingAddressInstanceId = entry.instanceId;
        console.info(`[EasyTierProVpn] waiting for instance address instanceId=${entry.instanceId}`);
      }
      return null;
    }
    const target = new VpnRuntimeTarget();
    target.instanceId = entry.instanceId;
    target.instanceLabel = entry.label;
    target.address = address;
    // tun.aggregatedRoutes is Core's platform-facing route set: at the packaged
    // commit it is the union over instances with tunRequired == true (own virtual
    // cidr + config routes + peer proxy cidrs, simplified). Control-only
    // instances stay out of it because Core reports them with tunRequired false
    // (dev_name "no_tun", or the Pro client id which is not a live instance), and
    // per-instance manual routes are not exposed in JSON, so this aggregate is
    // the only faithful source for the single TUN.
    target.routes = this.readCidrList(state.tun.aggregatedRoutes);
    target.dns = this.readAddressList(state.tun.dnsServers);
    target.mtu = DEFAULT_MTU;
    this.waitingAddressInstanceId = '';
    return target;
  }

  private instanceTunAddress(instance: CoreRuntimeInstanceState): string {
    const nodeInfo = instance.myNodeInfo;
    if (nodeInfo === undefined || nodeInfo === null) {
      return '';
    }
    const cidr = typeof nodeInfo.virtualIpv4Cidr === 'string' ? nodeInfo.virtualIpv4Cidr.trim() : '';
    if (cidr.length > 0) {
      return this.normalizeIpv4Cidr(cidr, DEFAULT_ADDRESS_PREFIX);
    }
    const address = typeof nodeInfo.virtualIpv4 === 'string' ? nodeInfo.virtualIpv4.trim() : '';
    if (address.length === 0) {
      return '';
    }
    return this.normalizeIpv4Cidr(address, DEFAULT_ADDRESS_PREFIX);
  }

  // The fingerprint of what is actually installed: instance id plus the exact
  // addresses/routes/dns/mtu that were handed to the platform.
  private tunSignature(instanceId: string, appliedConfig: RuntimeVpnConfig): string {
    return `${instanceId}|${appliedConfig.addresses.join(',')}|${appliedConfig.routes.join(',')}` +
      `|${appliedConfig.dns.join(',')}|${appliedConfig.mtu}`;
  }

  private async attachTun(
    target: VpnRuntimeTarget,
    appliedConfig: RuntimeVpnConfig,
    signature: string,
  ): Promise<void> {
    const replacedInstanceId = this.activeVpnInstanceId;
    const replacedInstanceName = this.activeVpnInstanceName;
    try {
      await this.prepareSocketProtection();
      if (this.shuttingDown) {
        return;
      }
      const config = this.buildVpnConfig(appliedConfig);
      const fd = await this.socketProtection.runConnectionOperation(async (): Promise<number> => {
        const vpnConnection = await this.createVpnConnection();
        await vpnConnection.destroy();
        if (replacedInstanceId.length > 0 && replacedInstanceId !== target.instanceId) {
          this.emitEvent('vpn_stopped', new VpnStoppedPayload(replacedInstanceName, replacedInstanceId));
        }
        // The previous interface is gone from here on, so stop reporting it as
        // attached before the replacement exists.
        this.clearActiveTun();
        return vpnConnection.create(config);
      });
      if (this.shuttingDown) {
        // Teardown raced this attach: drop the interface instead of leaving an
        // unattached TUN behind. Shutdown is not a failure of this attach.
        await this.destroyVpnConnection();
        return;
      }
      if (!easytier.setTunFd(target.instanceId, fd)) {
        await this.destroyVpnConnection();
        throw new Error(`HarmonyOS setTunFd failed for ${target.instanceId}`);
      }
      this.activeVpnInstanceId = target.instanceId;
      this.activeVpnInstanceName = target.instanceLabel;
      this.activeTunSignature = signature;
      this.activeTunConfig = appliedConfig;
      console.info(
        `[EasyTierProVpn] vpn started instanceId=${target.instanceId} label=${target.instanceLabel} ` +
        `fd=${fd} address=${target.address} routes=${target.routes.length}`,
      );
      this.emitEvent('vpn_started', new VpnStartedPayload(target.instanceLabel, target.instanceId, fd));
    } catch (error) {
      // The interface is not attached: report the failure to the caller so an
      // explicit resumeVpn rejects and the supervision tick reports it, instead
      // of claiming a successful attach.
      throw new Error(`HarmonyOS VPN attach failed: ${this.errorMessage(error)}`);
    }
  }

  private async detachTun(): Promise<void> {
    const instanceId = this.activeVpnInstanceId;
    const instanceName = this.activeVpnInstanceName;
    await this.destroyVpnConnection();
    this.clearActiveTun();
    if (instanceId.length > 0) {
      console.info(`[EasyTierProVpn] vpn stopped instanceId=${instanceId}`);
      this.emitEvent('vpn_stopped', new VpnStoppedPayload(instanceName, instanceId));
    }
  }

  private clearActiveTun(): void {
    this.activeVpnInstanceId = '';
    this.activeVpnInstanceName = '';
    this.activeTunSignature = '';
    this.activeTunConfig = null;
  }

  private recordError(message: string): void {
    if (this.lastError !== message) {
      this.lastError = message;
      this.emitEvent('error', new ErrorPayload(message));
    }
    console.error(`[EasyTierProVpn] ${message}`);
  }

  // A snapshot that cannot be read only means the runtime state is unknown. It
  // is kept for diagnostics, but it must never be published as the error event
  // that makes a UI process treat a healthy runtime as failed.
  private recordObservationProblem(message: string): void {
    this.lastError = message;
    console.error(`[EasyTierProVpn] ${message}`);
  }

  // `entries` is the Pro instance list already read during this tick; null makes
  // the snapshot read Core itself (explicit snapshot reads and non-tick callers).
  private refreshRuntimeSnapshot(entries: Record<string, string> | null): void {
    let snapshotJson = '';
    try {
      snapshotJson = this.buildSnapshotJson(entries);
    } catch (error) {
      this.recordObservationProblem(this.errorMessage(error));
      return;
    }
    if (snapshotJson === this.lastSnapshotJson) {
      return;
    }
    this.lastSnapshotJson = snapshotJson;
    this.emitEvent('runtime_snapshot', snapshotJson);
  }

  // An explicit read never moves the emission baseline: a client that asks for
  // the snapshot can still receive the same content once through the change
  // event without this becoming an unbounded periodic push.
  private buildSnapshotJson(entries: Record<string, string> | null): string {
    const snapshot = new RuntimeSnapshot();
    // A probe failure must not be reported as an authoritative connection state.
    snapshot.configServerConnected = easytier.isConfigServerClientConnected();
    // A signature is cleared the moment Core replaces the active instance
    // generation and only set again by a successful attach, so exporting the
    // identity through it keeps the snapshot from advertising a tunnel that the
    // Extension no longer vouches for.
    const attached = this.activeTunSignature.length > 0;
    snapshot.activeVpnInstanceName = attached ? this.activeVpnInstanceName : '';
    snapshot.activeVpnInstanceId = attached ? this.activeVpnInstanceId : '';
    snapshot.vpnConfig = this.activeTunConfig;
    snapshot.instances = entries === null ? this.readProInstances() : entries;
    snapshot.lastError = this.lastError;
    return JSON.stringify(snapshot);
  }


  private createVpnConnection(): Promise<vpnExtension.VpnConnection> {
    if (this.vpnConnection !== null) {
      return Promise.resolve(this.vpnConnection);
    }
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    return Promise.resolve(this.vpnConnection);
  }

  private prepareSocketProtection(): Promise<void> {
    return this.createVpnConnection().then(() => this.socketProtection.start());
  }

  private handleSocketProtectionFailure(error: Error): void {
    this.lastError = `HarmonyOS socket protection failed: ${this.errorMessage(error)}`;
    console.error(`[EasyTierProVpn] ${this.lastError}`);
    this.emitEvent('error', new ErrorPayload(this.lastError));
    this.handleRuntimeRequest('stopRuntime', new RuntimeParams()).catch((stopError: Error) => {
      console.error(`[EasyTierProVpn] protection fail-stop failed: ${this.errorMessage(stopError)}`);
    });
  }

  private destroyVpnConnection(): Promise<void> {
    return this.socketProtection.runConnectionOperation(async () => {
      if (this.vpnConnection !== null) {
        // Retain the connection handle: stopping only TUN does not stop the
        // config client, whose new transport sockets still require protection.
        await this.vpnConnection.destroy();
      }
    });
  }

  // Unchanged platform config rules: IPv4 interface address with default /24,
  // subnet routes with the interface address as gateway, dns passthrough, default
  // MTU, and never an allowlist/blocklist or multivpn id.
  private buildVpnConfig(input: RuntimeVpnConfig): vpnExtension.VpnConfig {
    const inputAddresses = this.safeStringArray(input.addresses);
    const addresses = inputAddresses.length > 0 ? inputAddresses : this.stringToArray(input.address);
    if (addresses.length === 0) {
      throw new Error('HarmonyOS VPN config missing address');
    }
    const primaryAddress = this.parseCidr(addresses[0], DEFAULT_ADDRESS_PREFIX);
    const inputRoutes = this.safeStringArray(input.routes);
    const routeCidrs = inputRoutes.length > 0 ? inputRoutes : this.stringToArray(input.route);
    const routes = routeCidrs
      .map((route: string): connection.RouteInfo | null => this.buildRouteInfo(route, primaryAddress.address))
      .filter((route: connection.RouteInfo | null): boolean => route !== null) as connection.RouteInfo[];
    const dns = this.firstNonEmptyStringArray(input.dns, input.dns_servers, input.dnsServers);
    const disallowedApplications = this.firstNonEmptyStringArray(
      input.disallowedApplications,
      input.disallowed_applications,
      input.disallowedPackages,
      input.disallowed_packages,
    );
    const mtu = input.mtu > 0 ? input.mtu : DEFAULT_MTU;

    // Use the ordinary single-VPN all-app/exclusion policy. Do not generate a
    // vpnId: older multi-VPN implementations require a real nonempty allowlist.
    const config: vpnExtension.VpnConfig = {
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
      mtu,
    };
    if (dns.length > 0) {
      config.dnsAddresses = dns;
    }
    if (disallowedApplications.length > 0) {
      config.blockedApplications = disallowedApplications;
    }
    return config;
  }

  // Core state to the platform config shape the rules above consume.
  private coreTunConfig(target: VpnRuntimeTarget): RuntimeVpnConfig {
    const derived = new RuntimeVpnConfig();
    derived.addresses = [target.address];
    derived.address = target.address;
    derived.routes = target.routes.slice();
    derived.dns = target.dns.slice();
    derived.mtu = target.mtu;
    return derived;
  }

  private buildRouteInfo(route: string, gateway: string): connection.RouteInfo | null {
    const cidr = this.normalizeIpv4Cidr(route, DEFAULT_ROUTE_PREFIX);
    if (cidr.length === 0) {
      return null;
    }
    const parts = cidr.split('/');
    const destination = parts[0];
    const prefix = Number.parseInt(parts[1], 10);
    return {
      interface: 'vpn-tun',
      destination: {
        address: {
          address: destination,
          family: IPV4_FAMILY,
        },
        prefixLength: prefix,
      },
      gateway: {
        address: gateway,
        family: IPV4_FAMILY,
      },
      hasGateway: true,
      isDefaultRoute: destination === '0.0.0.0' && prefix === 0,
    };
  }

  private readCidrList(values: Array<string>): Array<string> {
    const result: Array<string> = [];
    for (const value of values) {
      const cidr = this.normalizeIpv4Cidr(`${value}`, DEFAULT_ROUTE_PREFIX);
      if (cidr.length > 0 && !result.includes(cidr)) {
        result.push(cidr);
      }
    }
    return result;
  }

  private readAddressList(values: Array<string>): Array<string> {
    const result: Array<string> = [];
    for (const value of values) {
      const address = `${value}`.trim();
      if (this.isIpv4Address(address) && !result.includes(address)) {
        result.push(address);
      }
    }
    return result;
  }

  // Returns the normalized `address/prefix` for IPv4 input, or '' when the value
  // cannot be installed in the IPv4 TUN interface.
  private normalizeIpv4Cidr(value: string, defaultPrefix: number): string {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const parts = trimmed.split('/');
    const address = parts[0].trim();
    if (!this.isIpv4Address(address)) {
      return '';
    }
    let prefix = defaultPrefix;
    if (parts.length > 1) {
      const prefixText = parts[1].trim();
      if (!this.isDecimalText(prefixText)) {
        return '';
      }
      prefix = Number.parseInt(prefixText, 10);
      if (prefix > 32) {
        return '';
      }
    }
    return `${address}/${prefix}`;
  }

  private parseCidr(value: string, defaultPrefix: number): CidrParts {
    const normalized = this.normalizeIpv4Cidr(value, defaultPrefix);
    if (normalized.length === 0) {
      throw new Error(`invalid IPv4 cidr: ${value}`);
    }
    const parts = normalized.split('/');
    return { address: parts[0], prefix: Number.parseInt(parts[1], 10) };
  }

  private isIpv4Address(value: string): boolean {
    const parts = value.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (!this.isDecimalText(part) || part.length > 3) {
        return false;
      }
      const octet = Number.parseInt(part, 10);
      if (octet > 255) {
        return false;
      }
    }
    return true;
  }

  private isDecimalText(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private emitEvent(type: string, payload: RuntimeValue): void {
    this.ipcServer?.broadcastEvent(type, payload);
  }

  private stringToArray(value: string | undefined): Array<string> {
    return value !== undefined && value.length > 0 ? [value] : [];
  }

  private firstNonEmptyStringArray(
    first: Array<string> | undefined,
    second: Array<string> | undefined,
    third: Array<string> | undefined,
    fourth: Array<string> | undefined = [],
  ): Array<string> {
    const safeFirst = this.safeStringArray(first);
    const safeSecond = this.safeStringArray(second);
    const safeThird = this.safeStringArray(third);
    const safeFourth = this.safeStringArray(fourth);
    if (safeFirst.length > 0) {
      return safeFirst;
    }
    if (safeSecond.length > 0) {
      return safeSecond;
    }
    if (safeThird.length > 0) {
      return safeThird;
    }
    return safeFourth;
  }

  private safeStringArray(value: Array<string> | undefined): Array<string> {
    if (!Array.isArray(value)) {
      return [];
    }
    return value.map((item: string): string => `${item}`).filter((item: string): boolean => item.length > 0);
  }

  private errorMessage(error: Object): string {
    const typed = error as Error;
    return typed.message ?? `${error}`;
  }
}
