import { BusinessError } from '@kit.BasicServicesKit';
import { buffer, JSON } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';

export const CORE_RUNTIME_SOCKET_NAME = 'easytier_pro_core_runtime.sock';

// A single newline terminated frame, and the partial frame held between socket
// chunks, may not exceed this size. Anything larger is a protocol overrun.
const MAX_SOCKET_FRAME_LENGTH = 4 * 1024 * 1024;
// Per peer outbound bound. A UI process whose reader is frozen must not make the
// runtime hold an unbounded amount of queued data or outstanding sends, while a
// single valid frame (at most the protocol frame cap) is still admitted when the
// peer is merely behind, so one large response is never dropped for a peer that
// keeps up.
const MAX_CONNECTION_QUEUE_MESSAGES = 64;
const MAX_CONNECTION_QUEUE_BYTES = 8 * 1024 * 1024;
const CONNECTION_SEND_TIMEOUT_MS = 5000;
const CONNECT_RETRY_LIMIT = 30;
const CONNECT_RETRY_DELAY_MS = 200;
const REQUEST_TIMEOUT_MS = 10000;

export const RUNTIME_IPC_ERROR_TRANSPORT = 'transport';
export const RUNTIME_IPC_ERROR_REMOTE = 'remote';

export class RuntimeIpcError extends Error {
  kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

export type RuntimeValue = Object | string | number | boolean | Array<string> | null;

export class RuntimeVpnConfig {
  addresses: Array<string> = [];
  address: string = '';
  routes: Array<string> = [];
  route: string = '';
  dns: Array<string> = [];
  dns_servers: Array<string> = [];
  dnsServers: Array<string> = [];
  disallowedApplications: Array<string> = [];
  disallowed_applications: Array<string> = [];
  disallowedPackages: Array<string> = [];
  disallowed_packages: Array<string> = [];
  mtu: number = 0;
}

// Shared snapshot contract between the VPN extension and the UI process. Both the
// getRuntimeSnapshot response and the runtime_snapshot event carry this object
// serialized as a JSON string. Never carries credentials or the full server URL.
export class RuntimeSnapshot {
  configServerConnected: boolean = false;
  activeVpnInstanceName: string = '';
  activeVpnInstanceId: string = '';
  vpnConfig: RuntimeVpnConfig | null = null;
  instances: Record<string, string> = {};
  lastError: string = '';
}

export class RuntimeParams {
  type: string = '';
  url: string = '';
  hostname: string = '';
  machineId: string = '';
  secureMode: boolean = false;
  socketFilesDir: string = '';
  serviceName: string = '';
  methodName: string = '';
  domainName: string = '';
  payloadJson: string = '';
  instanceNames: Array<string> = [];
  instanceName: string = '';
  vpnConfig: RuntimeVpnConfig = new RuntimeVpnConfig();
}

class RuntimeRequestMessage {
  type: string = '';
  id: number = 0;
  method: string = '';
  params: RuntimeParams = new RuntimeParams();
}

class RuntimeResponseMessage {
  type: string = '';
  id: number = 0;
  ok: boolean = false;
  result: RuntimeValue = null;
  error: string = '';
  errorCode: string = '';
}

class RuntimeEventMessage {
  type: string = '';
  eventType: string = '';
  payload: RuntimeValue = null;
}

class PendingRuntimeRequest {
  timer: number;
  client: socket.LocalSocket | null;
  generation: number;
  resolve: (value: RuntimeValue) => void;
  reject: (reason: RuntimeIpcError) => void;

  constructor(
    timer: number,
    client: socket.LocalSocket | null,
    generation: number,
    resolve: (value: RuntimeValue) => void,
    reject: (reason: RuntimeIpcError) => void,
  ) {
    this.timer = timer;
    this.client = client;
    this.generation = generation;
    this.resolve = resolve;
    this.reject = reject;
  }
}

class SocketDrainResult {
  messages: Array<string>;
  rest: string;
  overrun: boolean;

