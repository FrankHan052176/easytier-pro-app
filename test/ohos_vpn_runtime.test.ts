// Run: bun test test/ohos_vpn_runtime.test.ts
// Host-side behavior tests of the actual ArkTS implementation. OS/N-API calls
// are controlled boundaries; these do not replace on-device routing checks.
import { beforeAll, expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

const etsRoot = resolve(import.meta.dir, '../ohos/entry/src/main/ets');
let abilityCode: string;
let protectionCode: string;

async function compile(relativePath: string): Promise<string> {
  const result = await Bun.build({
    entrypoints: [resolve(etsRoot, relativePath)],
    target: 'node',
    format: 'cjs',
    external: ['@kit.*', 'easytier-ohrs'],
    plugins: [{
      name: 'arkts-host-tests',
      setup(build) {
        build.onLoad({ filter: /\.ets$/ }, async ({ path }) => ({
          contents: await readFile(path, 'utf8'), loader: 'ts',
        }));
        build.onResolve({ filter: /^\.\// }, ({ path, importer }) => {
          if (!importer.endsWith('.ets') || path.endsWith('.ets')) return;
          return { path: resolve(importer, '..', path + '.ets') };
        });
        build.onResolve({ filter: /^\.\.\// }, ({ path, importer }) => {
          if (!importer.endsWith('.ets') || path.endsWith('.ets')) return;
          return { path: resolve(importer, '..', path + '.ets') };
        });
      },
    }],
  });
  if (!result.success) throw new Error(result.logs.join('\n'));
  return result.outputs[0].text();
}

beforeAll(async () => {
  [abilityCode, protectionCode] = await Promise.all([
    compile('entryability/EasyTierVpnAbility.ets'),
    compile('runtime/NativeSocketProtectionService.ets'),
  ]);
});

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: Error) => void;
}

interface VpnConfig {
  addresses: { address: { address: string; family: number }; prefixLength: number }[];
  routes: { destination: { address: { address: string }; prefixLength: number } }[];
  mtu: number;
  blockedApplications?: string[];
  dnsAddresses?: string[];
}

interface EventSink {
  broadcastEvent(type: string, payload: unknown): void;
  close(): Promise<void>;
}

interface AbilityUnderTest {
  handleRuntimeRequest(method: string, params: Record<string, unknown>): Promise<unknown>;
  runtimeOperationQueue: Promise<void>;
  lastError: string;
  ipcServer: EventSink | null;
  onDestroy(): void;
}

interface ProtectionUnderTest {
  start(): Promise<void>;
  stop(): Promise<void>;
  runConnectionOperation<T>(operation: () => Promise<T>): Promise<T>;
}

