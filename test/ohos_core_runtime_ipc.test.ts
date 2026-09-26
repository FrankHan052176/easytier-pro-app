// Run: bun test test/ohos_core_runtime_ipc.test.ts
// Host-side behavior tests of the actual ArkTS runtime IPC transport. The OS
// socket API, the timers and the sandbox path are controlled boundaries; these
// do not replace on-device verification.
import { beforeAll, expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

const etsRoot = resolve(import.meta.dir, '../ohos/entry/src/main/ets');
let ipcCode: string;

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
  ipcCode = await compile('runtime/OhosCoreRuntimeIpc.ets');
});

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const drain = () => new Promise<void>((resolve) => setImmediate(resolve));

function bytesOf(text: string): Uint8Array {
  return encoder.encode(text);
}

function requestText(id: number, method: string, params: Record<string, unknown> = {}): string {
  return JSON.stringify({ type: 'request', id, method, params }) + '\n';
}

function framesOf(text: string): Array<Record<string, unknown>> {
  return text
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function responseIds(text: string): number[] {
  return framesOf(text)
    .filter((frame) => frame.type === 'response')
    .map((frame) => frame.id as number);
}

interface ClockTimer {
  at: number;
  fn: () => void;
}

// Deterministic replacement for the sandbox timer globals: the transport's
// request and write timeouts are driven explicitly by the tests.
class TestClock {
  private current = 0;
  private nextId = 1;
  private readonly timers = new Map<number, ClockTimer>();

  setTimeout = (fn: () => void, ms: number): number => {
    const id = this.nextId++;
    this.timers.set(id, { at: this.current + Math.max(0, ms), fn });
    return id;
  };

  clearTimeout = (id: number): void => {
    this.timers.delete(id);
  };

  async advance(ms: number): Promise<void> {
    const target = this.current + ms;
    for (;;) {
      const due = [...this.timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0]);
      if (due.length === 0) break;
      const [id, timer] = due[0];
      this.timers.delete(id);
      this.current = timer.at;
      timer.fn();
      await drain();
    }
    this.current = target;
    await drain();
  }
}

interface HeldWrite {
  text: string;
  resolve: () => void;
  reject: (error: Error) => void;
}

// One socket endpoint. `send` models the OS write: it may settle immediately,
// never settle (a frozen reader), or fail, independently of message delivery.
class FakeEndpoint {
  readonly id: number;
  closed = false;
  mode: 'auto' | 'hold' | 'fail' | 'throw' = 'auto';
  writeFailure: Error = new Error('write failed');
  rejectWritesOnClose = true;
  sentCalls = 0;
  readonly delivered: string[] = [];
  peer: FakeEndpoint | null = null;
  private readonly listeners = new Map<string, Array<(value: unknown) => void>>();
  private readonly held: HeldWrite[] = [];

  constructor(id: number) {
    this.id = id;
  }

  get clientId(): number {
    return this.id;
  }

  on(type: string, callback: (value: unknown) => void): void {
    const list = this.listeners.get(type) ?? [];
    list.push(callback);
    this.listeners.set(type, list);
  }

  fire(type: string, value?: unknown): void {
    for (const callback of [...(this.listeners.get(type) ?? [])]) callback(value);
  }

  // Raw bytes written by this endpoint's owner, delivered to the peer socket.
  write(text: string): void {
    const peer = this.peer;
    if (peer === null || peer.closed) return;
    peer.fire('message', { message: bytesOf(text) });
  }

  send(options: { data: ArrayBuffer | Uint8Array | string }): Promise<void> {
    this.sentCalls += 1;
    if (this.closed) return Promise.reject(new Error('socket is closed'));
    if (this.mode === 'fail') return Promise.reject(this.writeFailure);
    if (this.mode === 'throw') throw new Error('synchronous write failure');
    const payload = options.data;
    const text = typeof payload === 'string'
      ? payload
      : decoder.decode(payload instanceof Uint8Array ? payload : new Uint8Array(payload));
    if (this.mode === 'hold') {
      return new Promise<void>((resolve, reject) => {
        this.held.push({ text, resolve, reject });
      });
    }
    return this.deliver(text);
  }

  pendingWrites(): number {
    return this.held.length;
  }

  async releaseOneWrite(): Promise<void> {
    const item = this.held.shift();
    if (item === undefined) return;
    await this.deliver(item.text);
    item.resolve();
    await drain();
  }