  constructor(messages: Array<string>, rest: string, overrun: boolean) {
    this.messages = messages;
    this.rest = rest;
    this.overrun = overrun;
  }
}

export type RuntimeRequestHandler = (method: string, params: RuntimeParams) => Promise<RuntimeValue>;
export type RuntimeEventHandler = (eventType: string, payload: RuntimeValue) => void;

export function runtimeSocketPath(filesDir: string): string {
  return `${filesDir}/${CORE_RUNTIME_SOCKET_NAME}`;
}

export function readStringParam(params: RuntimeParams, key: string): string {
  switch (key) {
    case 'type':
      return typeof params.type === 'string' ? params.type : '';
    case 'url':
      return typeof params.url === 'string' ? params.url : '';
    case 'hostname':
      return typeof params.hostname === 'string' ? params.hostname : '';
    case 'machineId':
      return typeof params.machineId === 'string' ? params.machineId : '';
    case 'socketFilesDir':
      return typeof params.socketFilesDir === 'string' ? params.socketFilesDir : '';
    case 'serviceName':
      return typeof params.serviceName === 'string' ? params.serviceName : '';
    case 'methodName':
      return typeof params.methodName === 'string' ? params.methodName : '';
    case 'domainName':
      return typeof params.domainName === 'string' ? params.domainName : '';
    case 'payloadJson':
      return typeof params.payloadJson === 'string' ? params.payloadJson : '';
    case 'instanceName':
      return typeof params.instanceName === 'string' ? params.instanceName : '';
    default:
      return '';
  }
}

export function readBoolParam(params: RuntimeParams, key: string): boolean {
  return key === 'secureMode' && typeof params.secureMode === 'boolean' ? params.secureMode : false;
}

export function readArrayParam(params: RuntimeParams, key: string): Array<string> {
  return key === 'instanceNames' && Array.isArray(params.instanceNames) ? params.instanceNames : [];
}

export function readObjectParam(params: RuntimeParams, key: string): RuntimeVpnConfig {
  if (key !== 'vpnConfig' || params.vpnConfig === undefined || params.vpnConfig === null) {
    return new RuntimeVpnConfig();
  }
  return params.vpnConfig;
}

function encodeRuntimeMessage(message: Object): ArrayBuffer {
  return buffer.from(`${JSON.stringify(message)}\n`).buffer;
}

function decodeRuntimeMessages(currentBuffer: string, message: ArrayBuffer | Uint8Array | string): SocketDrainResult {
  const chunkText = typeof message === 'string' ? message : buffer.from(message).toString();
  if (currentBuffer.length > MAX_SOCKET_FRAME_LENGTH) {
    return new SocketDrainResult([], '', true);
  }
  const combined = currentBuffer + chunkText;
  const messages: Array<string> = [];
  let start = 0;
  while (start < combined.length) {
    const newlineIndex = combined.indexOf('\n', start);
    if (newlineIndex < 0) {
      break;
    }
    if (newlineIndex - start > MAX_SOCKET_FRAME_LENGTH) {
      return new SocketDrainResult([], '', true);
    }
    if (newlineIndex > start) {
      messages.push(combined.substring(start, newlineIndex));
    }
    start = newlineIndex + 1;
  }
  const rest = combined.substring(start);
  if (rest.length > MAX_SOCKET_FRAME_LENGTH) {
    // Reporting the whole chunk as a protocol overrun is required here: dropping
    // just the head would turn the remainder into a bogus packet.
    return new SocketDrainResult([], '', true);
  }
  return new SocketDrainResult(messages, rest, false);
}

export class RuntimeIpcClient {
  private client: socket.LocalSocket | null = null;
  private socketPath: string = '';
  private connected: boolean = false;
  private messageBuffer: string = '';
  private nextRequestId: number = 1;
  private pending: Map<number, PendingRuntimeRequest> = new Map();
  private onEvent: RuntimeEventHandler;
  private onRemoteClose: (() => void) | undefined;
  private connectionGeneration: number = 0;
  private connectInFlight: Promise<void> | null = null;
  private connectInFlightPath: string = '';

