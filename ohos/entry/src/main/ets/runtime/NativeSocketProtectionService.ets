import { vpnExtension } from '@kit.NetworkKit';
import easytier from 'easytier-ohrs';

// Core owns each duplicated FD until ACK. Never close it in ArkTS or ACK before
// protect() settles. Only Core-selected underlay sockets bypass the VPN;
// TUN-facing listeners and their replies must remain unprotected.
export class NativeSocketProtectionService {
  private active: boolean = false;
  private generation: number = 0;
  private loopPromise: Promise<void> | undefined = undefined;
  private stopPromise: Promise<void> | undefined = undefined;
  private connectionOperationQueue: Promise<void> = Promise.resolve();
  private readonly getVpnConnection: () => vpnExtension.VpnConnection | null;
  private readonly onFatal: (error: Error) => void;

  constructor(getVpnConnection: () => vpnExtension.VpnConnection | null, onFatal: (error: Error) => void) {
    this.getVpnConnection = getVpnConnection;
    this.onFatal = onFatal;
  }

  async start(): Promise<void> {
    if (this.stopPromise !== undefined) {
      await this.stopPromise;
    }
    if (this.active) {
      return;
    }
    if (!easytier.enableSocketProtection()) {
      throw new Error('HarmonyOS socket protection could not be enabled');
    }
    this.active = true;
    const generation = ++this.generation;
    this.loopPromise = this.run(generation).catch((error: Error) => {
      if (this.active && this.generation === generation) {
        this.active = false;
        easytier.failSocketProtection();
        this.onFatal(error);
      }
    });
  }

  stop(): Promise<void> {
    if (this.stopPromise !== undefined) {
      return this.stopPromise;
    }
    if (!this.active && this.loopPromise === undefined) {
      return Promise.resolve();
    }
    this.active = false;
    this.generation++;
    // Wake the consumer and reject queued/new transport sockets. Keep Core's
    // disabled protector installed until the next start (no fail-open window).
    easytier.failSocketProtection();
    const loop = this.loopPromise;
    const stopping = Promise.resolve(loop).then(() => {
      this.loopPromise = undefined;
      this.stopPromise = undefined;
    });
    this.stopPromise = stopping;
    return stopping;
  }

  // Caller serializes runtime operations. Partial native teardown can block on
  // transport startup too, so drain ACKs and then resume protection for survivors.
  async runNativeTeardown<T>(operation: () => T): Promise<T> {
    const resume = this.active;
    await this.stop();
    try {
      return operation();
    } finally {
      if (resume) {
        await this.start();
      }
    }
  }

  runConnectionOperation<T>(operation: () => Promise<T>): Promise<T> {
    const task = this.connectionOperationQueue.then(operation);
    this.connectionOperationQueue = task.then(() => {}, () => {});
    return task;
  }

  private async run(generation: number): Promise<void> {
    while (this.active && this.generation === generation) {
      const request = await easytier.nextSocketProtectionRequest();
      if (request === null) {
        if (this.active && this.generation === generation) {
          throw new Error('HarmonyOS socket protection stream closed unexpectedly');
        }
        return;
      }
      let failure = '';
      try {
        await this.runConnectionOperation(async () => {
          if (!this.active || this.generation !== generation) {
            throw new Error('HarmonyOS socket protection stopped');
          }
          const vpnConnection = this.getVpnConnection();
          if (vpnConnection === null) {
            throw new Error('HarmonyOS VPN connection is unavailable');
          }
          await vpnConnection.protect(request.socketFd);
        });
      } catch (error) {
        failure = (error as Error).message;
      }
      const stopped = !this.active || this.generation !== generation;
      const success = failure.length === 0 && !stopped;
      // A rejected ACK only means Core already dropped the awaiting socket, and a
      // failed protect() makes Core fail that socket creation. Neither is reason
      // to tear the runtime down: the unprotectable socket is never used, so the
      // pump stays fail-closed per socket instead of stopping the whole VPN.
      const acknowledged = easytier.completeSocketProtection(
        request.requestId,
        success,
        success ? undefined : (failure.length > 0 ? failure : 'HarmonyOS socket protection stopped'),
      );
      if (stopped) {
        return;
      }
      if (!success) {
        console.warn(`[EasyTierProVpn] socket protection failed for fd ${request.socketFd}: ${failure}`);
      } else if (!acknowledged) {
        console.info(`[EasyTierProVpn] socket protection request ${request.requestId} was already released`);
      }
    }
  }
}
