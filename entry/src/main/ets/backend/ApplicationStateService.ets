import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x544156;
const TAG = 'ApplicationState';

export class ApplicationStateService {
  private static instance: ApplicationStateService = new ApplicationStateService();
  private foreground: boolean = true;
  private registered: boolean = false;
  private callback: ApplicationStateChangeCallback | null = null;

  private constructor() {
  }

  static getInstance(): ApplicationStateService {
    return ApplicationStateService.instance;
  }

  init(applicationContext: common.ApplicationContext): void {
    if (this.registered) {
      return;
    }
    try {
      this.callback = new TavernApplicationStateChangeCallback(this);
      applicationContext.on('applicationStateChange', this.callback);
      this.registered = true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to register application state callback: %{public}s', JSON.stringify(err));
    }
  }

  markForeground(): void {
    this.setForeground(true);
  }

  markBackground(): void {
    this.setForeground(false);
  }

  isBackground(): boolean {
    return !this.foreground;
  }

  private setForeground(value: boolean): void {
    if (this.foreground === value) {
      return;
    }
    this.foreground = value;
    hilog.info(DOMAIN, TAG, 'Application state changed: %{public}s', value ? 'foreground' : 'background');
  }
}

class TavernApplicationStateChangeCallback extends ApplicationStateChangeCallback {
  private service: ApplicationStateService;

  constructor(service: ApplicationStateService) {
    super();
    this.service = service;
  }

  onApplicationForeground(): void {
    this.service.markForeground();
  }

  onApplicationBackground(): void {
    this.service.markBackground();
  }
}
