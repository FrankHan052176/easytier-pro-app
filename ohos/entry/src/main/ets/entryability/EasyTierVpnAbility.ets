import { Want } from '@kit.AbilityKit';
import { JSON } from '@kit.ArkTS';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import easytier from 'easytier-ohrs';
import {
  readArrayParam,
  readBoolParam,
  readObjectParam,
  readStringParam,
  RuntimeIpcServer,
  RuntimeParams,
  RuntimeValue,
  RuntimeVpnConfig,
} from '../runtime/OhosCoreRuntimeIpc';

const IPV4_FAMILY = 1;
const DEFAULT_MTU = 1380;
const DEFAULT_DNS = '223.5.5.5';
const EVENT_POLL_INTERVAL_MS = 500;

interface CidrParts {
  address: string;
  prefix: number;
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

export default class EasyTierVpnAbility extends VpnExtensionAbility {
  private ipcServer: RuntimeIpcServer | null = null;
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private eventTimer: number | null = null;
  private lastError: string = '';
  private coreInitialized: boolean = false;
  private processNetProtected: boolean = false;
  private activeVpnInstanceId: string = '';
  private activeVpnInstanceName: string = '';

  onCreate(want: Want): void {
    let params = new RuntimeParams();
    if (want.parameters !== undefined) {
      params = want.parameters as Object as RuntimeParams;
    }
    const filesDir = readStringParam(params, 'socketFilesDir') || this.context.filesDir;
    this.ensureCoreInitialized(filesDir);
    if (readStringParam(params, 'url').length === 0) {
      return;
    }

    this.ipcServer = new RuntimeIpcServer((method: string, requestParams: RuntimeParams) => {
      return this.handleRuntimeRequest(method, requestParams);
    });
    this.ipcServer.start(filesDir);
    console.info(`[EasyTierProVpn] starting config server client url=${readStringParam(params, 'url')}`);
    this.protectProcessNetwork()
      .then(() => {
        const url = readStringParam(params, 'url');
        const hostname = readStringParam(params, 'hostname');
        const machineId = readStringParam(params, 'machineId');
        const secureMode = readBoolParam(params, 'secureMode');
        const ok = easytier.startConfigServerClient(url, hostname, machineId, secureMode);
        if (!ok) {
          this.lastError = 'HarmonyOS EasyTier config server client start failed';
          console.error(`[EasyTierProVpn] ${this.lastError}`);
          this.emitEvent('error', new ErrorPayload(this.lastError));
          return;
        }
        console.info(`[EasyTierProVpn] config server client started machineId=${machineId}`);
        this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
        this.startEventPolling();
      })
      .catch((error: Error) => {
        this.lastError = `HarmonyOS process network protection failed: ${this.errorMessage(error)}`;
        console.error(`[EasyTierProVpn] ${this.lastError}`);
        this.emitEvent('error', new ErrorPayload(this.lastError));
      });
  }

  onDestroy(): void {
    this.stopEventPolling();
    try {
      easytier.stopRuntime();
    } catch (_) {
    }
    this.ipcServer?.close();
    this.ipcServer = null;
    this.destroyVpnConnection().catch((_error: Error) => {
    });
  }

