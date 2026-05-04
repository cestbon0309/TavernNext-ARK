import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApplicationStateService } from './ApplicationStateService';

const DOMAIN = 0x544156;
const TAG = 'LlmBackgroundTask';
const RESPONSE_NOTIFICATION_ID = 17001;
const WANT_AGENT_REQUEST_CODE = 17002;

export class LlmBackgroundTaskHandle {
  readonly id: number;
  private valid: boolean = true;

  constructor(id: number) {
    this.id = id;
  }

  consume(): boolean {
    if (!this.valid) {
      return false;
    }
    this.valid = false;
    return true;
  }
}

export class LlmBackgroundTaskService {
  private context: common.UIAbilityContext;
  private activeCount: number = 0;
  private nextHandleId: number = 1;
  private continuousTaskId: number = -1;
  private continuousTaskRunning: boolean = false;
  private startPromise: Promise<void> | null = null;
  private stopPromise: Promise<void> | null = null;
  private responseNotificationWantAgent: WantAgent | null = null;
  private notificationPermissionRequested: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async beginResponse(): Promise<LlmBackgroundTaskHandle> {
    const handle = new LlmBackgroundTaskHandle(this.nextHandleId);
    this.nextHandleId += 1;
    this.activeCount += 1;
    if (this.activeCount === 1) {
      await this.startContinuousTask();
    } else if (this.startPromise !== null) {
      await this.startPromise;
    }
    return handle;
  }

  async finishResponse(handle: LlmBackgroundTaskHandle, notifyCompleted: boolean): Promise<void> {
    if (!handle.consume()) {
      return;
    }
    if (this.activeCount > 0) {
      this.activeCount -= 1;
    }
    if (this.activeCount === 0) {
      await this.stopContinuousTask();
    }
    if (notifyCompleted && ApplicationStateService.getInstance().isBackground()) {
      await this.publishResponseReadyNotification();
    }
  }

  private async startContinuousTask(): Promise<void> {
    if (this.startPromise !== null) {
      return this.startPromise;
    }
    this.startPromise = this.doStartContinuousTask();
    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  private async doStartContinuousTask(): Promise<void> {
    try {
      if (this.stopPromise !== null) {
        await this.stopPromise;
      }
      await this.ensureNotificationPermission();
      const agent = await this.wantAgent();
      const notification = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
      this.continuousTaskId = notification.continuousTaskId ?? -1;
      this.continuousTaskRunning = true;
      hilog.info(DOMAIN, TAG, 'Started DATA_TRANSFER continuous task: %{public}d', this.continuousTaskId);
    } catch (err) {
      this.continuousTaskId = -1;
      this.continuousTaskRunning = false;
      hilog.warn(DOMAIN, TAG, 'Failed to start DATA_TRANSFER continuous task: %{public}s', JSON.stringify(err));
    }
  }

  private async stopContinuousTask(): Promise<void> {
    if (this.stopPromise !== null) {
      return this.stopPromise;
    }
    this.stopPromise = this.doStopContinuousTask();
    try {
      await this.stopPromise;
    } finally {
      this.stopPromise = null;
    }
  }

  private async doStopContinuousTask(): Promise<void> {
    if (!this.continuousTaskRunning) {
      this.continuousTaskId = -1;
      return;
    }
    try {
      if (this.continuousTaskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(this.context, this.continuousTaskId);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      }
      hilog.info(DOMAIN, TAG, 'Stopped DATA_TRANSFER continuous task');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to stop DATA_TRANSFER continuous task: %{public}s', JSON.stringify(err));
    } finally {
      this.continuousTaskId = -1;
      this.continuousTaskRunning = false;
    }
  }

  private async publishResponseReadyNotification(): Promise<void> {
    try {
      await this.ensureNotificationPermission();
      await notificationManager.publish({
        id: RESPONSE_NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        tapDismissed: true,
        wantAgent: await this.wantAgent(),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'TavernNext',
            text: '回复已生成',
          },
        },
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to publish response notification: %{public}s', JSON.stringify(err));
    }
  }

  private async ensureNotificationPermission(): Promise<void> {
    if (this.notificationPermissionRequested) {
      return;
    }
    this.notificationPermissionRequested = true;
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(this.context);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to request notification permission: %{public}s', JSON.stringify(err));
    }
  }

  private async wantAgent(): Promise<WantAgent> {
    if (this.responseNotificationWantAgent !== null) {
      return this.responseNotificationWantAgent;
    }
    const entryWant: Want = {
      bundleName: 'com.esoteric.ark.tavernnext',
      abilityName: 'EntryAbility',
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [entryWant],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: WANT_AGENT_REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    this.responseNotificationWantAgent = await wantAgent.getWantAgent(info);
    return this.responseNotificationWantAgent;
  }
}
