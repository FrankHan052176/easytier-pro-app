// Run: bun test test/ohos_runtime_bridge.test.ts
// Exercise the real UI bridge against a fixture transport whose in-flight
// requests settle the way the real RuntimeIpcClient settles them: closing the
// socket rejects every pending request.
import { beforeAll, expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

let bridgeCode: string;
beforeAll(async () => {
  const result = await Bun.build({
    entrypoints: [resolve(import.meta.dir, '../ohos/entry/src/main/ets/runtime/OhosCoreRuntimeBridge.ets')],
    target: 'node', format: 'cjs',
    external: ['@kit.*', '@ohos/flutter_ohos', './OhosCoreRuntimeIpc'],
    plugins: [{ name: 'bridge-host', setup(build) {
      build.onLoad({ filter: /\.ets$/ }, async ({ path }) => ({
        contents: await readFile(path, 'utf8'), loader: 'ts',
      }));
      build.onResolve({ filter: /OhosCoreRuntimeIpc$/ }, ({ path }) => ({ path, external: true }));
    } }],
  });
  if (!result.success) throw new Error(result.logs.join('\n'));
  bridgeCode = await result.outputs[0].text();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

// One in-flight runtime request: the fixture can answer it or observe that a
// transport close already settled it.
interface PendingRequest {
  method: string;
  promise: Promise<unknown>;
  settled: boolean;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

const drain = () => new Promise<void>((resolve) => setImmediate(resolve));

type Event = { type: string; payload: unknown };
interface Bridge {
  onAttachedToAbility(binding: object): void;
  onDetachedFromAbility(): void;
  onListen(args: object, sink: object): void;
  onForeground(): void;
  onMethodCall(call: { method: string; argument?: (key: string) => unknown }, result: object): void;
}

interface Fixture {
  bridge: Bridge;
  events: Event[];
  pending: PendingRequest[];
  requests: string[];
  nativeActions: string[];
  closes(): number;
  listen(): void;
  delayConnect(value: Promise<void>): void;
  disconnect(): void;
}

function fixture(): Fixture {
  const events: Event[] = [];
  const requests: string[] = [];
  const nativeActions: string[] = [];
  const pending: PendingRequest[] = [];
  let connected = false;
  let closes = 0;
  let connectBarrier: Promise<void> = Promise.resolve();
  let remoteClose: () => void = () => {};
  class RuntimeIpcClient {
    constructor(_onEvent: (type: string, payload: unknown) => void, onClose: () => void) { remoteClose = onClose; }
    isConnected() { return connected; }
    async connect() { await connectBarrier; connected = true; }
    async close() {
      closes++;
      connected = false;
      // The real client rejects every in-flight request when its socket closes.
      for (const request of pending) {
        if (!request.settled) {
          request.reject(new RuntimeIpcError('transport', 'HarmonyOS core runtime socket closed'));
        }
      }
    }
    request(method: string) {
      requests.push(method);
      let settleResolve!: (value: unknown) => void;
      let settleReject!: (error: Error) => void;
      const request: PendingRequest = {
        method,
        settled: false,
        promise: new Promise<unknown>((ok, fail) => { settleResolve = ok; settleReject = fail; }),
        resolve(value: unknown) { request.settled = true; settleResolve(value); },
        reject(error: Error) { request.settled = true; settleReject(error); },
      };
      if (!connected) {
        // The real client rejects without sending while its socket is closed.
        request.reject(new RuntimeIpcError('transport', 'HarmonyOS core runtime socket is not connected'));
        return request.promise;
      }
      pending.push(request);
      return request.promise;
    }
  }
  class RuntimeIpcError extends Error {
    kind: string;

    constructor(kind: string, message: string) {
      super(message);
      this.kind = kind;
    }
  }
  const modules: Record<string, unknown> = {
    './OhosCoreRuntimeIpc': {
      RuntimeIpcClient, RuntimeIpcError, RuntimeParams: class {},
      RUNTIME_IPC_ERROR_REMOTE: 'remote', runtimeSocketPath: (dir: string) => `${dir}/runtime.sock`,
    },
    '@kit.AbilityKit': {}, '@kit.CoreFileKit': {}, '@kit.ArkTS': { JSON },
    '@kit.ArkData': {}, '@kit.BasicServicesKit': {}, '@ohos/flutter_ohos': {},
    '@kit.NetworkKit': { vpnExtension: {
      async startVpnExtensionAbility() { nativeActions.push('start'); },
      async stopVpnExtensionAbility() { nativeActions.push('stop'); },
    } },
  };
  const module = { exports: {} };
  runInNewContext(bridgeCode, {
    module, exports: module.exports, console, setTimeout, clearTimeout,
    require(name: string) {
      if (!(name in modules)) throw new Error(`Unexpected module ${name}`);
      return modules[name];
    },
  });
  // This is the known export of our compiled bridge, not external input.
  const bridgeModule = module.exports as { default: new () => Bridge };
  const bridge = new bridgeModule.default();
  bridge.onAttachedToAbility({ getAbility: () => ({ context: { filesDir: '/app/files' } }) });
  return {
    bridge, events, pending, requests, nativeActions,
    closes: () => closes,
    listen() { bridge.onListen({}, { success: (event: Event) => events.push(event) }); },
    delayConnect(value: Promise<void>) { connectBarrier = value; },
    disconnect() { connected = false; remoteClose(); },
  };
}

// The fixture only answers what a test drives, so a live snapshot read proves
// the bridge kept its transport usable; resolving it must publish normally.
async function settleSnapshotReads(f: Fixture, payload: string): Promise<number> {
  let answered = 0;
  for (let round = 0; round < 6; round += 1) {
    const read = f.pending.find((entry) => entry.method === 'getRuntimeSnapshot' && !entry.settled);
    if (read !== undefined) {
      read.resolve(payload);
      answered += 1;
    }
    await drain();
  }
  return answered;
}

// The readiness probe carries a short timeout, so it is answered as soon as it
// is issued. Only the first readiness check of a flow is guaranteed to probe.
async function answerReadinessProbe(f: Fixture): Promise<void> {
  const probe = f.pending.find((entry) => entry.method === 'isConfigServerClientConnected' && !entry.settled);
  if (probe === undefined) throw new Error('bridge never probed core runtime readiness');
  probe.resolve(true);
  await drain();
}

// Answer probes until the bridge issues its start request. A bridge may reuse a
// completed readiness check, so the number of probes before the start can vary.
async function waitForStartRequest(f: Fixture): Promise<PendingRequest> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const probe = f.pending.find((entry) => entry.method === 'isConfigServerClientConnected' && !entry.settled);
    if (probe !== undefined) probe.resolve(true);
    await drain();
    const start = f.pending.find((entry) => entry.method === 'startConfigServerClient' && !entry.settled);
    if (start !== undefined) return start;
  }
  throw new Error('bridge never issued a startConfigServerClient request');
}

test('resume replaces the frozen transport without surfacing the superseded snapshot rejection', async () => {
  const f = fixture();
  f.listen();
  await drain();
  f.bridge.onForeground();
  await drain();
  // The replaced transport already rejected the superseded read; it must not
  // reach the event sink.
  expect(f.closes()).toBe(1);
  expect(f.events).toEqual([]);
  const current = JSON.stringify({ configServerConnected: true, activeVpnInstanceName: 'mesh' });
  const read = f.pending.find((entry) => entry.method === 'getRuntimeSnapshot' && !entry.settled);
  if (read === undefined) throw new Error('resume never issued a snapshot read');
  read.resolve(current);
  await drain();
  expect(f.events.map((event) => event.type)).toEqual(['runtime_snapshot']);
  expect(f.events[0].payload).toBe(current);
  expect(f.nativeActions).toEqual([]);
});

test('detached UI cannot request or publish a snapshot from a late connection', async () => {
  const f = fixture();
  const connection = deferred<void>();
  f.delayConnect(connection.promise);
  f.listen();
  await drain();
  f.bridge.onDetachedFromAbility();
  connection.resolve();
  await drain();
  expect(f.requests).toEqual([]);
  expect(f.events).toEqual([]);
  expect(f.nativeActions).toEqual([]);
});

test('an unavailable child is unknown, not an empty running-instance list', async () => {
  const f = fixture();
  const results: Array<{ code: string; message: string }> = [];
  const successes: unknown[] = [];
  f.bridge.onMethodCall({ method: 'listInstances' }, {
    success: (value: unknown) => successes.push(value),
    error: (code: string, message: string) => results.push({ code, message }),
  });
  await drain();
  f.pending[0].reject(new Error('reader connection was dropped'));
  await drain();
  expect(successes).toEqual([]);
  expect(results[0].code).toBe('OHOS_RUNTIME_IPC_FAILED');
  expect(results[0].message).toContain('reader connection was dropped');
  expect(f.nativeActions).toEqual([]);
});

test('losing only the UI socket never terminates the extension', async () => {
  const f = fixture();
  f.listen();
  await drain();
  f.pending[0].resolve(JSON.stringify({ configServerConnected: true }));
  await drain();
  f.disconnect();
  expect(f.events.map((event) => event.type)).toEqual(['runtime_snapshot', 'runtime_disconnected']);
  expect(f.nativeActions).toEqual([]);
});

test('foreground during a pending core start neither rejects the start nor replays it', async () => {
  const f = fixture();
  f.listen();
  await drain();
  await settleSnapshotReads(f, '{}');
  const grants: unknown[] = [];
  f.bridge.onMethodCall({ method: 'prepareVpn' }, {
    success: (value: unknown) => grants.push(value),
    error: (code: string, message: string) => grants.push(`error ${code}: ${message}`),
  });
  await drain();
  // The permission probe is what starts the extension and grants VPN access.
  await answerReadinessProbe(f);
  expect(grants).toEqual([true]);

  const startErrors: Array<{ code: string; message: string }> = [];
  const startSuccesses: unknown[] = [];
  const startArgs: Record<string, unknown> = {
    url: 'tcp://core.easytier.local:11010',
    hostname: 'core.easytier.local',
    machineId: 'machine-1',
    secureMode: true,
  };
  f.bridge.onMethodCall({
    method: 'startConfigServerClient',
    argument: (key: string) => startArgs[key],
  }, {
    success: (value: unknown) => startSuccesses.push(value),
    error: (code: string, message: string) => startErrors.push({ code, message }),
  });
  const start = await waitForStartRequest(f);
  expect(f.requests.filter((method) => method === 'startConfigServerClient')).toHaveLength(1);

  // The permission dialog's foreground event arrives while the native start
  // request is still in flight. It must not cancel or replace that request.
  f.bridge.onForeground();
  await drain();
  expect(startErrors).toEqual([]);
  expect(startSuccesses).toEqual([]);
  expect(start.settled).toBe(false);
  expect(f.requests.filter((method) => method === 'startConfigServerClient')).toHaveLength(1);

  // The runtime answers the original request; the bridge must not compensate by
  // sending a second, mutating start.
  start.resolve(null);
  await drain();
  expect(startErrors).toEqual([]);
  expect(startSuccesses).toEqual([null]);
  expect(f.requests.filter((method) => method === 'startConfigServerClient')).toHaveLength(1);
  expect(f.events.filter((event) => event.type === 'config_server_started')).toHaveLength(1);

  // Snapshot recovery after the start must still publish on the surviving
  // transport, without surfacing a transport failure.
  const snapshot = JSON.stringify({ configServerConnected: true, activeVpnInstanceName: 'mesh' });
  expect(await settleSnapshotReads(f, snapshot)).toBeGreaterThanOrEqual(1);
  expect(f.events.filter((event) => event.type === 'runtime_disconnected')).toEqual([]);
  const snapshots = f.events.filter((event) => event.type === 'runtime_snapshot');
  expect(snapshots.length).toBeGreaterThan(0);
  expect(snapshots[snapshots.length - 1].payload).toBe(snapshot);
  expect(f.nativeActions).toEqual([]);
});

test('foreground between the permission probe and the first start keeps that start working', async () => {
  const f = fixture();
  f.listen();
  await drain();
  await settleSnapshotReads(f, '{}');
  const grants: unknown[] = [];
  f.bridge.onMethodCall({ method: 'prepareVpn' }, {
    success: (value: unknown) => grants.push(value),
    error: (code: string, message: string) => grants.push(`error ${code}: ${message}`),
  });
  await drain();
  await answerReadinessProbe(f);
  expect(grants).toEqual([true]);

  // The dialog's foreground event lands after the grant is reported but before
  // the app asks for its first start.
  f.bridge.onForeground();
  await drain();
  await settleSnapshotReads(f, '{}');

  const startErrors: Array<{ code: string; message: string }> = [];
  const startSuccesses: unknown[] = [];
  const startArgs: Record<string, unknown> = {
    url: 'tcp://core.easytier.local:11010',
    hostname: 'core.easytier.local',
    machineId: 'machine-1',
    secureMode: false,
  };
  f.bridge.onMethodCall({
    method: 'startConfigServerClient',
    argument: (key: string) => startArgs[key],
  }, {
    success: (value: unknown) => startSuccesses.push(value),
    error: (code: string, message: string) => startErrors.push({ code, message }),
  });
  const start = await waitForStartRequest(f);
  start.resolve(null);
  await drain();

  expect(startErrors).toEqual([]);
  expect(startSuccesses).toEqual([null]);
  expect(f.requests.filter((method) => method === 'startConfigServerClient')).toHaveLength(1);
  expect(f.events.filter((event) => event.type === 'config_server_started')).toHaveLength(1);
  expect(f.nativeActions).toEqual([]);
});
