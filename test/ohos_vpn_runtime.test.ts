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
  routes: { destination: { address: { address: string }; prefixLength: number } }[];
  blockedApplications?: string[];
  dnsAddresses?: string[];
}

interface AbilityUnderTest {
  handleRuntimeRequest(method: string, params: Record<string, unknown>): Promise<unknown>;
  runtimeOperationQueue: Promise<void>;
  lastError: string;
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

function fixture() {
  const calls: string[] = [];
  const acks: { requestId: string; success: boolean }[] = [];
  const configs: VpnConfig[] = [];
  const errors: Error[] = [];
  let enabled = false;
  let waiter: Deferred<Request | null> | undefined;
  const requests: Request[] = [];
  let protect: (fd: number) => Promise<void> = async () => {};
  let rejectAck = false;
  let failEnable = false;
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
    setTunFd() { calls.push('set-tun'); return true; },
  };
  const connection = {
    async protect(fd: number) { calls.push(`protect:${fd}`); await protect(fd); },
    async protectProcessNet() { throw new Error('process-wide bypass breaks TUN-facing sockets'); },
    async create(config: VpnConfig) { calls.push('create-tun'); configs.push(config); return 42; },
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
      setInterval: () => 1, clearInterval() {}, setTimeout, clearTimeout,
    });
    // These are exports from our compiled source, not external input.
    return module.exports as T;
  }
  const abilityModule = load<{ default: new () => AbilityUnderTest }>(abilityCode);
  const ability = new abilityModule.default();
  const service = new (load<ProtectionModule>(protectionCode).NativeSocketProtectionService)(
    () => connection, (error: Error) => errors.push(error),
  );
  return {
    ability, service, core, connection, calls, acks, configs, errors,
    setProtect(value: (fd: number) => Promise<void>) { protect = value; },
    rejectAcknowledgements() { rejectAck = true; },
    rejectEnable() { failEnable = true; },
    closeStream() { waiter?.resolve(null); waiter = undefined; },
    send(id = '1', fd = 17) {
      if (!enabled) throw new Error('protection is not enabled');
      const request = { requestId: id, socketFd: fd, purpose: 'socket' };
      if (waiter) { const pending = waiter; waiter = undefined; pending.resolve(request); }
      else requests.push(request);
    },
    request(method: string, params: Record<string, unknown> = {}) {
      return ability.handleRuntimeRequest(method, params);
    },
  };
}

const vpnParams = (extra = {}) => ({
  instanceName: 'mesh',
  vpnConfig: { addresses: ['10.10.0.2/24'], routes: ['192.168.5.0/24'], mtu: 1380, ...extra },
});

test('ordinary VPN omits empty allowlist and multivpn id, retaining subnet routes', async () => {
  const f = fixture();
  try {
    await f.request('startVpn', vpnParams());
    const config = f.configs[0];
    expect(Object.hasOwn(config, 'trustedApplications')).toBe(false);
    expect(Object.hasOwn(config, 'blockedApplications')).toBe(false);
    expect(Object.hasOwn(config, 'vpnId')).toBe(false);
    expect(config.routes[0].destination.address.address).toBe('192.168.5.0');
    expect(config.routes[0].destination.prefixLength).toBe(24);
    expect(f.calls.indexOf('enable')).toBeLessThan(f.calls.indexOf('create-tun'));
  } finally { await f.request('stopRuntime'); }
});

for (const field of ['disallowedApplications', 'disallowed_applications', 'disallowedPackages', 'disallowed_packages']) {
  test(`preserves ${field} exclusions without creating a whitelist`, async () => {
    const f = fixture();
    try {
      await f.request('startVpn', vpnParams({ [field]: ['example.blocked'], dns: ['10.10.0.1'] }));
      expect(f.configs[0].blockedApplications).toEqual(['example.blocked']);
      expect(Object.hasOwn(f.configs[0], 'trustedApplications')).toBe(false);
      expect(f.configs[0].dnsAddresses).toEqual(['10.10.0.1']);
    } finally { await f.request('stopRuntime'); }
  });
}

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

test('OS protection failure NACKs and leaves Core fail-closed', async () => {
  const f = fixture();
  f.setProtect(async () => { throw new Error('permission denied'); });
  await f.service.start();
  f.send();
  await drain();
  expect(f.acks).toEqual([{ requestId: '1', success: false }]);
  expect(f.calls).toContain('fail-closed');
  expect(f.errors[0].message).toBe('permission denied');
  await f.service.stop();
});

test('stream closure and rejected ACK trigger fail-stop', async () => {
  for (const failure of ['stream', 'ack']) {
    const f = fixture();
    await f.service.start();
    if (failure === 'stream') f.closeStream();
    else { f.rejectAcknowledgements(); f.send(); }
    await drain();
    expect(f.errors).toHaveLength(1);
    expect(f.calls).toContain('fail-closed');
    await f.service.stop();
  }
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

test('TUN-only stop keeps config client protection working; runtime restart is serialized', async () => {
  const f = fixture();
  try {
    await f.request('startVpn', vpnParams());
    await f.request('stopVpn');
    f.send();
    await drain();
    expect(f.acks[0].success).toBe(true);
    const stop = f.request('stopRuntime');
    const start = f.request('startConfigServerClient', { url: 'udp://test.invalid' });
    await Promise.all([stop, start]);
    expect(f.calls.indexOf('stop-runtime')).toBeLessThan(f.calls.indexOf('start-client'));
    f.send('2');
    await drain();
    expect(f.acks[1].success).toBe(true);
  } finally { await f.request('stopRuntime'); }
});

test('enabling failure does not start Core or create TUN', async () => {
  const f = fixture();
  f.rejectEnable();
  await expect(f.request('startVpn', vpnParams())).rejects.toThrow('could not be enabled');
  expect(f.calls).not.toContain('create-tun');
  expect(f.calls).not.toContain('start-client');
});

test('a protection failure shuts down the actual VPN runtime', async () => {
  const f = fixture();
  f.setProtect(async () => { throw new Error('protect failed'); });
  await f.request('startVpn', vpnParams());
  f.send();
  await drain();
  await f.ability.runtimeOperationQueue;
  expect(f.calls).toContain('stop-runtime');
  expect(f.calls.at(-1)).toBe('destroy-tun');
  expect(f.ability.lastError).toContain('protect failed');
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