interface ProtectionModule {
  NativeSocketProtectionService: new (
    getConnection: () => { protect(fd: number): Promise<void> },
    onFatal: (error: Error) => void,
  ) => ProtectionUnderTest;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

const drain = () => new Promise<void>((resolve) => setImmediate(resolve));
type Request = { requestId: string; socketFd: number; purpose: string };
type CoreInstanceSpec = { id: string; label: string; address: string | null; running?: boolean };
type RecordedEvent = { type: string; payload: unknown };

// Core serializes aggregate state with #[serde(rename_all = "camelCase")] and the
// Pro instance map as {"<network name>": "<instance uuid>"} (packaged commit
// c96b6c19), so these fixtures mirror exactly that wire shape.
function aggregateJson(specs: CoreInstanceSpec[], routes: string[], dns: string[]) {
  return JSON.stringify({
    instances: specs.map((spec) => ({
      configId: spec.id,
      instanceId: spec.id,
      displayName: spec.label,
      running: spec.running !== false,
      tunRequired: true,
      tunAttached: false,
      magicDnsEnabled: false,
      needExitNode: false,
      myNodeInfo: spec.address === null ? null : {
        virtualIpv4: spec.address.split('/')[0],
        virtualIpv4Cidr: spec.address,
        hostname: spec.label,
        listeners: [],
      },
      events: [],
      routes: [],
      peers: [],
    })),
    tun: {
      active: specs.length > 0,
      attachedInstanceIds: specs.map((spec) => spec.id),
      aggregatedRoutes: routes,
      dnsServers: dns,
      needRebuild: false,
    },
    runningInstanceCount: specs.length,
  });
}

interface Fixture {
  ability: AbilityUnderTest;
  service: ProtectionUnderTest;
  calls: string[];
  acks: { requestId: string; success: boolean }[];
  configs: VpnConfig[];
  errors: Error[];
  events: RecordedEvent[];
  request(method: string, params?: Record<string, unknown>): Promise<unknown>;
  startConfigClient(): Promise<unknown>;
  snapshot(): Promise<{
    configServerConnected: boolean;
    activeVpnInstanceName: string;
    activeVpnInstanceId: string;
    vpnConfig: VpnConfig | null;
    instances: Record<string, string>;
    lastError: string;
  }>;
  tick(times?: number): Promise<void>;
  fireTick(): Promise<void>;
  hasPolling(): boolean;
  collectStateCalls(): number;
  listProInstanceCalls(): number;
  eventPayloads(type: string): unknown[];
  setInstances(next: CoreInstanceSpec[]): void;
  setInstanceAddress(id: string, address: string): void;
  removeInstance(id: string): void;
  setAggregatedRoutes(routes: string[]): void;
  setTunDnsServers(values: string[]): void;
  setCorruptedProInstances(raw: string | null): void;
  setCorruptedAggregate(raw: string | null): void;
  rejectSetTunFd(): void;
  deferTunCreate(): Deferred<number>;
  rejectNextTunCreate(): void;
  rejectConnectionProbe(): void;
  publishRunEvent(instanceId: string, networkName: string): void;
  setProtect(value: (fd: number) => Promise<void>): void;
  rejectAcknowledgements(): void;
  rejectEnable(): void;
  closeStream(): void;
  send(id?: string, fd?: number): void;
}

function fixture(): Fixture {
  const calls: string[] = [];
  const acks: { requestId: string; success: boolean }[] = [];
  const configs: VpnConfig[] = [];
  const errors: Error[] = [];
  const events: RecordedEvent[] = [];
  const intervals = new Map<number, () => void>();
  let nextTimerId = 1;
  let enabled = false;
  let waiter: Deferred<Request | null> | undefined;
  const requests: Request[] = [];
  let protect: (fd: number) => Promise<void> = async () => {};
  let rejectAck = false;
  let failEnable = false;
  let setTunFdResult = true;
  let tunCreate: (() => Promise<number>) | undefined;
  let tunCreateFailures = 0;
  let collectStateCalls = 0;
  let listProInstanceCalls = 0;
  let proInstancesOverride: string | null = null;
  let aggregateOverride: string | null = null;
  let configServerConnected = false;
  let rejectConnectionProbe = false;
  const specs: CoreInstanceSpec[] = [];
  let aggregatedRoutes: string[] = [];
  let tunDnsServers: string[] = [];
  const coreEvents: unknown[] = [];

  const core = {
    enableSocketProtection() {
      calls.push('enable');
      if (failEnable) return false;
      enabled = true;
      return true;
    },
    failSocketProtection() {
      calls.push('fail-closed');
      enabled = false;
      requests.length = 0;
      waiter?.resolve(null);
      waiter = undefined;
      return true;
    },
    disableSocketProtection() { throw new Error('must not fail open'); },
    nextSocketProtectionRequest() {
      if (requests.length) return Promise.resolve(requests.shift());
      if (!enabled) return Promise.resolve(null);
      if (waiter) throw new Error('duplicate request consumer');
      waiter = deferred<Request | null>();
      return waiter.promise;
    },
    completeSocketProtection(requestId: string, success: boolean) {
      calls.push(`ack:${requestId}:${success}`);
      acks.push({ requestId, success });
      return !rejectAck;
    },
    startConfigServerClient() { calls.push('start-client'); return true; },
    stopConfigServerClient() { calls.push('stop-client'); return true; },
    stopRuntime() { calls.push('stop-runtime'); return true; },
    stopNetworkInstance() { calls.push('stop-instances'); return true; },
    resolveInstanceId(name: string) { return name; },
    isConfigServerClientConnected() {
      if (rejectConnectionProbe) throw new Error('native connection probe failed');
      return configServerConnected;
    },
    collectRuntimeStateJson() {
      collectStateCalls += 1;
      return aggregateOverride ?? aggregateJson(specs, aggregatedRoutes, tunDnsServers);
    },
    listProInstancesJson() {
      listProInstanceCalls += 1;
      if (proInstancesOverride !== null) return proInstancesOverride;
      const map: Record<string, string> = {};
      for (const spec of specs) {
        if (spec.running !== false) map[spec.label] = spec.id;
      }
      return JSON.stringify(map);
    },
    drainConfigServerEvents() { return JSON.stringify(coreEvents.splice(0, coreEvents.length)); },
    setTunFd(instanceId: string, fd: number) {
      calls.push(`set-tun:${instanceId}:${fd}`);
      return setTunFdResult;
    },
    initLogManager() {},
    configureLogManager() {},
    initConfigStore() {},
    initPanicHook() {},
  };
  const connection = {
    async protect(fd: number) { calls.push(`protect:${fd}`); await protect(fd); },
    async protectProcessNet() { throw new Error('process-wide bypass breaks TUN-facing sockets'); },
    async create(config: VpnConfig) {
      calls.push('create-tun');
      configs.push(config);
      if (tunCreateFailures > 0) {
        tunCreateFailures -= 1;
        throw new Error('platform refused');
      }
      return tunCreate === undefined ? 42 : tunCreate();
    },
    async destroy() { calls.push('destroy-tun'); },
  };
  const modules: Record<string, unknown> = {
    'easytier-ohrs': core,
    '@kit.NetworkKit': {
      VpnExtensionAbility: class {},
      vpnExtension: { createVpnConnection: () => connection },
    },
    '@kit.ArkTS': { JSON },
    '@kit.CoreFileKit': {},
    '@kit.AbilityKit': {},
    '@kit.BasicServicesKit': {},
  };
  function load<T>(code: string): T {
    const module = { exports: {} };
    runInNewContext(code, {
      module, exports: module.exports,
      require: (name: string) => {
        if (!(name in modules)) throw new Error(`Unexpected dependency: ${name}`);
        return modules[name];
      },
      console: { info() {}, error() {}, warn() {} },
      setInterval: (callback: () => void) => {
        const id = nextTimerId++;
        intervals.set(id, callback);
        return id;
      },
      clearInterval: (id: number) => { intervals.delete(id); },
      setTimeout, clearTimeout,
    });
    // These are exports from our compiled source, not external input.
    return module.exports as T;
  }
  const abilityModule = load<{ default: new () => AbilityUnderTest }>(abilityCode);
  const ability = new abilityModule.default();
  // Stand-in for the IPC server: no UI client is ever connected in these cases,
  // the sink only records what the native runtime chose to publish.
  ability.ipcServer = {
    broadcastEvent(type: string, payload: unknown) { events.push({ type, payload }); },
    async close() {},
  } as EventSink;
  const service = new (load<ProtectionModule>(protectionCode).NativeSocketProtectionService)(
    () => connection, (error: Error) => errors.push(error),
  );
  const request = (method: string, params: Record<string, unknown> = {}) =>
    ability.handleRuntimeRequest(method, params);
  return {
    ability, service, calls, acks, configs, errors, events,
    setProtect(value: (fd: number) => Promise<void>) { protect = value; },
    rejectAcknowledgements() { rejectAck = true; },
    rejectEnable() { failEnable = true; },
    closeStream() { waiter?.resolve(null); waiter = undefined; },
    send(id = '1', fd = 17) {
      if (!enabled) throw new Error('protection is not enabled');
      const r = { requestId: id, socketFd: fd, purpose: 'socket' };
      if (waiter) { const pending = waiter; waiter = undefined; pending.resolve(r); }
      else requests.push(r);
    },
    request,
    // Drives the extension the way the OS does: the control client is started,
    // then only the extension's own 500 ms supervision loop runs.
    async startConfigClient() {
      const started = await request('startConfigServerClient', { url: 'udp://test.invalid' });
      configServerConnected = true;
      return started;
    },
    async snapshot() {
      return JSON.parse(await request('getRuntimeSnapshot') as string);
    },
    // Fires the extension's own interval callbacks without waiting for the
    // queued reconcile work, for cases where that work is deliberately blocked.
    async fireTick() {
      for (const callback of [...intervals.values()]) callback();
      await drain();
      await drain();
    },
    async tick(times = 1) {
      for (let index = 0; index < times; index++) {
        for (const callback of [...intervals.values()]) callback();
        await drain();
        await ability.runtimeOperationQueue;
        await drain();
      }
    },
    hasPolling() { return intervals.size > 0; },
    collectStateCalls() { return collectStateCalls; },
    listProInstanceCalls() { return listProInstanceCalls; },
    eventPayloads(type: string) {
      return events.filter((event) => event.type === type).map((event) => event.payload);
    },
    setInstances(next: CoreInstanceSpec[]) { specs.length = 0; specs.push(...next); },
    setInstanceAddress(id: string, address: string) {
      for (const spec of specs) { if (spec.id === id) spec.address = address; }
    },
    removeInstance(id: string) {
      const index = specs.findIndex((spec) => spec.id === id);
      if (index >= 0) specs.splice(index, 1);
    },
    setAggregatedRoutes(routes: string[]) { aggregatedRoutes = routes; },
    setTunDnsServers(values: string[]) { tunDnsServers = values; },
    setCorruptedProInstances(raw: string | null) { proInstancesOverride = raw; },
    setCorruptedAggregate(raw: string | null) { aggregateOverride = raw; },
    rejectSetTunFd() { setTunFdResult = false; },
    deferTunCreate() {
      const pending = deferred<number>();
      tunCreate = () => pending.promise;
      return pending;
    },
    rejectNextTunCreate() { tunCreateFailures += 1; },
    rejectConnectionProbe() { rejectConnectionProbe = true; },
    publishRunEvent(instanceId: string, networkName: string) {
      coreEvents.push({
        event: 'run_network_instance',
        success: true,
        instance_id: instanceId,
        instance_name: instanceId,
        network_name: networkName,
      });
    },
  };
}

const count = (list: string[], value: string) => list.filter((entry) => entry === value).length;
const routeCidrs = (config: VpnConfig) =>
  config.routes.map((route) => `${route.destination.address.address}/${route.destination.prefixLength}`);
const officeInstance = (address: string | null = '10.144.144.1/24'): CoreInstanceSpec =>
  ({ id: 'inst-a', label: 'office-net', address });

test('stopping the runtime stops polling so a stale tick cannot re-attach the TUN', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  expect(f.calls).toContain('set-tun:inst-a:42');
  expect(f.hasPolling()).toBe(true);

  await f.request('stopRuntime');
  expect(f.hasPolling()).toBe(false);
  const collectsAfterStop = f.collectStateCalls();
  f.setInstances([{ id: 'inst-b', label: 'lab-net', address: '10.144.145.1/24' }]);
  await f.tick(5);
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect(f.collectStateCalls()).toBe(collectsAfterStop);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');
  expect(f.eventPayloads('config_server_stopped')).toHaveLength(1);

  // Ownership was released, so the same bootstrap starts a fresh client again.
  await f.startConfigClient();
  expect(count(f.calls, 'start-client')).toBe(2);
  expect(f.hasPolling()).toBe(true);
  await f.request('stopRuntime');
});