  constructor(onEvent: RuntimeEventHandler, onRemoteClose?: () => void) {
    this.onEvent = onEvent;
    this.onRemoteClose = onRemoteClose;
  }

  isConnected(): boolean {
    return this.connected;
  }

  connect(path: string, maxAttempts: number = CONNECT_RETRY_LIMIT): Promise<void> {
    if (this.connected && this.socketPath === path && this.client !== null) {
      return Promise.resolve();
    }
    if (this.connectInFlight !== null && this.connectInFlightPath === path) {
      return this.connectInFlight;
    }
    const closeRequest = this.close();
    this.socketPath = path;
    this.connectInFlightPath = path;
    const generation = this.connectionGeneration;
    const request = closeRequest.then(() => this.connectWithRetry(path, 0, maxAttempts, generation));
    const trackedRequest = request.then(() => {
      this.clearConnectInFlight(generation);
    }).catch((error: Error) => {
      this.clearConnectInFlight(generation);
      throw error;
    });
    this.connectInFlight = trackedRequest;
    return trackedRequest;
  }

  request(method: string, params: RuntimeParams, timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<RuntimeValue> {
    const client = this.client;
    const generation = this.connectionGeneration;
    if (!this.connected || client === null) {
      return Promise.reject(new RuntimeIpcError(
        RUNTIME_IPC_ERROR_TRANSPORT,
        'HarmonyOS core runtime socket is not connected',
      ));
    }
    const id = this.nextRequestId++;
    const request = new RuntimeRequestMessage();
    request.type = 'request';
    request.id = id;
    request.method = method;
    request.params = params;
    return new Promise<RuntimeValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.consumePendingRequest(id, client, generation)) {
          // A superseded connection's timer must not reject later requests.
          return;
        }
        const error = new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          `HarmonyOS core runtime request timed out: ${method}`,
        );
        this.invalidateTransport(client, generation, error);
        reject(error);
      }, timeoutMs);
      this.pending.set(id, new PendingRuntimeRequest(timer, client, generation, resolve, reject));
      const sendOptions: socket.LocalSendOptions = { data: encodeRuntimeMessage(request) };
      try {
        client.send(sendOptions).catch((error: BusinessError) => {
          if (!this.consumePendingRequest(id, client, generation)) {
            // The transport was already replaced; a late write failure from the
            // old socket must not disturb the new one.
            return;
          }
          clearTimeout(timer);
          const transportError = new RuntimeIpcError(
            RUNTIME_IPC_ERROR_TRANSPORT,
            this.errorMessage(error),
          );
          this.invalidateTransport(client, generation, transportError);
          reject(transportError);
        });
      } catch (error) {
        if (!this.consumePendingRequest(id, client, generation)) {
          return;
        }
        clearTimeout(timer);
        const transportError = new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          this.errorMessage(error),
        );
        this.invalidateTransport(client, generation, transportError);
        reject(transportError);
      }
    });
  }

  private isCurrentPendingRequest(id: number, client: socket.LocalSocket, generation: number): boolean {
    const pending = this.pending.get(id);
    return pending !== undefined && pending.client === client && pending.generation === generation;
  }

  private consumePendingRequest(id: number, client: socket.LocalSocket, generation: number): boolean {
    if (!this.isCurrentPendingRequest(id, client, generation)) {
      return false;
    }
    this.pending.delete(id);
    return true;
  }

  close(): Promise<void> {
    this.connectionGeneration += 1;
    this.connectInFlight = null;
    this.connectInFlightPath = '';
    const client = this.client;
    this.client = null;
    this.connected = false;
    this.messageBuffer = '';
    this.rejectAllPending(new RuntimeIpcError(
      RUNTIME_IPC_ERROR_TRANSPORT,
      'HarmonyOS core runtime socket closed',
    ));
    if (client === null) {
      return Promise.resolve();
    }
    return this.closeClient(client);
  }

  private connectWithRetry(path: string, attempt: number, maxAttempts: number, generation: number): Promise<void> {
    if (generation !== this.connectionGeneration) {
      return Promise.reject(new RuntimeIpcError(
        RUNTIME_IPC_ERROR_TRANSPORT,
        'HarmonyOS core runtime socket connection was superseded',
      ));
    }
    return new Promise<void>((resolve, reject) => {
      const client = socket.constructLocalSocketInstance();
      this.client = client;
      client.on('message', (value: socket.LocalSocketMessageInfo) => {
        if (generation !== this.connectionGeneration || this.client !== client) {
          return;
        }
        try {
          this.handleSocketMessage(value.message);
        } catch (error) {
          const failure = error instanceof RuntimeIpcError
            ? error as RuntimeIpcError
            : new RuntimeIpcError(
              RUNTIME_IPC_ERROR_TRANSPORT,
              `HarmonyOS core runtime protocol error: ${this.errorMessage(error)}`,
            );
          this.invalidateTransport(client, generation, failure);
        }
      });
      client.on('close', () => {
        this.invalidateTransport(client, generation, new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          'HarmonyOS core runtime socket closed',
        ));
      });
      client.on('error', (error: BusinessError) => {
        this.invalidateTransport(client, generation, new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          this.errorMessage(error),
        ));
      });

      const connectOptions: socket.LocalConnectOptions = {
        address: { address: path },
        timeout: 3000,
      };
      client.connect(connectOptions).then(() => {
        if (generation !== this.connectionGeneration || this.client !== client) {
          this.closeClient(client).then(() => {
            reject(new RuntimeIpcError(
              RUNTIME_IPC_ERROR_TRANSPORT,
              'HarmonyOS core runtime socket connection was superseded',
            ));
          });
          return;
        }
        this.connected = true;
        resolve();
      }).catch((error: BusinessError) => {
        if (this.client === client) {
          this.client = null;
        }
        this.closeClient(client).then(() => {
          if (generation !== this.connectionGeneration) {
            reject(new RuntimeIpcError(
              RUNTIME_IPC_ERROR_TRANSPORT,
              'HarmonyOS core runtime socket connection was superseded',
            ));
            return;
          }
          if (attempt + 1 >= maxAttempts) {
            reject(new RuntimeIpcError(RUNTIME_IPC_ERROR_TRANSPORT, this.errorMessage(error)));
            return;
          }
          setTimeout(() => {
            this.connectWithRetry(path, attempt + 1, maxAttempts, generation).then(resolve).catch(reject);
          }, CONNECT_RETRY_DELAY_MS);
        });
      });
    });
  }

  private invalidateTransport(
    client: socket.LocalSocket,
    generation: number,
    error: RuntimeIpcError,
  ): void {
    if (generation !== this.connectionGeneration || this.client !== client) {
      return;
    }
    this.connectionGeneration += 1;
    this.client = null;
    this.connected = false;
    this.messageBuffer = '';
    this.connectInFlight = null;
    this.connectInFlightPath = '';
    this.rejectAllPending(error);
    this.closeClient(client).then(() => {
    });
    this.onRemoteClose?.();
  }

  private closeClient(client: socket.LocalSocket): Promise<void> {
    try {
      return client.close().catch((error: BusinessError): void => {
        console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(error)}`);
      });
    } catch (error) {
      console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(error)}`);
      return Promise.resolve();
    }
  }

  private clearConnectInFlight(generation: number): void {
    if (generation !== this.connectionGeneration) {
      return;
    }
    this.connectInFlight = null;
    this.connectInFlightPath = '';
  }

  private handleSocketMessage(message: ArrayBuffer | Uint8Array | string): void {
    const decoded = decodeRuntimeMessages(this.messageBuffer, message);
    if (decoded.overrun) {
      throw new RuntimeIpcError(
        RUNTIME_IPC_ERROR_TRANSPORT,
        'HarmonyOS core runtime protocol frame exceeds the supported size',
      );
    }
    this.messageBuffer = decoded.rest;
    for (const rawMessage of decoded.messages) {
      const parsed = JSON.parse(rawMessage) as RuntimeResponseMessage;
      if (parsed.type === 'event') {
        const event = JSON.parse(rawMessage) as RuntimeEventMessage;
        this.onEvent(event.eventType, event.payload);
        continue;
      }
      if (parsed.type !== 'response') {
        continue;
      }
      const pending = this.pending.get(parsed.id);
      if (pending === undefined || pending.generation !== this.connectionGeneration || pending.client !== this.client) {
        // A response from a superseded connection must not settle a later request.
        continue;
      }
      clearTimeout(pending.timer);
      this.pending.delete(parsed.id);
      if (parsed.ok) {
        pending.resolve(parsed.result);
      } else {
        const message = parsed.error.length > 0 ? parsed.error : 'HarmonyOS core runtime request failed';
        pending.reject(new RuntimeIpcError(RUNTIME_IPC_ERROR_REMOTE, message));
      }
    }
  }

  private rejectAllPending(error: RuntimeIpcError): void {
    this.pending.forEach((pending) => {
      clearTimeout(pending.timer);
      pending.reject(error);
    });
    this.pending.clear();
  }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    const message = businessError.message ?? `${error}`;
    return typeof businessError.code === 'number' ?
      `code=${businessError.code}, message=${message}` : message;
  }
}