  async releaseWrites(limit = 64): Promise<void> {
    for (let index = 0; index < limit && this.held.length > 0; index++) {
      await this.releaseOneWrite();
    }
  }

  failPendingWrites(error: Error): void {
    for (const item of this.held.splice(0, this.held.length)) item.reject(error);
  }

  close(): Promise<void> {
    if (this.closed) return Promise.resolve();
    this.closed = true;
    if (this.rejectWritesOnClose) this.failPendingWrites(new Error('socket is closed'));
    this.fire('close');
    const peer = this.peer;
    if (peer !== null && !peer.closed) peer.fire('close');
    return Promise.resolve();
  }

  private deliver(text: string): Promise<void> {
    this.delivered.push(text);
    const peer = this.peer;
    if (peer !== null && !peer.closed) peer.fire('message', { message: bytesOf(text) });
    return Promise.resolve();
  }
}

class FakeLocalSocket extends FakeEndpoint {
  connectFails = false;

  constructor(id: number, private readonly network: FakeNetwork) {
    super(id);
  }

  connect(options: { address: { address: string }; timeout: number }): Promise<void> {
    if (this.connectFails) return Promise.reject(new Error('connect refused'));
    const server = this.network.serverAt(options.address.address);
    if (server === null) return Promise.reject(new Error('connect refused'));
    server.accept(this);
    return Promise.resolve();
  }
}

class FakeServer {
  path = '';
  listening = false;
  closed = false;
  private onConnect: ((connection: FakeEndpoint) => void) | null = null;

  listen(address: { address: string }): Promise<void> {
    this.path = address.address;
    this.listening = true;
    return Promise.resolve();
  }

  close(): Promise<void> {
    this.listening = false;
    this.closed = true;
    return Promise.resolve();
  }

  on(type: string, callback: (value: unknown) => void): void {
    if (type === 'connect') this.onConnect = callback as (connection: FakeEndpoint) => void;
  }

  accept(client: FakeEndpoint): FakeEndpoint {
    const connection = new FakeEndpoint(client.id);
    connection.peer = client;
    client.peer = connection;
    this.onConnect?.(connection);
    return connection;
  }
}

class FakeNetwork {
  private readonly servers: FakeServer[] = [];
  private readonly sockets: FakeLocalSocket[] = [];
  private nextId = 1;

  socketModule(): unknown {
    return {
      socket: {
        constructLocalSocketServerInstance: (): FakeServer => {
          const server = new FakeServer();
          this.servers.push(server);
          return server;
        },
        constructLocalSocketInstance: (): FakeLocalSocket => {
          const socket = new FakeLocalSocket(this.nextId++, this);
          this.sockets.push(socket);
          return socket;
        },
      },
    };
  }

  serverAt(path: string): FakeServer | null {
    for (const server of this.servers) {
      if (server.listening && !server.closed && server.path === path) return server;
    }
    return null;
  }

  latestSocket(): FakeLocalSocket {
    return this.sockets[this.sockets.length - 1];
  }

  // An OS accepted connection whose peer id may be reused after a drop.
  connectPeer(clientId: number): { client: FakeEndpoint; connection: FakeEndpoint } {
    const client = new FakeEndpoint(clientId);
    const connection = this.servers[this.servers.length - 1].accept(client);
    return { client, connection };
  }
}

interface ClientUnderTest {
  isConnected(): boolean;
  connect(path: string, maxAttempts?: number): Promise<void>;
  request(method: string, params: Record<string, unknown>, timeoutMs?: number): Promise<unknown>;
  close(): Promise<void>;
}

interface ServerUnderTest {
  start(socketFilesDir: string): Promise<void>;
  close(): Promise<void>;
  broadcastEvent(eventType: string, payload: unknown): void;
}

interface IpcModule {
  RuntimeIpcClient: new (
    onEvent: (type: string, payload: unknown) => void,
    onRemoteClose?: () => void,
  ) => ClientUnderTest;
  RuntimeIpcServer: new (
    handler: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  ) => ServerUnderTest;
  runtimeSocketPath(filesDir: string): string;
  RUNTIME_IPC_ERROR_TRANSPORT: string;
  RUNTIME_IPC_ERROR_REMOTE: string;
}

interface RuntimeErrorLike {
  kind?: string;
  message?: string;
}

