import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ApplicationStateService } from '../backend/ApplicationStateService';
import { BackendService } from '../backend/BackendService';
import { ShellThemeService } from '../backend/ShellThemeService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private foldStatusCallback: ((status: display.FoldStatus) => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    const applicationState = ApplicationStateService.getInstance();
    applicationState.init(this.context.getApplicationContext());
    applicationState.markForeground();
    ShellThemeService.getInstance(this.context).refreshWindow();
    BackendService.getInstance(this.context).start();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.applyShellTheme(windowStage);
    this.attachBackgroundPrivacy(windowStage);
    this.applyPreferredOrientation(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      ShellThemeService.getInstance(this.context).refreshWindow();
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  private applyShellTheme(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      ShellThemeService.getInstance(this.context).attachWindow(mainWindow);
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to apply shell theme. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private attachBackgroundPrivacy(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      BackendService.getInstance(this.context).getBackgroundPrivacy().attachWindow(mainWindow);
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to attach background privacy. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private applyPreferredOrientation(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      const deviceType = deviceInfo.deviceType;
      const foldable = deviceType === 'phone' && display.isFoldable();
      if (deviceType === 'tablet' || deviceType === '2in1') {
        mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
          .catch((err: Error) => {
            hilog.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
          });
        return;
      }
      if (!foldable) {
        mainWindow.setPreferredOrientation(window.Orientation.PORTRAIT)
          .catch((err: Error) => {
            hilog.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
          });
        return;
      }
      const applyFoldOrientation = (status: display.FoldStatus): void => {
        const orientation = status === display.FoldStatus.FOLD_STATUS_FOLDED
          ? window.Orientation.PORTRAIT
          : window.Orientation.AUTO_ROTATION_RESTRICTED;
        mainWindow.setPreferredOrientation(orientation).catch((err: Error) => {
          hilog.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
        });
      };
      applyFoldOrientation(display.getFoldStatus());
      this.foldStatusCallback = applyFoldOrientation;
      display.on('foldStatusChange', this.foldStatusCallback);
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to apply preferred orientation. Cause: %{public}s', JSON.stringify(err));
    }
  }


  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    const callback = this.foldStatusCallback;
    if (callback !== null) {
      try {
        display.off('foldStatusChange', callback);
      } catch (err) {
        hilog.warn(DOMAIN, 'testTag', 'Failed to unregister fold status listener. Cause: %{public}s', JSON.stringify(err));
      }
      this.foldStatusCallback = null;
    }
  }

  onForeground(): void {
    // Ability has brought to foreground
    ApplicationStateService.getInstance().markForeground();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    ApplicationStateService.getInstance().markBackground();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
