import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';

const LIVE_VIEW_TYPE_CODE: number = 8;
const NO_NOTIFICATION_ID: number = -1;

export default class OhosLiveViewNotificationService {
  private notificationId: number = NO_NOTIFICATION_ID;

  publish(notificationId: number, progressValue: number): void {
    this.notificationId = notificationId;
    const downloadTemplate: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title: 'EasyTier Pro',
        fileName: '正在保活',
        progressValue,
      },
    };
    const request: notificationManager.NotificationRequest = {
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: LIVE_VIEW_TYPE_CODE,
          title: 'EasyTier Pro',
          text: '正在保活',
        },
      },
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: downloadTemplate,
    };
    try {
      notificationManager.publish(request)
        .then((): void => {
          if (this.notificationId !== notificationId) {
            this.cancelNotification(notificationId);
          }
        })
        .catch((error: BusinessError): void => {
          console.error(`[EasyTierProBackgroundTask] live-view notification publish failed: ${error.code}`);
          if (this.notificationId !== notificationId) {
            this.cancelNotification(notificationId);
          }
        });
    } catch (_error) {
      console.error('[EasyTierProBackgroundTask] live-view notification publish failed');
    }
  }

  cancel(): void {
    const notificationId: number = this.notificationId;
    this.notificationId = NO_NOTIFICATION_ID;
    if (notificationId === NO_NOTIFICATION_ID) {
      return;
    }
    this.cancelNotification(notificationId);
  }

  private cancelNotification(notificationId: number): void {
    try {
      notificationManager.cancel(notificationId)
        .catch((error: BusinessError): void => {
          console.error(`[EasyTierProBackgroundTask] live-view notification cancel failed: ${error.code}`);
        });
    } catch (_error) {
      console.error('[EasyTierProBackgroundTask] live-view notification cancel failed');
    }
  }
}
