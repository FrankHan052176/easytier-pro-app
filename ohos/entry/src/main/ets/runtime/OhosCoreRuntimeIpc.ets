import { BusinessError } from '@kit.BasicServicesKit';
import { buffer, JSON } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';

export const CORE_RUNTIME_SOCKET_NAME = 'easytier_pro_core_runtime.sock';

const MAX_SOCKET_REST_LENGTH = 4 * 1024 * 1024;
const CONNECT_RETRY_LIMIT = 30;
const CONNECT_RETRY_DELAY_MS = 200;
const REQUEST_TIMEOUT_MS = 10000;

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
  reject: (reason: Error) => void;

  constructor(timer: number, resolve: (value: RuntimeValue) => void, reject: (reason: Error) => void) {
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
    this.close();
    this.socketPath = path;
    return this.connectWithRetry(0, maxAttempts);
  }

  request(method: string, params: RuntimeParams): Promise<RuntimeValue> {
    if (!this.connected || this.client === null) {
      return Promise.reject(new Error('HarmonyOS core runtime socket is not connected'));
    }
    const id = this.nextRequestId++;
    const request = new RuntimeRequestMessage();
    request.type = 'request';
    request.id = id;
    request.method = method;
    request.params = params;
    return new Promise<RuntimeValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`HarmonyOS core runtime request timed out: ${method}`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, new PendingRuntimeRequest(timer, resolve, reject));
      const sendOptions: socket.LocalSendOptions = { data: encodeRuntimeMessage(request) };
      this.client?.send(sendOptions).catch((error: BusinessError) => {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error(this.errorMessage(error)));
      });
    });
  }

  close(): void {
    const client = this.client;
    this.client = null;
    this.connected = false;
    this.messageBuffer = '';
    this.rejectAllPending(new Error('HarmonyOS core runtime socket closed'));
    try {
      client?.close();
    } catch (_) {
    }
  }

  private connectWithRetry(attempt: number, maxAttempts: number = CONNECT_RETRY_LIMIT): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const client = socket.constructLocalSocketInstance();
      this.client = client;
      client.on('message', (value: socket.LocalSocketMessageInfo) => {
        if (this.client !== client) {
          return;
        }
        this.handleSocketMessage(value.message);
      });
      client.on('close', () => {
        if (this.client !== client) {
          return;
        }
        this.connected = false;
        this.rejectAllPending(new Error('HarmonyOS core runtime socket closed'));
        this.onRemoteClose?.();
      });
      client.on('error', (error: BusinessError) => {
        if (this.client !== client) {
          return;
        }
        this.connected = false;
        this.rejectAllPending(new Error(this.errorMessage(error)));
      });

      const connectOptions: socket.LocalConnectOptions = {
        address: { address: this.socketPath },
        timeout: 3000,
      };
      client.connect(connectOptions).then(() => {
        this.connected = true;
        resolve();
      }).catch((error: BusinessError) => {
        try {
          client.close();
        } catch (_) {
        }
        if (attempt >= maxAttempts) {
          reject(new Error(this.errorMessage(error)));
          return;
        }
        setTimeout(() => {
          this.connectWithRetry(attempt + 1, maxAttempts).then(resolve).catch(reject);
        }, CONNECT_RETRY_DELAY_MS);
      });
    });
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
        pending.reject(new Error(parsed.error.length > 0 ? parsed.error : 'HarmonyOS core runtime request failed'));
      }
    }
  }

  private rejectAllPending(error: Error): void {
    this.pending.forEach((pending) => {
      clearTimeout(pending.timer);
      pending.reject(error);
    });
    this.pending.clear();
  }

  private errorMessage(error: Object): string {
    const typed = error as Error;
    return typed.message ?? `${error}`;
  }
}

export class RuntimeIpcServer {
  private server: socket.LocalSocketServer | null = null;
  private connections: Map<number, socket.LocalSocketConnection> = new Map();
  private messageBuffers: Map<number, string> = new Map();
  private handler: RuntimeRequestHandler;

  constructor(handler: RuntimeRequestHandler) {
    this.handler = handler;
  }

  start(socketFilesDir: string): void {
    this.close();
    const path = runtimeSocketPath(socketFilesDir);
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
    }

    const server = socket.constructLocalSocketServerInstance();
    this.server = server;
    server.on('connect', (connection: socket.LocalSocketConnection) => {
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
    server.listen(listenAddress).catch((_error: BusinessError) => {
    });
  }

  close(): void {
    this.connections.forEach((connection) => {
      try {
        connection.close();
      } catch (_) {
      }
    });
    this.connections.clear();
    this.messageBuffers.clear();
    try {
      this.server?.close();
    } catch (_) {
    }
    this.server = null;
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
    });
  }

  private dropConnection(connection: socket.LocalSocketConnection): void {
    this.connections.delete(connection.clientId);
    this.messageBuffers.delete(connection.clientId);
  }

  private errorMessage(error: Object): string {
    const typed = error as Error;
    return typed.message ?? `${error}`;
  }
}
