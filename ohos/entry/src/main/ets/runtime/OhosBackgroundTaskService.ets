import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import OhosLiveViewNotificationService from './OhosLiveViewNotificationService';

const BUNDLE_NAME = 'net.easytier.pro';
const ENTRY_ABILITY_NAME = 'EntryAbility';
const MAX_START_RETRY_ATTEMPTS: number = 3;
const START_RETRY_DELAY_MS: number = 500;
const KEEPALIVE_UPDATE_INTERVAL_MS: number = 5000;

let sharedBackgroundTaskService: OhosBackgroundTaskService | null = null;

export function getOhosBackgroundTaskService(context: common.UIAbilityContext): OhosBackgroundTaskService {
  if (sharedBackgroundTaskService === null) {
    sharedBackgroundTaskService = new OhosBackgroundTaskService(context);
  } else {
    sharedBackgroundTaskService.updateContext(context);
  }
  return sharedBackgroundTaskService;
}

export default class OhosBackgroundTaskService {
  private context: common.UIAbilityContext;
  private uiBackground: boolean = false;
  private runtimeActive: boolean = false;
  private shouldRun: boolean = false;
  private isStarting: boolean = false;
  private isRunning: boolean = false;
  private isStopping: boolean = false;
  private startRetryAttempts: number = 0;
  private startRetryTimer: number = -1;
  private keepaliveUpdateTimer: number = -1;
  private keepaliveProgress: number = 5;
  private liveViewNotificationService: OhosLiveViewNotificationService = new OhosLiveViewNotificationService();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  updateContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setUiBackground(background: boolean): void {
    this.uiBackground = background;
    this.updateDesiredState();
  }

  setRuntimeActive(active: boolean): void {
    this.runtimeActive = active;
    this.updateDesiredState();
  }

  private updateDesiredState(): void {
    const desired: boolean = this.uiBackground && this.runtimeActive;
    const wasDesired: boolean = this.shouldRun;
    this.shouldRun = desired;
    if (desired && !wasDesired) {
      this.resetStartRetryState();
    }
    if (!desired) {
      this.stop();
      return;
    }
    this.startIfPossible();
  }

  private stop(): void {
    this.shouldRun = false;
    this.resetStartRetryState();
    this.stopKeepaliveUpdates();
    this.liveViewNotificationService.cancel();
    if (!this.isRunning || this.isStopping) {
      return;
    }
    this.isStopping = true;
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context)
        .then((): void => {
          this.finishStoppedTask();
        })
        .catch((error: BusinessError): void => {
          console.error(`[EasyTierProBackgroundTask] stopBackgroundRunning failed: ${error.code}`);
          this.finishStoppedTask();
        });
    } catch (_error) {
      console.error('[EasyTierProBackgroundTask] stopBackgroundRunning failed');
      this.finishStoppedTask();
    }
  }

  private startIfPossible(): void {
    if (!this.shouldRun || !this.uiBackground || !this.runtimeActive || this.isRunning || this.isStarting || this.isStopping) {
      return;
    }
    this.isStarting = true;
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: BUNDLE_NAME,
          abilityName: ENTRY_ABILITY_NAME,
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    try {
      wantAgent.getWantAgent(wantAgentInfo)
        .then((wantAgentObj: WantAgent): void => {
          if (!this.shouldRun || !this.uiBackground || !this.runtimeActive) {
            this.isStarting = false;
            return;
          }
          this.startBackgroundRunning(wantAgentObj);
        })
        .catch((error: BusinessError): void => {
          console.error(`[EasyTierProBackgroundTask] getWantAgent failed: ${error.code}`);
          this.handleStartFailure();
        });
    } catch (_error) {
      console.error('[EasyTierProBackgroundTask] getWantAgent failed');
      this.handleStartFailure();
    }
  }

  private startBackgroundRunning(wantAgentObj: WantAgent): void {
    try {
      backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], wantAgentObj)
        .then((res: backgroundTaskManager.ContinuousTaskNotification): void => {
          this.isStarting = false;
          this.isRunning = true;
          this.resetStartRetryState();
          if (!this.shouldRun || !this.uiBackground || !this.runtimeActive) {
            this.stop();
            return;
          }
          this.keepaliveProgress = 5;
          this.liveViewNotificationService.publish(res.notificationId, this.keepaliveProgress);
          this.startKeepaliveUpdates(res.notificationId);
        })
        .catch((error: BusinessError): void => {
          console.error(`[EasyTierProBackgroundTask] startBackgroundRunning failed: ${error.code}`);
          this.handleStartFailure();
        });
    } catch (_error) {
      console.error('[EasyTierProBackgroundTask] startBackgroundRunning failed');
      this.handleStartFailure();
    }
  }

  private handleStartFailure(): void {
    this.isStarting = false;
    if (!this.shouldRun || !this.uiBackground || !this.runtimeActive || this.isRunning || this.isStopping || this.startRetryTimer !== -1) {
      return;
    }
    if (this.startRetryAttempts >= MAX_START_RETRY_ATTEMPTS) {
      console.error('[EasyTierProBackgroundTask] start retry limit reached');
      return;
    }
    this.startRetryAttempts++;
    this.startRetryTimer = setTimeout((): void => {
      this.startRetryTimer = -1;
      this.startIfPossible();
    }, START_RETRY_DELAY_MS);
  }

  private resetStartRetryState(): void {
    if (this.startRetryTimer !== -1) {
      clearTimeout(this.startRetryTimer);
    }
    this.startRetryTimer = -1;
    this.startRetryAttempts = 0;
  }

  private startKeepaliveUpdates(notificationId: number): void {
    this.stopKeepaliveUpdates();
    if (!this.isRunning || !this.shouldRun || !this.uiBackground || !this.runtimeActive) {
      return;
    }
    this.keepaliveUpdateTimer = setInterval((): void => {
      this.updateKeepalive(notificationId);
    }, KEEPALIVE_UPDATE_INTERVAL_MS);
  }

  private updateKeepalive(notificationId: number): void {
    if (!this.isRunning || !this.shouldRun || !this.uiBackground || !this.runtimeActive) {
      return;
    }
    if (this.keepaliveProgress >= 90) {
      const decrease: number = Math.floor(Math.random() * 6) + 3;
      this.keepaliveProgress = Math.max(5, this.keepaliveProgress - decrease);
    } else {
      this.keepaliveProgress++;
    }
    this.liveViewNotificationService.publish(notificationId, this.keepaliveProgress);
  }

  private stopKeepaliveUpdates(): void {
    if (this.keepaliveUpdateTimer !== -1) {
      clearInterval(this.keepaliveUpdateTimer);
    }
    this.keepaliveUpdateTimer = -1;
  }

  private finishStoppedTask(): void {
    this.isRunning = false;
    this.isStopping = false;
    this.stopKeepaliveUpdates();
    this.liveViewNotificationService.cancel();
    this.startIfPossible();
  }
}