const bufferModule = {
  buffer: {
    from(input: string | ArrayBuffer | Uint8Array): { buffer: ArrayBuffer; toString(): string } {
      let bytes: Uint8Array;
      let text: string;
      if (typeof input === 'string') {
        bytes = bytesOf(input);
        text = input;
      } else if (input instanceof Uint8Array) {
        bytes = input;
        text = decoder.decode(input);
      } else {
        bytes = new Uint8Array(input);
        text = decoder.decode(bytes);
      }
      return {
        buffer: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
        toString: () => text,
      };
    },
  },
  JSON,
};

function loadIpc(clock: TestClock, network: FakeNetwork): IpcModule {
  const modules: Record<string, unknown> = {
    '@kit.BasicServicesKit': {},
    '@kit.ArkTS': bufferModule,
    '@kit.CoreFileKit': { fileIo: { unlinkSync(): void {} } },
    '@kit.NetworkKit': network.socketModule(),
  };
  const module = { exports: {} as Record<string, unknown> };
  runInNewContext(ipcCode, {
    module,
    exports: module.exports,
    require: (name: string) => {
      if (!(name in modules)) throw new Error(`Unexpected dependency: ${name}`);
      return modules[name];
    },
    console: { info() {}, error() {}, warn() {} },
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    setInterval: () => 1,
    clearInterval() {},
  });
  return module.exports as unknown as IpcModule;
}

interface FixtureOptions {
  handler?: (method: string, params: Record<string, unknown>) => Promise<unknown>;
}

function fixture(options: FixtureOptions = {}) {
  const clock = new TestClock();
  const network = new FakeNetwork();
  const ipc = loadIpc(clock, network);
  const methods: string[] = [];
  const server = new ipc.RuntimeIpcServer(async (method: string, params: Record<string, unknown>) => {
    methods.push(method);
    if (options.handler !== undefined) return options.handler(method, params);
    return `ok:${method}`;
  });
  const path = ipc.runtimeSocketPath('/tmp/easytier-test-files');
  return {
    clock, network, ipc, server, methods, path,
    async start(): Promise<void> {
      await server.start('/tmp/easytier-test-files');
    },
    connectPeer(clientId: number) {
      return network.connectPeer(clientId);
    },
    client(): {
      client: ClientUnderTest;
      events: Array<{ type: string; payload: unknown }>;
      remoteCloses: () => number;
    } {
      const events: Array<{ type: string; payload: unknown }> = [];
      let remoteCloses = 0;
      const client = new ipc.RuntimeIpcClient(
        (type: string, payload: unknown) => {
          events.push({ type, payload });
        },
        () => {
          remoteCloses += 1;
        },
      );
      return { client, events, remoteCloses: () => remoteCloses };
    },
  };
}

test('a frozen reader is dropped once its bounded queue overflows; a healthy peer keeps being served', async () => {
  const f = fixture();
  await f.start();
  const frozen = f.connectPeer(41);
  const healthy = f.connectPeer(42);
  frozen.connection.mode = 'hold';

  frozen.client.write(requestText(1, 'listInstances'));
  healthy.client.write(requestText(1, 'listInstances'));
  await drain();

  expect(frozen.connection.sentCalls).toBe(1);
  expect(frozen.connection.pendingWrites()).toBe(1);
  expect(responseIds(healthy.connection.delivered.join(''))).toEqual([1]);

  const chunk = 'x'.repeat(4096);
  let broadcasts = 0;
  while (!frozen.connection.closed && broadcasts < 2000) {
    f.server.broadcastEvent('runtime_snapshot', chunk);
    broadcasts += 1;
    await drain();
  }
  expect(frozen.connection.closed).toBe(true);
  expect(broadcasts).toBeGreaterThan(1);
  expect(broadcasts).toBeLessThan(600);
  expect(frozen.connection.sentCalls).toBe(1);
  expect(frozen.connection.pendingWrites()).toBe(0);

  // Dropping one peer must not disturb the server, the native control loop, or
  // any other peer.
  f.server.broadcastEvent('runtime_snapshot', chunk);
  healthy.client.write(requestText(2, 'listInstances'));
  await drain();
  expect(healthy.connection.closed).toBe(false);
  expect(responseIds(healthy.connection.delivered.join(''))).toEqual([1, 2]);
  const events = framesOf(healthy.connection.delivered.join('')).filter((frame) => frame.type === 'event');
  expect(events.length).toBe(broadcasts + 1);
  expect(events[0].eventType).toBe('runtime_snapshot');
});