  private handleRuntimeRequest(method: string, params: RuntimeParams): Promise<RuntimeValue> {
    try {
      switch (method) {
        case 'startConfigServerClient':
          return this.startConfigServerClient(params);
        case 'stopConfigServerClient':
          easytier.stopConfigServerClient();
          this.emitEvent('config_server_stopped', new EmptyPayload());
          return Promise.resolve(null);
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
          this.stopNetworkInstances(params);
          return Promise.resolve(null);
        case 'startVpn':
          return this.startVpn(params);
        case 'stopVpn':
          return this.stopVpn();
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
    return this.protectProcessNetwork().then(() => {
      const url = readStringParam(params, 'url');
      const hostname = readStringParam(params, 'hostname');
      const machineId = readStringParam(params, 'machineId');
      const secureMode = readBoolParam(params, 'secureMode');
      const ok = easytier.startConfigServerClient(url, hostname, machineId, secureMode);
      if (!ok) {
        this.lastError = 'HarmonyOS EasyTier config server client start failed';
        return Promise.reject(new Error(this.lastError));
      }
      this.emitEvent('config_server_started', new ConfigServerStartedPayload(url, hostname, machineId));
      this.startEventPolling();
      return null;
    });
  }

  private stopRuntime(): Promise<RuntimeValue> {
    this.stopEventPolling();
    easytier.stopRuntime();
    return this.destroyVpnConnection()
      .then(() => {
        this.activeVpnInstanceId = '';
        this.activeVpnInstanceName = '';
        this.emitEvent('config_server_stopped', new EmptyPayload());
        return null;
      });
  }

  private stopNetworkInstances(params: RuntimeParams): void {
    const instanceNames = readArrayParam(params, 'instanceNames');
    const instanceIds = instanceNames
      .map((name: string) => easytier.resolveInstanceId(name) ?? name)
      .filter((id: string) => id.length > 0);
    if (instanceIds.length > 0) {
      easytier.stopNetworkInstance(instanceIds);
    }
  }

  private startVpn(params: RuntimeParams): Promise<RuntimeValue> {
    const instanceName = readStringParam(params, 'instanceName');
    const vpnConfig = readObjectParam(params, 'vpnConfig');
    const instanceId = easytier.resolveInstanceId(instanceName) ?? instanceName;
    console.info(`[EasyTierProVpn] startVpn requested instanceName=${instanceName} instanceId=${instanceId}`);
    if (instanceId.length === 0) {
      this.lastError = 'HarmonyOS VPN instance id is empty';
      console.error(`[EasyTierProVpn] ${this.lastError}`);
      return Promise.reject(new Error(this.lastError));
    }

    const config = this.buildVpnConfig(vpnConfig);
    const configAddresses = config.addresses ?? [];
    const configRoutes = config.routes ?? [];
    console.info(`[EasyTierProVpn] startVpn config addresses=${configAddresses.length} routes=${configRoutes.length}`);
    return this.createVpnConnection()
      .then((vpnConnection) => this.protectProcessNetwork().then(() => vpnConnection))
      .then((vpnConnection) => vpnConnection.destroy().then(() => vpnConnection.create(config)))
      .then((fd: number) => {
        if (!easytier.setTunFd(instanceId, fd)) {
          this.lastError = `HarmonyOS setTunFd failed for ${instanceId}`;
          console.error(`[EasyTierProVpn] ${this.lastError}`);
          return Promise.reject(new Error(this.lastError));
        }
        this.activeVpnInstanceId = instanceId;
        this.activeVpnInstanceName = instanceName;
        console.info(`[EasyTierProVpn] vpn started instanceId=${instanceId} fd=${fd}`);
        this.emitEvent('vpn_started', new VpnStartedPayload(instanceName, instanceId, fd));
        return null;
      });
  }

  private stopVpn(): Promise<RuntimeValue> {
    const instanceName = this.activeVpnInstanceName;
    const instanceId = this.activeVpnInstanceId;
    return this.destroyVpnConnection()
      .then(() => {
        this.activeVpnInstanceName = '';
        this.activeVpnInstanceId = '';
        this.emitEvent('vpn_stopped', new VpnStoppedPayload(instanceName, instanceId));
        return null;
      });
  }

  private createVpnConnection(): Promise<vpnExtension.VpnConnection> {
    if (this.vpnConnection !== null) {
      return Promise.resolve(this.vpnConnection);
    }
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    return Promise.resolve(this.vpnConnection);
  }

  private protectProcessNetwork(): Promise<void> {
    if (this.processNetProtected) {
      return Promise.resolve();
    }
    return this.createVpnConnection()
      .then((vpnConnection) => vpnConnection.protectProcessNet())
      .then(() => {
        this.processNetProtected = true;
      });
  }

  private destroyVpnConnection(): Promise<void> {
    if (this.vpnConnection === null) {
      return Promise.resolve();
    }
    const vpnConnection = this.vpnConnection;
    this.vpnConnection = null;
    this.processNetProtected = false;
    return vpnConnection.destroy();
  }

  private buildVpnConfig(input: RuntimeVpnConfig): vpnExtension.VpnConfig {
    const inputAddresses = this.safeStringArray(input.addresses);
    const addresses = inputAddresses.length > 0 ? inputAddresses : this.stringToArray(input.address);
    if (addresses.length === 0) {
      throw new Error('HarmonyOS VPN config missing address');
    }
    const primaryAddress = this.parseCidr(addresses[0], 24);
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
    try {
      const raw = easytier.drainConfigServerEvents();
      const events = JSON.parse(raw) as Array<Object>;
      if (events.length > 0) {
        console.info(`[EasyTierProVpn] drain config events count=${events.length}`);
      }
      for (const event of events) {
        this.emitEvent('config_server', event);
      }
      if (events.length > 0) {
        this.emitEvent('runtime_instances_changed', new EmptyPayload());
      }
    } catch (error) {
      this.lastError = `HarmonyOS config server event drain failed: ${this.errorMessage(error)}`;
      this.emitEvent('error', new ErrorPayload(this.lastError));
    }
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
