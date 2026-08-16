import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettingsService, APP_SETTING_BACKGROUND_PRIVACY_ENABLED } from './AppSettingsService';
import { ApplicationStateService } from './ApplicationStateService';
import { JsonRecord } from './HttpTypes';

const DOMAIN = 0x5441;
const TAG = 'BackgroundPrivacy';

export class BackgroundPrivacyService {
  private enabled: boolean = true;
  private settings: AppSettingsService;
  private mainWindow: window.Window | null = null;
  private targetPrivacyMode: boolean | null = null;

  constructor(filesDir: string) {
    this.settings = AppSettingsService.getInstance(filesDir);
    this.enabled = this.settings.getBoolean(APP_SETTING_BACKGROUND_PRIVACY_ENABLED, true);
    ApplicationStateService.getInstance().subscribe((foreground: boolean): void => {
      this.setWindowPrivacyMode(this.enabled && !foreground);
    });
  }

  attachWindow(mainWindow: window.Window): void {
    this.mainWindow = mainWindow;
    this.targetPrivacyMode = null;
    this.applyCurrentState();
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  settingsJson(): JsonRecord {
    const value: JsonRecord = {};
    value['enabled'] = this.enabled;
    value['background'] = ApplicationStateService.getInstance().isBackground();
    return value;
  }

  updateEnabled(enabled: boolean): JsonRecord {
    this.enabled = enabled;
    this.settings.setBoolean(APP_SETTING_BACKGROUND_PRIVACY_ENABLED, enabled);
    this.applyCurrentState();
    return this.settingsJson();
  }

  private applyCurrentState(): void {
    this.setWindowPrivacyMode(this.enabled && ApplicationStateService.getInstance().isBackground());
  }

  private setWindowPrivacyMode(protect: boolean): void {
    if (this.mainWindow === null || this.targetPrivacyMode === protect) {
      return;
    }
    this.targetPrivacyMode = protect;
    this.mainWindow.setWindowPrivacyMode(protect).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Failed to set window privacy mode to %{public}s. Cause: %{public}s',
        protect ? 'true' : 'false', JSON.stringify(err));
      this.targetPrivacyMode = null;
    });
  }
}