// One live peer of the runtime socket server. `clientId` values are reused by the
// OS after a connection closes, so every callback and send result is validated
// against this object identity before it may touch server state.
class RuntimeConnection {
  connection: socket.LocalSocketConnection;
  clientId: number;
  buffer: string = '';
  queued: Array<ArrayBuffer> = [];
  queuedBytes: number = 0;
  sendSequence: number = 0;
  sendTimer: number = 0;
  sending: boolean = false;
  closed: boolean = false;

  constructor(connection: socket.LocalSocketConnection) {
    this.connection = connection;
    this.clientId = connection.clientId;
  }
}

export class RuntimeIpcServer {
  private server: socket.LocalSocketServer | null = null;
  private connections: Map<number, RuntimeConnection> = new Map();
  private handler: RuntimeRequestHandler;
  private lifecycle: Promise<void> = Promise.resolve();
  private lifecycleGeneration: number = 0;

  constructor(handler: RuntimeRequestHandler) {
    this.handler = handler;
  }

  start(socketFilesDir: string): Promise<void> {
    const generation = ++this.lifecycleGeneration;
    const operation = this.lifecycle
      .then(() => this.closeCurrent())
      .then(() => this.listen(socketFilesDir, generation));
    this.lifecycle = operation.catch((_error: Error): void => {
    });
    return operation;
  }

