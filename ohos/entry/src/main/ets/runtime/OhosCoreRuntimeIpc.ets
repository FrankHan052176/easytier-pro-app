import { BusinessError } from '@kit.BasicServicesKit';
import { buffer, JSON } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';

export const CORE_RUNTIME_SOCKET_NAME = 'easytier_pro_core_runtime.sock';

const MAX_SOCKET_REST_LENGTH = 4 * 1024 * 1024;
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
  resolve: (value: RuntimeValue) => void;
  reject: (reason: RuntimeIpcError) => void;

  constructor(
    timer: number,
    resolve: (value: RuntimeValue) => void,
    reject: (reason: RuntimeIpcError) => void,
  ) {
    this.timer = timer;
    this.resolve = resolve;
    this.reject = reject;
  }
}

class SocketDrainResult {
  messages: Array<string>;
  rest: string;

  constructor(messages: Array<string>, rest: string) {
    this.messages = messages;
    this.rest = rest;
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
      return params.type;
    case 'url':
      return params.url;
    case 'hostname':
      return params.hostname;
    case 'machineId':
      return params.machineId;
    case 'socketFilesDir':
      return params.socketFilesDir;
    case 'serviceName':
      return params.serviceName;
    case 'methodName':
      return params.methodName;
    case 'domainName':
      return params.domainName;
    case 'payloadJson':
      return params.payloadJson;
    case 'instanceName':
      return params.instanceName;
    default:
      return '';
  }
}

export function readBoolParam(params: RuntimeParams, key: string): boolean {
  return key === 'secureMode' ? params.secureMode : false;
}

export function readArrayParam(params: RuntimeParams, key: string): Array<string> {
  return key === 'instanceNames' ? params.instanceNames : [];
}

export function readObjectParam(params: RuntimeParams, key: string): RuntimeVpnConfig {
  return key === 'vpnConfig' ? params.vpnConfig : new RuntimeVpnConfig();
}

function encodeRuntimeMessage(message: Object): ArrayBuffer {
  return buffer.from(`${JSON.stringify(message)}\n`).buffer;
}

function decodeRuntimeMessages(currentBuffer: string, message: ArrayBuffer | Uint8Array | string): SocketDrainResult {
  const chunkText = typeof message === 'string' ? message : buffer.from(message).toString();
  const combined = (currentBuffer.length > MAX_SOCKET_REST_LENGTH ? '' : currentBuffer) + chunkText;
  const messages: Array<string> = [];
  let start = 0;
  while (start < combined.length) {
    const newlineIndex = combined.indexOf('\n', start);
    if (newlineIndex < 0) {
      break;
    }
    if (newlineIndex > start) {
      messages.push(combined.substring(start, newlineIndex));
    }
    start = newlineIndex + 1;
  }
  const rest = combined.substring(start);
  return new SocketDrainResult(messages, rest.length > MAX_SOCKET_REST_LENGTH ? '' : rest);
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
        if (!this.pending.has(id)) {
          return;
        }
        this.pending.delete(id);
        const error = new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          `HarmonyOS core runtime request timed out: ${method}`,
        );
        this.invalidateTransport(client, generation, error);
        reject(error);
      }, timeoutMs);
      this.pending.set(id, new PendingRuntimeRequest(timer, resolve, reject));
      const sendOptions: socket.LocalSendOptions = { data: encodeRuntimeMessage(request) };
      try {
        client.send(sendOptions).catch((error: BusinessError) => {
          if (!this.pending.has(id)) {
            return;
          }
          clearTimeout(timer);
          this.pending.delete(id);
          const transportError = new RuntimeIpcError(
            RUNTIME_IPC_ERROR_TRANSPORT,
            this.errorMessage(error),
          );
          this.invalidateTransport(client, generation, transportError);
          reject(transportError);
        });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        const transportError = new RuntimeIpcError(
          RUNTIME_IPC_ERROR_TRANSPORT,
          this.errorMessage(error),
        );
        this.invalidateTransport(client, generation, transportError);
        reject(transportError);
      }
    });
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
          this.invalidateTransport(client, generation, new RuntimeIpcError(
            RUNTIME_IPC_ERROR_TRANSPORT,
            `HarmonyOS core runtime protocol error: ${this.errorMessage(error)}`,
          ));
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
      if (pending === undefined) {
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

export class RuntimeIpcServer {
  private server: socket.LocalSocketServer | null = null;
  private connections: Map<number, socket.LocalSocketConnection> = new Map();
  private messageBuffers: Map<number, string> = new Map();
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
      this.connections.set(connection.clientId, connection);
      this.messageBuffers.set(connection.clientId, '');
      connection.on('message', (value: socket.LocalSocketMessageInfo) => {
        this.handleConnectionMessage(connection, value.message);
      });
      connection.on('close', () => {
        this.dropConnection(connection);
      });
      connection.on('error', () => {
        this.dropConnection(connection);
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
    this.connections.forEach((connection) => {
      closeRequests.push(this.closeConnection(connection));
    });
    this.connections.clear();
    this.messageBuffers.clear();
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
    this.connections.forEach((connection) => {
      this.sendRaw(connection, encodeRuntimeMessage(message));
    });
  }

  private handleConnectionMessage(connection: socket.LocalSocketConnection, message: ArrayBuffer | Uint8Array | string): void {
    const currentBuffer = this.messageBuffers.get(connection.clientId) ?? '';
    const decoded = decodeRuntimeMessages(currentBuffer, message);
    this.messageBuffers.set(connection.clientId, decoded.rest);
    for (const rawMessage of decoded.messages) {
      this.handleRawMessage(connection, rawMessage);
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

  private sendRaw(connection: socket.LocalSocketConnection, data: ArrayBuffer): void {
    const sendOptions: socket.LocalSendOptions = { data };
    connection.send(sendOptions).catch((_error: BusinessError) => {
      this.dropConnection(connection);
      this.closeConnection(connection).then(() => {
      });
    });
  }

  private dropConnection(connection: socket.LocalSocketConnection): void {
    this.connections.delete(connection.clientId);
    this.messageBuffers.delete(connection.clientId);
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