test('a tick already queued behind stopRuntime cannot resurrect the stopped child', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const protect = deferred<void>();
  f.setProtect(() => protect.promise);
  f.send();
  await drain();
  const teardown = f.request('stopNetworkInstances', { instanceNames: ['mesh'] });
  const stopping = f.request('stopRuntime');
  await f.fireTick();
  protect.resolve();
  await Promise.all([teardown, stopping]);
  await f.ability.runtimeOperationQueue;
  await f.request('resumeVpn');
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');
  expect(f.hasPolling()).toBe(false);
});

test('a repeated start with the same bootstrap keeps the owned client and the TUN', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);
  const enablesAfterStart = count(f.calls, 'enable');

  // e.g. a readStatus transport failure re-running ensureRunning while the child
  // still owns a healthy client.
  await f.request('startConfigServerClient', { url: 'udp://test.invalid' });
  expect(count(f.calls, 'start-client')).toBe(1);
  expect(count(f.calls, 'stop-client')).toBe(1);
  expect(count(f.calls, 'enable')).toBe(enablesAfterStart);
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect(count(f.calls, 'destroy-tun')).toBe(1);
  expect(f.eventPayloads('config_server_started')).toHaveLength(1);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');

  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);
  await f.request('stopRuntime');
});

test('a changed bootstrap replaces the owned client', async () => {
  const f = fixture();
  await f.startConfigClient();
  const stopsAfterStart = count(f.calls, 'stop-client');

  await f.request('startConfigServerClient', {
    url: 'udp://replacement.invalid', hostname: 'other', machineId: 'other-machine', secureMode: true,
  });
  expect(count(f.calls, 'stop-client')).toBe(stopsAfterStart + 1);
  expect(count(f.calls, 'start-client')).toBe(2);
  expect(f.eventPayloads('config_server_started')).toHaveLength(2);
  await f.request('stopRuntime');
});

