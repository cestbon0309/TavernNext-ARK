import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BackendService, BackendStatus } from '../backend/BackendService';
import { ShellThemeService } from '../backend/ShellThemeService';

const DEFAULT_SHELL_BACKGROUND = '#171717';
const BACK_EXIT_INTERVAL_MS = 2000;

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
  private lastBackPressTime: number = 0;
  private handlingBackPress: boolean = false;

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
          .onOverrideUrlLoading((request) => this.handleWebNavigation(request))
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

  private handleWebNavigation(request: WebResourceRequest): boolean {
    const targetUrl = request.getRequestUrl();
    if (!request.isMainFrame() || !this.shouldOpenExternally(targetUrl)) {
      return false;
    }

    this.openExternalUrl(targetUrl);
    return true;
  }

  private shouldOpenExternally(targetUrl: string): boolean {
    const normalized = targetUrl.trim().toLowerCase();
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      return false;
    }
    return !this.isLocalTavernUrl(normalized);
  }

  private isLocalTavernUrl(targetUrl: string): boolean {
    const match = targetUrl.match(/^https?:\/\/([^/?#:]+)(?::(\d+))?(?:[/?#]|$)/i);
    if (match === null) {
      return false;
    }

    const host = match[1].toLowerCase();
    const port = match[2] ?? (targetUrl.startsWith('https://') ? '443' : '80');
    return (host === '127.0.0.1' || host === 'localhost') && port === '8000';
  }

  private openExternalUrl(targetUrl: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(targetUrl, { appLinkingOnly: false }).catch((_err: Error) => {
      context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: targetUrl
      }).catch((_fallbackErr: Error) => {
      });
    });
  }

  onBackPress(): boolean {
    this.handleBackPress();
    return true;
  }

  private handleBackPress(): void {
    if (this.handlingBackPress) {
      return;
    }
    this.handlingBackPress = true;

    this.goBackInWeb().then((handled: boolean) => {
      this.handlingBackPress = false;
      if (handled) {
        this.lastBackPressTime = 0;
        return;
      }
      this.handleTopLevelBack();
    }).catch((_err: Error) => {
      this.handlingBackPress = false;
      this.handleTopLevelBack();
    });
  }

  private handleTopLevelBack(): void {
    const now = Date.now();
    if (now - this.lastBackPressTime <= BACK_EXIT_INTERVAL_MS) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.terminateSelf().catch((_err: Error) => {
      });
      return;
    }

    this.lastBackPressTime = now;
    try {
      this.getUIContext().getPromptAction().showToast({
        message: '\u518d\u6309\u4e00\u6b21\u8fd4\u56de\u9000\u51fa',
        duration: BACK_EXIT_INTERVAL_MS
      });
    } catch (_err) {
    }
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

  private async goBackInWeb(): Promise<boolean> {
    if (!this.running || !this.webReady) {
      return false;
    }

    try {
      const result = await this.controller.runJavaScript(`(() => {
        const state = window.__tavernNextBackBridge;
        if (state && typeof state.handleBack === 'function') {
          return state.handleBack();
        }
        if (history.length > 1) {
          history.back();
          return 'history';
        }
        return 'exit';
      })();`);
      const normalized = result.replace(/"/g, '');
      if (normalized === 'handled' || normalized === 'history') {
        return true;
      }
    } catch (_err) {
    }

    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (_err) {
    }
    return false;
  }

  private injectShellThemeProbe(): void {
    this.controller.runJavaScript(`(() => {
      if (window.__tavernNextShellThemeProbeInstalled) {
        window.__tavernNextShellThemeProbeReport && window.__tavernNextShellThemeProbeReport();
        window.__tavernNextBackBridgeInstall && window.__tavernNextBackBridgeInstall();
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
      window.__tavernNextExternalLinkBridgeInstall = () => {
        if (window.__tavernNextExternalLinkBridgeInstalled) {
          return;
        }
        window.__tavernNextExternalLinkBridgeInstalled = true;

        const isLocalUrl = (url) => {
          try {
            const parsed = new URL(url, location.href);
            const localHost = parsed.hostname === '127.0.0.1' || parsed.hostname === 'localhost';
            return localHost && parsed.port === '8000';
          } catch (_) {
            return false;
          }
        };

        document.addEventListener('click', (event) => {
          const target = event.target && event.target.closest && event.target.closest('a[href]');
          if (!target) {
            return;
          }
          const href = target.href || '';
          if (!/^https?:\/\//i.test(href) || isLocalUrl(href)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          location.href = href;
        }, true);
      };
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
      window.__tavernNextExternalLinkBridgeInstall();

      window.__tavernNextBackBridgeInstall = () => {
        if (window.__tavernNextBackBridge) {
          return;
        }

        const visible = (element) => {
          if (!element) {
            return false;
          }
          const style = getComputedStyle(element);
          if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
            return false;
          }
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        };

        const clickIfVisible = (selector) => {
          const elements = Array.from(document.querySelectorAll(selector)).reverse();
          const target = elements.find(visible);
          if (!target) {
            return false;
          }
          target.click();
          return true;
        };

        const closeOpenDrawer = () => {
          if (clickIfVisible('#rm_button_back_from_group, #rm_button_back')) {
            return true;
          }

          const drawers = Array.from(document.querySelectorAll('.drawer-content.openDrawer:not(.pinnedOpen)'))
            .filter(visible)
            .reverse();
          const drawer = drawers[0];
          if (!drawer) {
            return false;
          }

          const wrapper = drawer.closest('.drawer');
          const toggle = wrapper && wrapper.querySelector('.drawer-toggle');
          if (toggle) {
            toggle.click();
          } else {
            drawer.classList.remove('openDrawer');
            drawer.classList.add('closedDrawer');
            document.querySelectorAll('.openIcon:not(.drawerPinnedOpen)').forEach((icon) => {
              icon.classList.remove('openIcon');
              icon.classList.add('closedIcon');
            });
          }
          return true;
        };

        const closeLegacyPopup = () => {
          if (clickIfVisible('#dialogue_popup_cancel, #dialogue_popup_ok, #select_chat_cross, #character_cross')) {
            return true;
          }
          const shadowPopup = document.querySelector('#shadow_popup');
          if (visible(shadowPopup)) {
            shadowPopup.style.display = 'none';
            return true;
          }
          return false;
        };

        const closeHtmlDialog = () => {
          const dialogs = Array.from(document.querySelectorAll('dialog.popup[open]')).reverse();
          const dialog = dialogs.find(visible);
          if (!dialog) {
            return false;
          }
          const cancel = dialog.querySelector('.popup-button-cancel, .popup-button-close, [data-result="0"]');
          if (cancel instanceof HTMLElement && visible(cancel)) {
            cancel.click();
          } else {
            dialog.dispatchEvent(new Event('cancel', { bubbles: true, cancelable: true }));
          }
          return true;
        };

        const bridge = {
          depth: 0,
          ignoreNextPop: false,
          handleBack() {
            if (closeHtmlDialog() || closeLegacyPopup() || closeOpenDrawer()) {
              return 'handled';
            }
            if (bridge.depth > 0 || location.hash) {
              bridge.ignoreNextPop = true;
              history.back();
              return 'history';
            }
            return 'exit';
          }
        };

        const originalPushState = history.pushState.bind(history);
        const originalReplaceState = history.replaceState.bind(history);
        history.pushState = (...args) => {
          bridge.depth++;
          return originalPushState(...args);
        };
        history.replaceState = (...args) => originalReplaceState(...args);

        window.addEventListener('popstate', () => {
          if (bridge.ignoreNextPop) {
            bridge.ignoreNextPop = false;
          }
          bridge.depth = Math.max(0, bridge.depth - 1);
        });
        window.addEventListener('hashchange', () => {
          bridge.depth = Math.max(bridge.depth, location.hash ? 1 : 0);
        });

        bridge.depth = location.hash ? 1 : 0;
        window.__tavernNextBackBridge = bridge;
      };
      window.__tavernNextBackBridgeInstall();
      return 'installed';
    })();`).catch((_err: Error) => {
    });
  }
}