  close(): Promise<void> {
    ++this.lifecycleGeneration;
    const operation = this.lifecycle.then(() => this.closeCurrent());
    this.lifecycle = operation.catch((_error: Error): void => {
    });
    return operation;
  }

  private listen(socketFilesDir: string, generation: number): Promise<void> {
    if (generation !== this.lifecycleGeneration) {
      return Promise.reject(new Error('HarmonyOS core runtime socket server start was superseded'));
    }
    const path = runtimeSocketPath(socketFilesDir);
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
    }

    const server = socket.constructLocalSocketServerInstance();
    this.server = server;
    server.on('connect', (connection: socket.LocalSocketConnection) => {
      if (generation !== this.lifecycleGeneration || this.server !== server) {
        this.closeConnection(connection).then(() => {
        });
        return;
      }
      const state = new RuntimeConnection(connection);
      const replaced = this.connections.get(state.clientId);
      if (replaced !== undefined) {
        // The OS reuses clientIds. Dispose the replaced peer's queue and timers
        // now, because its own close/error callbacks can no longer match it. Only
        // the stale connection object is closed; the replacement is kept.
        this.connections.delete(replaced.clientId);
        this.discardState(replaced);
        this.closeConnection(replaced.connection).then(() => {
        });
      }
      this.connections.set(state.clientId, state);
      connection.on('message', (value: socket.LocalSocketMessageInfo) => {
        this.handleConnectionMessage(state, value.message);
      });
      connection.on('close', () => {
        this.releaseConnection(state);
      });
      connection.on('error', () => {
        this.releaseConnection(state);
      });
    });
    const listenAddress: socket.LocalAddress = { address: path };
    return server.listen(listenAddress).catch((error: BusinessError) => {
      if (this.server === server) {
        this.server = null;
      }
      throw new Error(`HarmonyOS core runtime socket listen failed: ${this.errorMessage(error)}`);
    });
  }

  private closeCurrent(): Promise<void> {
    const closeRequests: Array<Promise<void>> = [];
    const states: Array<RuntimeConnection> = [];
    this.connections.forEach((state) => {
      states.push(state);
    });
    this.connections.clear();
    for (const state of states) {
      this.discardState(state);
      closeRequests.push(this.closeConnection(state.connection));
    }
    const server = this.server;
    this.server = null;
    if (server !== null) {
      try {
        closeRequests.push(server.close().catch((error: BusinessError): void => {
          console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(error)}`);
        }));
      } catch (error) {
        console.error(`HarmonyOS core runtime socket close failed: ${this.errorMessage(error)}`);
      }
    }
    return Promise.all(closeRequests).then((): void => {
    });
  }

  broadcastEvent(eventType: string, payload: RuntimeValue): void {
    const message = new RuntimeEventMessage();
    message.type = 'event';
    message.eventType = eventType;
    message.payload = payload;
    const data = encodeRuntimeMessage(message);
    const states: Array<RuntimeConnection> = [];
    this.connections.forEach((state) => {
      states.push(state);
    });
    // Never awaited: the native control loop must not block on a slow peer. The
    // frame is encoded once and shared by every peer.
    for (const state of states) {
      this.sendRaw(state.connection, data);
    }
  }

  private handleConnectionMessage(state: RuntimeConnection, message: ArrayBuffer | Uint8Array | string): void {
    if (!this.isCurrentState(state) || state.closed) {
      return;
    }
    const decoded = decodeRuntimeMessages(state.buffer, message);
    if (decoded.overrun) {
      this.dropConnection(state);
      return;
    }
    state.buffer = decoded.rest;
    for (const rawMessage of decoded.messages) {
      this.handleRawMessage(state.connection, rawMessage);
    }
  }

  private handleRawMessage(connection: socket.LocalSocketConnection, rawMessage: string): void {
    let request: RuntimeRequestMessage;
    try {
      request = JSON.parse(rawMessage) as RuntimeRequestMessage;
    } catch (error) {
      const response = new RuntimeResponseMessage();
      response.type = 'response';
      response.id = 0;
      response.ok = false;
      response.error = this.errorMessage(error);
      this.sendResponse(connection, response);
      return;
    }
    if (request.type !== 'request') {
      return;
    }
    this.handler(request.method, request.params ?? new RuntimeParams())
      .then((value: RuntimeValue) => {
        const response = new RuntimeResponseMessage();
        response.type = 'response';
        response.id = request.id;
        response.ok = true;
        response.result = value;
        this.sendResponse(connection, response);
      })
      .catch((error: Error) => {
        const response = new RuntimeResponseMessage();
        response.type = 'response';
        response.id = request.id;
        response.ok = false;
        response.error = this.errorMessage(error);
        this.sendResponse(connection, response);
      });
  }

  private sendResponse(connection: socket.LocalSocketConnection, response: RuntimeResponseMessage): void {
    this.sendRaw(connection, encodeRuntimeMessage(response));
  }

  // Enqueues one frame for a peer. Sends are strictly serial per peer so response
  // ordering and newline framing are preserved, while the queue and the in-flight
  // write stay bounded: a peer whose reader is frozen is dropped rather than
  // accumulating data or unacknowledged native sends. Other peers and the native
  // control loop are never blocked by a slow peer.
  private sendRaw(connection: socket.LocalSocketConnection, data: ArrayBuffer): void {
    const state = this.connections.get(connection.clientId);
    if (state === undefined || state.connection !== connection || state.closed) {
      return;
    }
    if (data.byteLength > MAX_SOCKET_FRAME_LENGTH) {
      // The outbound side honours the same frame cap as the decoder.
      this.dropConnection(state);
      return;
    }
    const idle = !state.sending && state.queued.length === 0;
    if (!idle
      && (state.queued.length >= MAX_CONNECTION_QUEUE_MESSAGES
        || state.queuedBytes + data.byteLength > MAX_CONNECTION_QUEUE_BYTES)) {
      this.dropConnection(state);
      return;
    }
    state.queued.push(data);
    state.queuedBytes += data.byteLength;
    this.pumpConnection(state);
  }

  private pumpConnection(state: RuntimeConnection): void {
    if (state.sending || state.closed || state.queued.length === 0) {
      return;
    }
    if (!this.isCurrentState(state)) {
      // The peer was released or replaced; never write through a stale connection.
      this.discardState(state);
      return;
    }
    const data = state.queued.shift();
    if (data === undefined) {
      return;
    }
    state.queuedBytes -= data.byteLength;
    state.sending = true;
    state.sendSequence += 1;
    const sequence = state.sendSequence;
    state.sendTimer = setTimeout(() => {
      if (state.sendSequence !== sequence) {
        return;
      }
      state.sendTimer = 0;
      state.sending = false;
      // A write that never settles means the peer stopped reading entirely.
      this.dropConnection(state);
    }, CONNECTION_SEND_TIMEOUT_MS);
    const sendOptions: socket.LocalSendOptions = { data };
    try {
      state.connection.send(sendOptions).then(() => {
        if (state.sendSequence !== sequence) {
          // Result of a write that was already abandoned or superseded.
          return;
        }
        clearTimeout(state.sendTimer);
        state.sendTimer = 0;
        state.sending = false;
        this.pumpConnection(state);
      }).catch((_error: BusinessError) => {
        if (state.sendSequence !== sequence) {
          return;
        }
        clearTimeout(state.sendTimer);
        state.sendTimer = 0;
        state.sending = false;
        this.dropConnection(state);
      });
    } catch (_error) {
      // A synchronous write failure is a failure of this peer only.
      this.dropConnection(state);
    }
  }

  private isCurrentState(state: RuntimeConnection): boolean {
    return this.connections.get(state.clientId) === state;
  }

  private releaseConnection(state: RuntimeConnection): void {
    if (!this.isCurrentState(state)) {
      return;
    }
    this.discardState(state);
    this.connections.delete(state.clientId);
  }

  private dropConnection(state: RuntimeConnection): void {
    if (!this.isCurrentState(state)) {
      return;
    }
    this.connections.delete(state.clientId);
    this.discardState(state);
    this.closeConnection(state.connection).then(() => {
    });
  }

  private discardState(state: RuntimeConnection): void {
    state.closed = true;
    state.buffer = '';
    state.queued = [];
    state.queuedBytes = 0;
    state.sending = false;
    // Invalidate every in-flight write result for this peer.
    state.sendSequence += 1;
    if (state.sendTimer !== 0) {
      clearTimeout(state.sendTimer);
      state.sendTimer = 0;
    }
  }

  private closeConnection(connection: socket.LocalSocketConnection): Promise<void> {
    try {
      return connection.close().catch((error: BusinessError): void => {
        console.error(`HarmonyOS core runtime connection close failed: ${this.errorMessage(error)}`);
      });
    } catch (error) {
      console.error(`HarmonyOS core runtime connection close failed: ${this.errorMessage(error)}`);
      return Promise.resolve();
    }
  }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    const message = businessError.message ?? `${error}`;
    return typeof businessError.code === 'number' ?
      `code=${businessError.code}, message=${message}` : message;
  }
}