test('a write that never settles times out and drops only that peer', async () => {
  const f = fixture();
  await f.start();
  const stuck = f.connectPeer(51);
  const other = f.connectPeer(52);
  stuck.connection.mode = 'hold';

  stuck.client.write(requestText(1, 'listInstances'));
  other.client.write(requestText(1, 'listInstances'));
  await drain();
  expect(stuck.connection.closed).toBe(false);
  expect(stuck.connection.pendingWrites()).toBe(1);

  await f.clock.advance(60000);

  expect(stuck.connection.closed).toBe(true);
  expect(stuck.connection.sentCalls).toBe(1);
  expect(other.connection.closed).toBe(false);
  other.client.write(requestText(2, 'listInstances'));
  await drain();
  const frames = framesOf(other.connection.delivered.join(''));
  expect(frames.map((frame) => frame.id)).toEqual([1, 2]);
  expect(frames[1].ok).toBe(true);
  expect(frames[1].result).toBe('ok:listInstances');
});

test('late callbacks from a dropped peer cannot evict a peer reusing its clientId', async () => {
  const f = fixture();
  await f.start();
  const stale = f.connectPeer(61);
  stale.connection.mode = 'hold';
  stale.connection.rejectWritesOnClose = false;
  stale.client.write(requestText(1, 'listInstances'));
  await drain();
  expect(stale.connection.pendingWrites()).toBe(1);

  const chunk = 'x'.repeat(4096);
  let broadcasts = 0;
  while (!stale.connection.closed && broadcasts < 2000) {
    f.server.broadcastEvent('runtime_snapshot', chunk);
    broadcasts += 1;
    await drain();
  }
  expect(stale.connection.closed).toBe(true);

  const reused = f.connectPeer(61);
  reused.client.write(requestText(1, 'listInstances'));
  await drain();
  expect(responseIds(reused.connection.delivered.join(''))).toEqual([1]);

  // The OS reports the dead socket of the old peer only after its id was reused.
  stale.connection.fire('close');
  stale.connection.fire('error', new Error('late socket error'));
  stale.connection.failPendingWrites(new Error('late write failure'));
  await drain();
  expect(reused.connection.closed).toBe(false);

  reused.client.write(requestText(2, 'listInstances'));
  await drain();
  expect(responseIds(reused.connection.delivered.join(''))).toEqual([1, 2]);
});

test('a valid frame is delivered whole while an oversized frame drops the peer instead of being truncated', async () => {
  const payloads: number[] = [];
  const f = fixture({
    handler: async (_method: string, params: Record<string, unknown>) => {
      payloads.push(typeof params.payloadJson === 'string' ? params.payloadJson.length : -1);
      return 'ok';
    },
  });
  await f.start();
  const peer = f.connectPeer(71);
  const split = f.connectPeer(72);
  const terminated = f.connectPeer(73);

  const payload = 'p'.repeat(1024 * 1024);
  peer.client.write(requestText(1, 'callJsonRpc', { payloadJson: payload }));
  await drain();
  expect(payloads).toEqual([payload.length]);
  const response = framesOf(peer.connection.delivered.join(''))[0];
  expect(response.ok).toBe(true);
  expect(response.result).toBe('ok');

  // An incomplete frame may span chunks, but not grow past the protocol bound.
  const half = 'q'.repeat(3 * 1024 * 1024);
  split.client.write(half);
  await drain();
  expect(split.connection.closed).toBe(false);
  split.client.write(half);
  await drain();
  expect(split.connection.closed).toBe(true);

  // A terminated frame past the bound is rejected the same way.
  terminated.client.write('r'.repeat(4 * 1024 * 1024 + 1) + '\n');
  await drain();
  expect(terminated.connection.closed).toBe(true);
  expect(payloads).toEqual([payload.length]);

  peer.client.write(requestText(2, 'listInstances'));
  await drain();
  expect(responseIds(peer.connection.delivered.join(''))).toEqual([1, 2]);
});

test('splits and joins frames across chunks while keeping responses serial and ordered', async () => {
  const f = fixture({ handler: async (method: string) => `ok:${method}` });
  await f.start();
  const peer = f.connectPeer(81);
  peer.connection.mode = 'hold';

  const batch = requestText(1, 'first') + requestText(2, 'second');
  peer.client.write(batch.slice(0, 21));
  peer.client.write(batch.slice(21));
  await drain();

  expect(peer.connection.sentCalls).toBe(1);
  expect(peer.connection.delivered.length).toBe(0);
  await peer.connection.releaseOneWrite();
  expect(peer.connection.sentCalls).toBe(2);
  expect(peer.connection.delivered.length).toBe(1);
  await peer.connection.releaseWrites();

  const frames = framesOf(peer.connection.delivered.join(''));
  expect(frames.map((frame) => frame.id)).toEqual([1, 2]);
  expect(frames.map((frame) => frame.result)).toEqual(['ok:first', 'ok:second']);
  for (const text of peer.connection.delivered) {
    expect(text.endsWith('\n')).toBe(true);
    expect(text.indexOf('\n')).toBe(text.length - 1);
  }
});