test('an explicit stop releases client ownership so the same bootstrap can start again', async () => {
  const f = fixture();
  await f.startConfigClient();
  await f.request('stopConfigServerClient');
  await f.request('startConfigServerClient', { url: 'udp://test.invalid' });
  expect(count(f.calls, 'start-client')).toBe(2);
  await f.request('stopRuntime');
});

test('without any UI client the loop attaches the TUN from Core state', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24', '192.168.9.0/24']);
  await f.startConfigClient();
  await f.tick();

  expect(f.calls).toContain('set-tun:inst-a:42');
  expect(f.calls.indexOf('enable')).toBeLessThan(f.calls.indexOf('create-tun'));
  const config = f.configs[0];
  expect(routeCidrs(config)).toEqual(['10.144.144.0/24', '192.168.9.0/24']);
  expect(config.addresses[0].address.address).toBe('10.144.144.1');
  expect(config.addresses[0].prefixLength).toBe(24);
  expect(config.mtu).toBe(1380);
  expect(Object.hasOwn(config, 'blockedApplications')).toBe(false);
  expect(Object.hasOwn(config, 'trustedApplications')).toBe(false);
  expect(Object.hasOwn(config, 'vpnId')).toBe(false);
  expect(f.eventPayloads('vpn_started')[0]).toMatchObject({ instanceId: 'inst-a', fd: 42 });

  const snapshot = await f.snapshot();
  expect(snapshot.activeVpnInstanceId).toBe('inst-a');
  expect(snapshot.activeVpnInstanceName).toBe('office-net');
  expect(snapshot.instances).toEqual({ 'office-net': 'inst-a' });
  expect(snapshot.vpnConfig.routes).toEqual(['10.144.144.0/24', '192.168.9.0/24']);
  expect(snapshot.configServerConnected).toBe(true);
  expect(snapshot.lastError).toBe('');
  const published = JSON.parse(f.eventPayloads('runtime_snapshot')[0] as string);
  expect(published.activeVpnInstanceId).toBe('inst-a');
  expect(published.vpnConfig.addresses).toEqual(['10.144.144.1/24']);
});

