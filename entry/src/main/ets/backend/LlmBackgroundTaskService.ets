import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApplicationStateService } from './ApplicationStateService';
import { AppSettingsService, APP_SETTING_NOTIFY_ON_COMPLETED } from './AppSettingsService';
import { JsonRecord } from './HttpTypes';



const DOMAIN = 0x5441;
const TAG = 'LlmBackgroundTask';
const RESPONSE_NOTIFICATION_ID = 17001;
const WANT_AGENT_REQUEST_CODE = 17002;
const NOTIFICATION_REFUSED_CODE = 1600004;
const GENERATION_PREPARATION_TIMEOUT_MS = 5 * 60 * 1000;

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
  private notifyOnCompleted: boolean = false;
  private settings: AppSettingsService;
  private generationPreparations: Map<number, LlmBackgroundTaskHandle> = new Map();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.settings = AppSettingsService.getInstance(context.filesDir);
    this.notifyOnCompleted = this.settings.getBoolean(APP_SETTING_NOTIFY_ON_COMPLETED, false);
  }

  async beginResponse(): Promise<LlmBackgroundTaskHandle> {
    const handle = new LlmBackgroundTaskHandle(this.nextHandleId);
    this.nextHandleId += 1;
    this.activeCount += 1;
    if (this.activeCount === 1 || !this.continuousTaskRunning) {
      await this.startContinuousTask();
    } else if (this.startPromise !== null) {
      await this.startPromise;
    }
    return handle;
  }

  async beginGenerationPreparation(): Promise<JsonRecord> {
    const handle = await this.beginResponse();
    this.generationPreparations.set(handle.id, handle);
    setTimeout(() => {
      this.expireGenerationPreparation(handle.id);
    }, GENERATION_PREPARATION_TIMEOUT_MS);
    const value: JsonRecord = {};
    value['leaseId'] = handle.id;
    return value;
  }

  async finishGenerationPreparation(leaseId: number): Promise<JsonRecord> {
    const value: JsonRecord = {};
    const handle = this.generationPreparations.get(leaseId);
    if (handle === undefined) {
      value['released'] = false;
      return value;
    }
    this.generationPreparations.delete(leaseId);
    await this.finishResponse(handle, false);
    value['released'] = true;
    return value;
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
    if (notifyCompleted && this.notifyOnCompleted && ApplicationStateService.getInstance().isBackground()) {
      await this.publishResponseReadyNotification();
    }
  }

  isNotifyOnCompleted(): boolean {
    return this.notifyOnCompleted;
  }

  private expireGenerationPreparation(leaseId: number): void {
    if (!this.generationPreparations.has(leaseId)) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'Generation preparation lease timed out: %{public}d', leaseId);
    this.finishGenerationPreparation(leaseId).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to expire generation preparation lease: %{public}s', JSON.stringify(err));
    });
  }

  notificationPreferencesJson(): JsonRecord {
    const value: JsonRecord = {};
    value['notifyOnCompleted'] = this.notifyOnCompleted;
    value['permissionGranted'] = this.isNotificationEnabledSync();
    return value;
  }

  async updateNotifyOnCompleted(enabled: boolean): Promise<JsonRecord> {
    this.notifyOnCompleted = enabled;
    this.settings.setBoolean(APP_SETTING_NOTIFY_ON_COMPLETED, enabled);
    const value: JsonRecord = {};
    value['notifyOnCompleted'] = enabled;
    if (!enabled) {
      value['permissionGranted'] = this.isNotificationEnabledSync();
      value['message'] = '生成完成通知已关闭';
      return value;
    }
    if (this.isNotificationEnabledSync()) {
      value['permissionGranted'] = true;
      value['message'] = '已开启，生成完成后将推送通知';
      return value;
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
      value['permissionGranted'] = true;
      value['message'] = '已开启，生成完成后将推送通知';
      return value;
    } catch (err) {
      const error = err as BusinessError;
      if (error.code === NOTIFICATION_REFUSED_CODE) {
        await this.guideToNotificationSettings(value);
        return value;
      }
      value['permissionGranted'] = false;
      value['message'] = '申请通知权限失败';
      hilog.warn(DOMAIN, TAG, 'Failed to request notification permission: %{public}s', JSON.stringify(err));
      return value;
    }
  }


  private isNotificationEnabledSync(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to check notification permission: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private async guideToNotificationSettings(value: JsonRecord): Promise<void> {
    try {
      await notificationManager.openNotificationSettings(this.context);
      value['guided'] = true;
      value['permissionGranted'] = this.isNotificationEnabledSync();
      if (value['permissionGranted'] === true) {
        value['message'] = '已开启，生成完成后将推送通知';
      } else {
        value['message'] = '请在通知设置中允许 TavernNext 的通知权限';
      }
    } catch (err) {
      value['guided'] = false;
      value['permissionGranted'] = false;
      value['message'] = '请在系统设置中允许 TavernNext 的通知权限';
      hilog.warn(DOMAIN, TAG, 'Failed to open notification settings: %{public}s', JSON.stringify(err));
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
    if (!this.isNotificationEnabledSync()) {
      return;
    }
    try {
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

  private async wantAgent(): Promise<WantAgent> {
    if (this.responseNotificationWantAgent !== null) {
      return this.responseNotificationWantAgent;
    }
    const entryWant: Want = {
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: this.context.abilityInfo.name,
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
