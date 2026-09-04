import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ApplicationStateService } from '../backend/ApplicationStateService';
import { BackendService } from '../backend/BackendService';
import { DiagnosticLogService } from '../backend/DiagnosticLogService';
import { FileStore } from '../backend/FileStore';
import { joinPath } from '../backend/PathUtils';
import { ShareExportService } from '../backend/ShareExportService';
import { ShellThemeService } from '../backend/ShellThemeService';

const DOMAIN = 0x0000;
const DIAGNOSTIC_EXPORT_RETENTION_MS = 5 * 60 * 1000;

export default class EntryAbility extends UIAbility {
  private foldStatusCallback: ((status: display.FoldStatus) => void) | null = null;
  private diagnosticCapturePendingShare: boolean = false;
  private diagnosticShareInFlight: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    DiagnosticLogService.initialize(this.context.filesDir);
    const diagnosticShareExports = new ShareExportService(this.context, new FileStore(),
      joinPath(this.context.filesDir, 'exports'));
    diagnosticShareExports.discardExportFiles('diagnostics', /^tavernnext-diagnostics-\d+\.txt$/,
      Date.now() - DIAGNOSTIC_EXPORT_RETENTION_MS);
    const diagnostics = DiagnosticLogService.getInstance();
    if (diagnostics.isCapturing()) {
      DiagnosticLogService.setShareExportService(diagnosticShareExports);
      diagnostics.scheduleCaptureCompletion(() => {
        if (ApplicationStateService.getInstance().isBackground()) {
          diagnostics.prepareCaptureReport();
          this.diagnosticCapturePendingShare = true;
          return;
        }
        this.finishDiagnosticCapture();
      });
    }
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      DiagnosticLogService.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    const applicationState = ApplicationStateService.getInstance();
    applicationState.init(this.context.getApplicationContext());
    applicationState.markForeground();
    ShellThemeService.getInstance(this.context).refreshWindow();
    BackendService.getInstance(this.context).start();
  }

  onDestroy(): void {
    DiagnosticLogService.getInstance().suspendCapture();
    this.diagnosticCapturePendingShare = false;
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.applyShellTheme(windowStage);
    this.attachBackgroundPrivacy(windowStage);
    this.applyPreferredOrientation(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        DiagnosticLogService.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      ShellThemeService.getInstance(this.context).refreshWindow();
      DiagnosticLogService.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  private applyShellTheme(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      ShellThemeService.getInstance(this.context).attachWindow(mainWindow);
    } catch (err) {
      DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to apply shell theme. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private attachBackgroundPrivacy(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      BackendService.getInstance(this.context).getBackgroundPrivacy().attachWindow(mainWindow);
    } catch (err) {
      DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to attach background privacy. Cause: %{public}s', JSON.stringify(err));
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
            DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
          });
        return;
      }
      if (!foldable) {
        mainWindow.setPreferredOrientation(window.Orientation.PORTRAIT)
          .catch((err: Error) => {
            DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
          });
        return;
      }
      const applyFoldOrientation = (status: display.FoldStatus): void => {
        const orientation = status === display.FoldStatus.FOLD_STATUS_FOLDED
          ? window.Orientation.PORTRAIT
          : window.Orientation.AUTO_ROTATION_RESTRICTED;
        mainWindow.setPreferredOrientation(orientation).catch((err: Error) => {
          DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to set orientation. Cause: %{public}s', JSON.stringify(err));
        });
      };
      applyFoldOrientation(display.getFoldStatus());
      this.foldStatusCallback = applyFoldOrientation;
      display.on('foldStatusChange', this.foldStatusCallback);
    } catch (err) {
      DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to apply preferred orientation. Cause: %{public}s', JSON.stringify(err));
    }
  }


  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    const callback = this.foldStatusCallback;
    if (callback !== null) {
      try {
        display.off('foldStatusChange', callback);
      } catch (err) {
        DiagnosticLogService.warn(DOMAIN, 'testTag', 'Failed to unregister fold status listener. Cause: %{public}s', JSON.stringify(err));
      }
      this.foldStatusCallback = null;
    }
  }

  onForeground(): void {
    // Ability has brought to foreground
    ApplicationStateService.getInstance().markForeground();
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    if (this.diagnosticCapturePendingShare) {
      this.finishDiagnosticCapture();
    }
  }

  onBackground(): void {
    // Ability has back to background
    ApplicationStateService.getInstance().markBackground();
    DiagnosticLogService.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private finishDiagnosticCapture(): void {
    if (this.diagnosticShareInFlight) {
      return;
    }
    this.diagnosticCapturePendingShare = false;
    this.diagnosticShareInFlight = true;
    DiagnosticLogService.getInstance().finishCaptureAndShare().then((shared: boolean) => {
      if (!shared) {
        DiagnosticLogService.error(DOMAIN, 'testTag', 'Failed to share startup diagnostic capture');
      }
    }).catch((err: Error) => {
      DiagnosticLogService.error(DOMAIN, 'testTag',
        'Failed to finish startup diagnostic capture. Cause: %{public}s', JSON.stringify(err));
    }).finally(() => {
      this.diagnosticShareInFlight = false;
    });
  }
}