test('Core DNS servers are installed into the TUN config', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  f.setTunDnsServers(['10.144.144.3']);
  await f.startConfigClient();
  await f.tick();
  expect(f.configs[0].dnsAddresses).toEqual(['10.144.144.3']);
  await f.request('stopRuntime');
});

test('the TUN waits for a usable instance address and drops unusable routes', async () => {
  const f = fixture();
  f.setInstances([officeInstance(null)]);
  f.setAggregatedRoutes(['2001:db8::/64', 'not-a-cidr']);
  await f.startConfigClient();
  await f.tick(3);
  expect(count(f.calls, 'create-tun')).toBe(0);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');

  f.setInstanceAddress('inst-a', '10.144.144.7/24');
  f.setAggregatedRoutes(['10.144.144.0/24', '2001:db8::/64']);
  await f.tick();
  expect(f.configs[f.configs.length - 1].addresses[0].address.address).toBe('10.144.144.7');
  expect(routeCidrs(f.configs[f.configs.length - 1])).toEqual(['10.144.144.0/24']);
  await f.request('stopRuntime');
});

test('a Core route change rebuilds the TUN once and an unchanged config stays', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);

  const destroysAfterAttach = count(f.calls, 'destroy-tun');
  await f.tick(3);
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach);
  expect(f.eventPayloads('vpn_started')).toHaveLength(1);

  f.setAggregatedRoutes(['10.144.144.0/24', '10.20.0.0/16']);
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(2);
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach + 1);
  expect(routeCidrs(f.configs[f.configs.length - 1])).toEqual(['10.144.144.0/24', '10.20.0.0/16']);
  expect(f.eventPayloads('vpn_started')).toHaveLength(2);

  await f.tick(2);
  expect(count(f.calls, 'create-tun')).toBe(2);
  await f.request('stopRuntime');
});

test('a disappearing Pro instance stops the TUN', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const destroysAfterAttach = count(f.calls, 'destroy-tun');

  f.removeInstance('inst-a');
  await f.tick();
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach + 1);
  expect(f.eventPayloads('vpn_stopped')[0]).toMatchObject({ instanceId: 'inst-a' });
  const snapshot = await f.snapshot();
  expect(snapshot.activeVpnInstanceId).toBe('');
  expect(snapshot.activeVpnInstanceName).toBe('');
  expect(snapshot.vpnConfig).toBe(null);
  expect(snapshot.instances).toEqual({});
  await f.tick(2);
  expect(count(f.calls, 'create-tun')).toBe(1);
  await f.request('stopRuntime');
});

test('stopVpn stays stopped across ticks and resumeVpn applies the latest Core routes', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const destroysAfterAttach = count(f.calls, 'destroy-tun');

  await f.request('stopVpn');
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach + 1);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');

  f.setAggregatedRoutes(['10.144.144.0/24', '10.30.0.0/16']);
  await f.request('stopVpn'); // A retried exit must not release the suspension.
  await f.tick(4);
  expect(count(f.calls, 'create-tun')).toBe(1);

  await f.request('resumeVpn');
  expect(count(f.calls, 'create-tun')).toBe(2);
  expect(routeCidrs(f.configs[f.configs.length - 1])).toEqual(['10.144.144.0/24', '10.30.0.0/16']);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');
  await f.request('stopRuntime');
});

test('stopVpn does not block a different instance that joins later', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  await f.request('stopVpn');

  f.setInstances([{ id: 'inst-b', label: 'lab-net', address: '10.144.145.1/24' }]);
  await f.tick();
  expect(f.calls).toContain('set-tun:inst-b:42');
  expect(f.configs[f.configs.length - 1].addresses[0].address.address).toBe('10.144.145.1');
  await f.request('stopRuntime');
});

