// Run: bun test test/ohos_runtime_bridge.test.ts
// Exercise the real UI bridge; transport completions are controlled to model
// callbacks queued while the UI process was frozen.
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
const drain = () => new Promise<void>((resolve) => setImmediate(resolve));

type Event = { type: string; payload: unknown };
interface Bridge {
  onAttachedToAbility(binding: object): void;
  onDetachedFromAbility(): void;
  onListen(args: object, sink: object): void;
  onForeground(): void;
  onMethodCall(call: { method: string }, result: object): void;
}

function fixture() {
  const events: Event[] = [];
  const requests: string[] = [];
  const nativeActions: string[] = [];
  const pending: ReturnType<typeof deferred<unknown>>[] = [];
  let connected = false;
  let closes = 0;
  let connectBarrier: Promise<void> = Promise.resolve();
  let remoteClose: () => void = () => {};
  class RuntimeIpcClient {
    constructor(_onEvent: (type: string, payload: unknown) => void, onClose: () => void) { remoteClose = onClose; }
    isConnected() { return connected; }
    async connect() { await connectBarrier; connected = true; }
    async close() { closes++; connected = false; }
    request(method: string) {
      requests.push(method);
      const request = deferred<unknown>();
      pending.push(request);
      return request.promise;
    }
  }
  class RuntimeIpcError extends Error { kind = 'transport'; }
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

test('resume replaces a frozen transport and discards its late snapshot failure', async () => {
  const f = fixture();
  f.listen();
  await drain();
  const old = f.pending[0];
  f.bridge.onForeground();
  await drain();
  const current = JSON.stringify({ configServerConnected: true, activeVpnInstanceName: 'mesh' });
  f.pending[1].resolve(current);
  await drain();
  old.reject(new Error('expired while UI frozen'));
  await drain();
  expect(f.closes()).toBe(1);
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
