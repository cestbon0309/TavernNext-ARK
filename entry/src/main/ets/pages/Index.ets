import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BackendService, BackendStatus } from '../backend/BackendService';
import { ShellThemeService } from '../backend/ShellThemeService';

const DEFAULT_SHELL_BACKGROUND = '#171717';

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State url: string = 'http://127.0.0.1:8000';
  @State pageError: string = '';
  @State message: string = 'Starting ArkTS backend...';
  @State shellBackground: string = DEFAULT_SHELL_BACKGROUND;
  @State webReady: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private webRevealToken: number = 0;

  aboutToAppear(): void {
    webview.WebviewController.setWebDebuggingAccess(true);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const theme = ShellThemeService.getInstance(context);
    this.applyShellBackground(theme.getBackgroundColor());
    theme.subscribe((color: string) => {
      this.applyShellBackground(color);
    });
    const service = BackendService.getInstance(context);
    service.start().then((status: BackendStatus) => {
      this.applyStatus(status);
    });
  }

  private applyStatus(status: BackendStatus): void {
    if (!this.running && status.running) {
      this.hideWebUntilReady();
    }
    this.running = status.running;
    this.url = status.url;
    this.message = status.message;
  }

  private applyShellBackground(color: string): void {
    this.shellBackground = color;
  }

  build() {
    Stack() {
      if (this.running) {
        Web({ src: this.url, controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .databaseAccess(true)
          .imageAccess(true)
          .onlineImageAccess(true)
          .mixedMode(MixedMode.All)
          .cacheMode(CacheMode.Online)
          .width('100%')
          .height('100%')
          .backgroundColor(this.shellBackground)
          .opacity(this.webReady ? 1 : 0)
          .onPageBegin(() => {
            this.pageError = '';
            this.hideWebUntilReady();
          })
          .onPageEnd(() => {
            this.injectShellThemeProbe();
            this.revealWebAfterFirstPaint();
          })
          .onErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.pageError = `WebView failed to load SillyTavern: ${event.error.getErrorInfo()}`;
              this.webReady = true;
            }
          })
          .onHttpErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.pageError = 'SillyTavern page returned an HTTP error.';
              this.webReady = true;
            }
          })
      } else {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(48)
            .height(48)
          Text(this.message)
            .fontSize(16)
            .fontColor('#D6D6D6')
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.shellBackground)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      if (this.pageError.length > 0) {
        Text(this.pageError)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#8C1D18')
          .padding(8)
          .borderRadius(6)
          .position({ x: 12, y: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.shellBackground)
  }

  private revealWebAfterFirstPaint(): void {
    const token = this.webRevealToken;
    setTimeout(() => {
      if (token === this.webRevealToken) {
        this.webReady = true;
      }
    }, 80);
  }

  private hideWebUntilReady(): void {
    this.webReady = false;
    this.webRevealToken++;
    const token = this.webRevealToken;
    setTimeout(() => {
      if (token === this.webRevealToken) {
        this.webReady = true;
      }
    }, 700);
  }

  private injectShellThemeProbe(): void {
    this.controller.runJavaScript(`(() => {
      if (window.__tavernNextShellThemeProbeInstalled) {
        window.__tavernNextShellThemeProbeReport && window.__tavernNextShellThemeProbeReport();
        return 'already-installed';
      }
      window.__tavernNextShellThemeProbeInstalled = true;

      const transparent = new Set(['', 'transparent', 'rgba(0, 0, 0, 0)']);
      const usable = (value) => value && !transparent.has(String(value).trim().toLowerCase());
      const resolveColor = () => {
        const style = getComputedStyle(document.documentElement);
        const themeColor = style.getPropertyValue('--SmartThemeBlurTintColor').trim();
        if (usable(themeColor)) {
          return themeColor;
        }
        const bodyColor = getComputedStyle(document.body).backgroundColor;
        if (usable(bodyColor)) {
          return bodyColor;
        }
        const htmlColor = getComputedStyle(document.documentElement).backgroundColor;
        return usable(htmlColor) ? htmlColor : 'rgb(23, 23, 23)';
      };

      let lastColor = '';
      let timer = 0;
      const postColor = (color) => {
        fetch('/api/ohos/shell-theme/background', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ color })
        }).catch(() => {});
      };
      const report = () => {
        const color = resolveColor();
        if (color === lastColor) {
          return;
        }
        lastColor = color;
        postColor(color);
      };
      const schedule = () => {
        clearTimeout(timer);
        timer = setTimeout(report, 80);
      };

      window.__tavernNextShellThemeProbeReport = report;
      new MutationObserver(schedule).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['style', 'class']
      });
      new MutationObserver(schedule).observe(document.body, {
        attributes: true,
        attributeFilter: ['style', 'class']
      });
      window.addEventListener('load', schedule);
      window.addEventListener('resize', schedule);
      document.addEventListener('visibilitychange', schedule);
      schedule();
      setInterval(report, 2000);
      return 'installed';
    })();`).catch((_err: Error) => {
    });
  }
}