test('stop before the first address suppresses attachment until the instance disappears', async () => {
  const f = fixture();
  f.setInstances([officeInstance(null)]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  await f.request('stopVpn');
  f.setInstanceAddress('inst-a', '10.144.144.1/24');
  await f.tick(2);
  expect(count(f.calls, 'create-tun')).toBe(0);
  f.setInstances([]);
  await f.tick();
  f.setInstances([officeInstance()]);
  await f.tick();
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');
  expect(count(f.calls, 'create-tun')).toBe(1);
  await f.request('stopRuntime');
});

test('failed explicit resume rejects and leaves no reported TUN attachment', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  await f.request('stopVpn');
  f.rejectNextTunCreate();
  await expect(f.request('resumeVpn')).rejects.toThrow();
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');
  expect((await f.snapshot()).vpnConfig).toBe(null);
  await f.tick();
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');
  await f.request('stopRuntime');
});

test('the loop prefers the instance Core reported as started last', async () => {
  const f = fixture();
  f.setInstances([
    { id: 'inst-b', label: 'lab-net', address: '10.144.145.1/24' },
    { id: 'inst-a', label: 'office-net', address: '10.144.144.1/24' },
  ]);
  f.setAggregatedRoutes(['10.144.144.0/24', '10.144.145.0/24']);
  await f.startConfigClient();
  f.publishRunEvent('inst-b', 'lab-net');
  await f.tick();
  expect(f.calls).toContain('set-tun:inst-b:42');
  expect(f.eventPayloads('config_server')).toHaveLength(1);
  await f.request('stopRuntime');
});

test('an unchanged state publishes no further snapshots but a late reader still sees it', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const published = f.eventPayloads('runtime_snapshot').length;
  await f.tick(4);
  expect(f.eventPayloads('runtime_snapshot')).toHaveLength(published);

  // A client that lost every event reads the real attach through the snapshot.
  const snapshot = await f.snapshot();
  expect(snapshot.activeVpnInstanceId).toBe('inst-a');
  expect(snapshot.vpnConfig.addresses).toEqual(['10.144.144.1/24']);
  // Protected sockets keep being serviced while the loop owns the runtime.
  f.send('77', 23);
  await drain();
  expect(f.acks.at(-1)).toEqual({ requestId: '77', success: true });
  await f.request('stopRuntime');
});

test('an unusable Core snapshot neither fabricates a detached state nor tears the TUN down', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const destroysAfterAttach = count(f.calls, 'destroy-tun');

  f.setCorruptedProInstances('{"broken"');
  await expect(f.request('getRuntimeSnapshot')).rejects.toThrow('not valid JSON');
  expect(f.ability.lastError).toContain('not valid JSON');
  await f.tick(2);
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach);
  expect(f.eventPayloads('error').length).toBeGreaterThan(0);

  f.setCorruptedProInstances(null);
  f.setCorruptedAggregate('{}');
  await f.tick(2);
  expect(count(f.calls, 'destroy-tun')).toBe(destroysAfterAttach);
  expect(count(f.calls, 'create-tun')).toBe(1);
  const snapshot = await f.snapshot();
  expect(snapshot.activeVpnInstanceId).toBe('inst-a');
  expect(snapshot.instances).toEqual({ 'office-net': 'inst-a' });

  f.setCorruptedAggregate(null);
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);
  await f.request('stopRuntime');
});

test('a failed native connection probe cannot become a cached authoritative snapshot', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  expect((await f.snapshot()).configServerConnected).toBe(true);
  f.rejectConnectionProbe();
  await expect(f.snapshot()).rejects.toThrow();
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect(count(f.calls, 'stop-runtime')).toBe(0);
  await f.request('stopRuntime');
});

test('a rejected setTunFd never reports a fake attachment', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  f.rejectSetTunFd();
  await f.startConfigClient();
  await f.tick();
  expect(f.ability.lastError).toContain('setTunFd failed');
  const snapshot = await f.snapshot();
  expect(snapshot.activeVpnInstanceId).toBe('');
  expect(snapshot.vpnConfig).toBe(null);
  expect(f.eventPayloads('vpn_started')).toHaveLength(0);
  await f.request('stopRuntime');
});

test('a delayed TUN create cannot survive extension shutdown', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  const pendingCreate = f.deferTunCreate();
  await f.fireTick();
  expect(f.calls).not.toContain('set-tun:inst-a:42');

  f.ability.onDestroy();
  pendingCreate.resolve(42);
  await f.ability.runtimeOperationQueue;
  await drain();
  await drain();
  expect(f.calls).not.toContain('set-tun:inst-a:42');
  expect(f.calls.lastIndexOf('destroy-tun')).toBeGreaterThan(f.calls.lastIndexOf('create-tun'));
  expect(f.calls).toContain('stop-runtime');
  expect(f.hasPolling()).toBe(false);
  await expect(f.request('getRuntimeSnapshot')).rejects.toThrow('shutting down');
});