test('a client request timeout drops only that transport and never replays the command', async () => {
  const f = fixture({
    handler: async (method: string) => {
      if (method === 'hang') return new Promise<string>((): void => {});
      return `ok:${method}`;
    },
  });
  await f.start();
  const first = f.client();
  await first.client.connect(f.path, 1);
  let failure: RuntimeErrorLike | null = null;
  first.client.request('hang', {}).catch((error: RuntimeErrorLike) => {
    failure = error;
  });
  await drain();
  expect(f.methods.filter((method) => method === 'hang').length).toBe(1);
  expect(first.client.isConnected()).toBe(true);

  await f.clock.advance(60000);

  expect(failure?.kind).toBe(f.ipc.RUNTIME_IPC_ERROR_TRANSPORT);
  expect(first.client.isConnected()).toBe(false);
  expect(first.remoteCloses()).toBe(1);
  expect(f.methods.filter((method) => method === 'hang').length).toBe(1);
  expect(f.network.serverAt(f.path)?.closed).toBe(false);

  const second = f.client();
  await second.client.connect(f.path, 1);
  expect(await second.client.request('getRuntimeSnapshot', {})).toBe('ok:getRuntimeSnapshot');
  expect(second.client.isConnected()).toBe(true);
});

test('a handler failure stays a remote error and leaves the transport usable', async () => {
  const f = fixture({
    handler: async (method: string) => {
      if (method === 'boom') throw new Error('native failure');
      return `ok:${method}`;
    },
  });
  await f.start();
  const peer = f.client();
  await peer.client.connect(f.path, 1);
  let failure: RuntimeErrorLike | null = null;
  await peer.client.request('boom', {}).catch((error: RuntimeErrorLike) => {
    failure = error;
  });
  expect(failure?.kind).toBe(f.ipc.RUNTIME_IPC_ERROR_REMOTE);
  expect(failure?.message).toBe('native failure');
  expect(peer.client.isConnected()).toBe(true);
  expect(await peer.client.request('ping', {})).toBe('ok:ping');
});

test('a protocol overrun from the runtime drops the client transport instead of buffering it', async () => {
  const f = fixture();
  await f.start();
  const peer = f.client();
  await peer.client.connect(f.path, 1);
  f.network.latestSocket().fire('message', { message: bytesOf('y'.repeat(4 * 1024 * 1024 + 1)) });
  await drain();

  expect(peer.client.isConnected()).toBe(false);
  expect(peer.remoteCloses()).toBe(1);
  let failure: RuntimeErrorLike | null = null;
  await peer.client.request('listInstances', {}).catch((error: RuntimeErrorLike) => {
    failure = error;
  });
  expect(failure?.kind).toBe(f.ipc.RUNTIME_IPC_ERROR_TRANSPORT);

  const replacement = f.client();
  await replacement.client.connect(f.path, 1);
  expect(await replacement.client.request('listInstances', {})).toBe('ok:listInstances');
});

test('a reconnect is unaffected by stale timers, messages and writes of the superseded socket', async () => {
  const f = fixture({
    handler: async (method: string) => {
      if (method === 'hang') return new Promise<string>((): void => {});
      return `ok:${method}`;
    },
  });
  await f.start();
  const first = f.client();
  await first.client.connect(f.path, 1);
  const oldSocket = f.network.latestSocket();
  oldSocket.mode = 'hold';
  oldSocket.rejectWritesOnClose = false;
  let failure: RuntimeErrorLike | null = null;
  first.client.request('hang', {}).catch((error: RuntimeErrorLike) => {
    failure = error;
  });
  await drain();
  await f.clock.advance(60000);
  expect(failure?.kind).toBe(f.ipc.RUNTIME_IPC_ERROR_TRANSPORT);
  expect(oldSocket.closed).toBe(true);

  await first.client.connect(f.path, 1);
  expect(first.client.isConnected()).toBe(true);
  expect(await first.client.request('getRuntimeSnapshot', {})).toBe('ok:getRuntimeSnapshot');

  // Everything the superseded socket still reports must be ignored.
  oldSocket.failPendingWrites(new Error('late write failure'));
  oldSocket.fire('error', new Error('late socket error'));
  oldSocket.fire('close');
  oldSocket.fire('message', {
    message: bytesOf(JSON.stringify({ type: 'response', id: 1, ok: true, result: 'stale' }) + '\n'),
  });
  f.network.latestSocket().fire('message', {
    message: bytesOf(JSON.stringify({ type: 'response', id: 1, ok: true, result: 'stale' }) + '\n'),
  });
  await drain();

  expect(first.remoteCloses()).toBe(1);
  expect(first.client.isConnected()).toBe(true);
  expect(await first.client.request('getRuntimeSnapshot', {})).toBe('ok:getRuntimeSnapshot');
});

