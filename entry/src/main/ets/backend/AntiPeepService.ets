import { BusinessError } from '@kit.BasicServicesKit';
import { dlpAntiPeep } from '@kit.DeviceSecurityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpRequest, HttpResponse, JsonRecord } from './HttpTypes';
import { asBoolean, asRecord } from './JsonUtils';

const DOMAIN = 0x5441;
const TAG = 'AntiPeepService';

export type AntiPeepStateListener = (peeping: boolean) => void;

export class AntiPeepService {
  private enabled: boolean = false;
  private peeping: boolean = false;
  private subscribed: boolean = false;
  private listeners: AntiPeepStateListener[] = [];
  private callback = (status: dlpAntiPeep.DlpAntiPeepStatus): void => {
    this.updatePeeping(status === dlpAntiPeep.DlpAntiPeepStatus.HIDE);
  };

  subscribe(listener: AntiPeepStateListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
    listener(this.peeping);
  }

  unsubscribe(listener: AntiPeepStateListener): void {
    this.listeners = this.listeners.filter((candidate: AntiPeepStateListener): boolean => candidate !== listener);
  }

  statusResponse(): HttpResponse {
    return HttpResponse.json(this.statusJson(this.enabled ? '防窥保护已启用' : '防窥保护未启用'));
  }

  async updateSettings(request: HttpRequest): Promise<HttpResponse> {
    const body = asRecord(request.body as Object | undefined);
    const enabled = asBoolean(body['enabled']);
    if (!enabled) {
      this.disable();
      return HttpResponse.json(this.statusJson('防窥保护已关闭'));
    }
    return await this.enable();
  }

  refreshStatus(): void {
    if (!this.enabled || !this.subscribed) {
      return;
    }
    try {
      const status = dlpAntiPeep.getDlpAntiPeepInfo();
      this.updatePeeping(status === dlpAntiPeep.DlpAntiPeepStatus.HIDE);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Failed to refresh anti-peep status: %{public}s', JSON.stringify(error));
    }
  }

  private async enable(): Promise<HttpResponse> {
    if (!canIUse('SystemCapability.Security.DlpAntiPeep')) {
      this.disable();
      return this.failureResponse('当前设备不支持防窥保护能力。', 501, 801);
    }
    try {
      const switchOn = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      if (!switchOn) {
        this.disable();
        return this.failureResponse('系统防窥保护开关尚未开启，请先在系统设置中开启后再试。', 409, 0);
      }

      if (!this.subscribed) {
        dlpAntiPeep.on('dlpAntiPeep', this.callback);
        this.subscribed = true;
      }
      this.enabled = true;
      this.refreshStatus();
      return HttpResponse.json(this.statusJson('防窥保护已启用'));
    } catch (error) {
      this.disable();
      return this.businessErrorResponse(error as BusinessError);
    }
  }

  private disable(): void {
    if (this.subscribed) {
      try {
        dlpAntiPeep.off('dlpAntiPeep', this.callback);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'Failed to unsubscribe anti-peep status: %{public}s', JSON.stringify(error));
      }
    }
    this.subscribed = false;
    this.enabled = false;
    this.updatePeeping(false);
  }

  private updatePeeping(peeping: boolean): void {
    if (this.peeping === peeping) {
      return;
    }
    this.peeping = peeping;
    hilog.info(DOMAIN, TAG, 'Anti-peep status changed: %{public}s', peeping ? 'HIDE' : 'PASS');
    for (const listener of this.listeners) {
      try {
        listener(peeping);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'Anti-peep listener failed: %{public}s', JSON.stringify(error));
      }
    }
  }

  private statusJson(message: string): JsonRecord {
    const value: JsonRecord = {};
    value['enabled'] = this.enabled;
    value['peeping'] = this.peeping;
    value['message'] = message;
    return value;
  }

  private businessErrorResponse(error: BusinessError): HttpResponse {
    const code = error.code;
    if (code === 201) {
      return this.failureResponse('应用未获得防窥状态权限（错误码 201），请检查签名与权限配置。', 403, code);
    }
    if (code === 801) {
      return this.failureResponse('当前设备不支持防窥保护能力（错误码 801）。', 501, code);
    }
    if (code === 1020600001) {
      return this.failureResponse('系统防窥服务发生内部错误（错误码 1020600001），请稍后重试。', 500, code);
    }
    const detail = error.message.length > 0 ? `：${error.message}` : '';
    return this.failureResponse(`启用防窥保护失败${detail}`, 500, code);
  }

  private failureResponse(message: string, statusCode: number, code: number): HttpResponse {
    const value = this.statusJson(message);
    value['error'] = 'ANTI_PEEP_UNAVAILABLE';
    value['code'] = code;
    return HttpResponse.json(value, statusCode);
  }
}