test('a failing TUN create never reports an attach and is retried by the next tick', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  f.rejectNextTunCreate();
  await f.startConfigClient();
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(1);
  expect(f.calls).not.toContain('set-tun:inst-a:42');
  expect(f.ability.lastError).toContain('platform refused');
  const rejected = await f.snapshot();
  expect(rejected.activeVpnInstanceId).toBe('');
  expect(rejected.vpnConfig).toBe(null);
  expect(f.eventPayloads('vpn_started')).toHaveLength(0);

  // No separate retry policy: the coalesced supervision loop retries next tick.
  await f.tick();
  expect(count(f.calls, 'create-tun')).toBe(2);
  expect(f.calls).toContain('set-tun:inst-a:42');
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');
  await f.request('stopRuntime');
});

test('the control client is not started when socket protection cannot be enabled', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.rejectEnable();
  await expect(f.startConfigClient()).rejects.toThrow('could not be enabled');
  expect(f.calls).not.toContain('create-tun');
  expect(f.calls).not.toContain('start-client');
  expect(f.hasPolling()).toBe(false);
  await f.tick(2);
  expect(count(f.calls, 'create-tun')).toBe(0);
});

test('does not ACK until OS protection succeeds; serializes TUN operations', async () => {
  const f = fixture();
  const protectedFd = deferred<void>();
  f.setProtect(() => protectedFd.promise);
  await f.service.start();
  f.send();
  await drain();
  const operation = f.service.runConnectionOperation(async () => { f.calls.push('rebuild'); });
  expect(f.acks).toHaveLength(0);
  expect(f.calls).not.toContain('rebuild');
  protectedFd.resolve();
  await operation;
  await drain();
  expect(f.acks).toEqual([{ requestId: '1', success: true }]);
  await f.service.stop();
});

test('OS protection failure NACKs that socket and keeps the pump alive', async () => {
  const f = fixture();
  f.setProtect(async () => { throw new Error('permission denied'); });
  await f.service.start();
  f.send();
  await drain();
  expect(f.acks).toEqual([{ requestId: '1', success: false }]);
  expect(f.errors).toHaveLength(0);
  f.setProtect(async () => {});
  f.send('2');
  await drain();
  expect(f.acks[1]).toEqual({ requestId: '2', success: true });
  await f.service.stop();
});

test('stream closure alone triggers fail-stop', async () => {
  const f = fixture();
  await f.service.start();
  f.closeStream();
  await drain();
  expect(f.errors).toHaveLength(1);
  expect(f.calls).toContain('fail-closed');
  await f.service.stop();
});

test('a released ACK is not fatal', async () => {
  const f = fixture();
  await f.service.start();
  f.rejectAcknowledgements();
  f.send();
  await drain();
  expect(f.acks).toEqual([{ requestId: '1', success: true }]);
  expect(f.errors).toHaveLength(0);
  f.send('2');
  await drain();
  expect(f.acks[1]).toEqual({ requestId: '2', success: true });
  await f.service.stop();
});

test('stop retains in-flight FD until OS returns, NACKs it, then permits restart', async () => {
  const f = fixture();
  const protectedFd = deferred<void>();
  f.setProtect(() => protectedFd.promise);
  await f.service.start();
  f.send();
  await drain();
  const stopping = f.service.stop();
  const restarting = f.service.start();
  await drain();
  expect(f.acks).toHaveLength(0);
  expect(f.calls.filter((call) => call === 'enable')).toHaveLength(1);
  protectedFd.resolve();
  await stopping;
  await restarting;
  expect(f.acks).toEqual([{ requestId: '1', success: false }]);
  f.send('2');
  await drain();
  expect(f.acks[1]).toEqual({ requestId: '2', success: true });
  await f.service.stop();
});

test('runtime stop waits for protection ACK before synchronous native teardown', async () => {
  const f = fixture();
  const protectedFd = deferred<void>();
  f.setProtect(() => protectedFd.promise);
  await f.request('startConfigServerClient', { url: 'udp://test.invalid' });
  f.send();
  await drain();
  const stopping = f.request('stopRuntime');
  await drain();
  expect(f.calls).not.toContain('stop-runtime');
  protectedFd.resolve();
  await stopping;
  expect(f.calls.indexOf('ack:1:false')).toBeLessThan(f.calls.indexOf('stop-runtime'));
  expect(f.calls.indexOf('stop-runtime')).toBeLessThan(f.calls.indexOf('destroy-tun'));
});