test('a reused clientId disposes the replaced peer queue instead of draining it later', async () => {
  const f = fixture();
  await f.start();
  const old = f.connectPeer(91);
  old.connection.mode = 'hold';
  old.connection.rejectWritesOnClose = false;
  old.client.write(requestText(1, 'listInstances'));
  await drain();
  f.server.broadcastEvent('runtime_snapshot', 'queued-old');
  f.server.broadcastEvent('runtime_snapshot', 'queued-old');
  expect(old.connection.sentCalls).toBe(1);
  expect(old.connection.delivered.length).toBe(0);

  const replacement = f.connectPeer(91);
  replacement.client.write(requestText(1, 'listInstances'));
  await drain();
  expect(old.connection.closed).toBe(true);
  expect(responseIds(replacement.connection.delivered.join(''))).toEqual([1]);

  // The abandoned write settles only after the id was reused: it must not resume
  // the replaced peer's queue on the stale connection.
  await old.connection.releaseOneWrite();
  await drain();
  expect(old.connection.sentCalls).toBe(1);
  expect(old.connection.delivered.filter((text) => text.includes('queued-old')).length).toBe(0);

  replacement.client.write(requestText(2, 'listInstances'));
  await drain();
  expect(responseIds(replacement.connection.delivered.join(''))).toEqual([1, 2]);
});

test('a synchronous write failure drops only that peer and never escapes a broadcast', async () => {
  const f = fixture();
  await f.start();
  const broken = f.connectPeer(101);
  const healthy = f.connectPeer(102);
  broken.client.write(requestText(1, 'listInstances'));
  healthy.client.write(requestText(1, 'listInstances'));
  await drain();
  expect(broken.connection.delivered.length).toBe(1);

  broken.connection.mode = 'throw';
  expect(() => f.server.broadcastEvent('runtime_snapshot', 'x')).not.toThrow();
  await drain();
  expect(broken.connection.closed).toBe(true);
  expect(healthy.connection.closed).toBe(false);

  healthy.client.write(requestText(2, 'listInstances'));
  await drain();
  expect(responseIds(healthy.connection.delivered.join(''))).toEqual([1, 2]);
});

test('large valid responses are delivered while a frame past the protocol cap drops only its peer', async () => {
  let payload = 'z'.repeat(3 * 1024 * 1024);
  const f = fixture({ handler: async () => payload });
  await f.start();
  const peer = f.connectPeer(111);
  peer.connection.mode = 'hold';
  peer.client.write(requestText(1, 'callJsonRpc'));
  await drain();
  f.server.broadcastEvent('runtime_snapshot', 'small');
  peer.client.write(requestText(2, 'callJsonRpc'));
  await drain();
  expect(peer.connection.closed).toBe(false);
  expect(peer.connection.sentCalls).toBe(1);

  await peer.connection.releaseWrites();
  await drain();
  const frames = framesOf(peer.connection.delivered.join(''));
  expect(frames.filter((frame) => frame.type === 'response').map((frame) => frame.id)).toEqual([1, 2]);
  expect((frames[0].result as string).length).toBe(payload.length);
  expect((frames[2].result as string).length).toBe(payload.length);
  expect(frames[1].eventType).toBe('runtime_snapshot');

  payload = 'o'.repeat(4 * 1024 * 1024 + 1);
  const over = f.connectPeer(112);
  over.client.write(requestText(1, 'callJsonRpc'));
  await drain();
  expect(over.connection.closed).toBe(true);
  expect(over.connection.sentCalls).toBe(0);
});