test('a per-socket protection failure keeps the autonomous runtime served', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  f.setProtect(async () => { throw new Error('protect failed'); });
  await f.startConfigClient();
  await f.tick();
  f.send();
  await drain();
  expect(f.acks).toEqual([{ requestId: '1', success: false }]);
  expect(f.ability.lastError).toBe('');
  expect(f.calls).not.toContain('stop-runtime');
  expect(count(f.calls, 'create-tun')).toBe(1);
  await f.request('stopRuntime');
});

test('TUN-only stop keeps config client protection working; runtime restart is serialized', async () => {
  const f = fixture();
  try {
    f.setInstances([officeInstance()]);
    f.setAggregatedRoutes(['10.144.144.0/24']);
    await f.startConfigClient();
    await f.tick();
    await f.request('stopVpn');
    f.send();
    await drain();
    expect(f.acks[0].success).toBe(true);
    const stop = f.request('stopRuntime');
    const start = f.request('startConfigServerClient', { url: 'udp://replacement.invalid' });
    await Promise.all([stop, start]);
    expect(count(f.calls, 'start-client')).toBe(2);
    expect(f.calls.indexOf('stop-runtime')).toBeLessThan(f.calls.lastIndexOf('start-client'));
    f.send('2');
    await drain();
    expect(f.acks[1].success).toBe(true);
  } finally { await f.request('stopRuntime'); }
});

for (const method of ['stopConfigServerClient', 'stopNetworkInstances', 'startConfigServerClient']) {
  test(`${method} drains ACKs before native teardown and resumes surviving protection`, async () => {
    const f = fixture();
    const protectedFd = deferred<void>();
    f.setProtect(() => protectedFd.promise);
    await f.request('startConfigServerClient', { url: 'udp://test.invalid' });
    f.calls.length = 0;
    f.send();
    await drain();
    const operation = f.request(method, {
      instanceNames: ['mesh'], url: 'udp://replacement.invalid',
    });
    await drain();
    expect(f.calls).not.toContain('stop-client');
    expect(f.calls).not.toContain('stop-instances');
    expect(f.calls).not.toContain('start-client');
    protectedFd.resolve();
    await operation;
    const stopCall = method === 'stopNetworkInstances' ? 'stop-instances' : 'stop-client';
    expect(f.calls).toContain(stopCall);
    expect(f.calls.indexOf('ack:1:false')).toBeLessThan(f.calls.indexOf(stopCall));
    expect(f.calls.indexOf(stopCall)).toBeLessThan(f.calls.indexOf('enable'));
    if (method === 'startConfigServerClient') {
      expect(f.calls.indexOf('enable')).toBeLessThan(f.calls.indexOf('start-client'));
    }
    f.send('2');
    await drain();
    expect(f.acks[1]).toEqual({ requestId: '2', success: true });
    await f.request('stopRuntime');
  });
}

test('Core overwrite of the active UUID reattaches even when its routes are unchanged', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  f.publishRunEvent('inst-a', 'office-net');
  await f.tick();
  expect(count(f.calls, 'set-tun:inst-a:42')).toBe(2);
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-a');
  await f.tick(2);
  expect(count(f.calls, 'create-tun')).toBe(2);
  await f.request('stopRuntime');
});

test('a removed owner detaches while its replacement waits for an address', async () => {
  const f = fixture();
  f.setInstances([officeInstance()]);
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  f.setInstances([{ id: 'inst-b', label: 'lab-net', address: null }]);
  await f.tick();
  expect((await f.snapshot()).activeVpnInstanceId).toBe('');
  expect((await f.snapshot()).vpnConfig).toBe(null);
  expect(count(f.calls, 'destroy-tun')).toBe(2);
  f.setInstanceAddress('inst-b', '10.144.145.1/24');
  await f.tick();
  expect((await f.snapshot()).activeVpnInstanceId).toBe('inst-b');
  await f.request('stopRuntime');
});

test('snapshot reads and events preserve a legal __proto__ network label', async () => {
  const f = fixture();
  f.setInstances([{ id: 'inst-a', label: '__proto__', address: '10.144.144.1/24' }]);
  f.setCorruptedProInstances('{"__proto__":"inst-a"}');
  f.setAggregatedRoutes(['10.144.144.0/24']);
  await f.startConfigClient();
  await f.tick();
  const snapshot = await f.snapshot();
  expect(Object.hasOwn(snapshot.instances, '__proto__')).toBe(true);
  expect(snapshot.instances['__proto__']).toBe('inst-a');
  const eventSnapshot = JSON.parse(String(f.eventPayloads('runtime_snapshot').at(-1)));
  expect(Object.hasOwn(eventSnapshot.instances, '__proto__')).toBe(true);
  expect(eventSnapshot.instances['__proto__']).toBe('inst-a');
  expect(snapshot.activeVpnInstanceName).toBe('__proto__');
  await f.request('stopRuntime');
});
