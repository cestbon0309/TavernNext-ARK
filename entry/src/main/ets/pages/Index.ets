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
        const intersectsViewport = (rect) => rect.right > 0 &&
          rect.bottom > 0 &&
          rect.left < window.innerWidth &&
          rect.top < window.innerHeight;
        const visible = (element) => {
          if (!element) {
            return false;
          }
          const style = getComputedStyle(element);
          if (style.display === 'none' || style.visibility === 'hidden') {
            return false;
          }
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && intersectsViewport(rect);
        };
        const hideElement = (element) => {
          if (!element) {
            return false;
          }
          try {
            if (window.jQuery) {
              window.jQuery(element).stop(true, true).hide();
            } else {
              element.style.display = 'none';
            }
          } catch (_) {
            element.style.display = 'none';
          }
          return true;
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
        const hideIfVisible = (selector) => {
          const elements = Array.from(document.querySelectorAll(selector)).reverse();
          const target = elements.find(visible);
          return hideElement(target);
        };
        const closeExtensionsMenu = () => {
          const menu = document.querySelector('#extensionsMenu');
          if (!visible(menu)) {
            return false;
          }
          hideElement(menu);
          const button = document.querySelector('#extensionsMenuButton');
          if (button instanceof HTMLElement) {
            button.blur();
          }
          return true;
        };
        const closeOptionsMenu = () => {
          if (closeExtensionsMenu()) {
            return true;
          }
          return hideIfVisible('.options-content');
        };
        const closeSelect2 = () => {
          const openSelect = Array.from(document.querySelectorAll('.select2-container--open, .select2-dropdown')).find(visible);
          if (!openSelect) {
            return false;
          }
          if (window.jQuery) {
            try {
              window.jQuery('select.select2-hidden-accessible').select2('close');
              return true;
            } catch (_) {
            }
          }
          document.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Escape',
            code: 'Escape',
            keyCode: 27,
            which: 27,
            bubbles: true,
            cancelable: true
          }));
          return true;
        };
        const closeFloatingPanel = () => {
          if (clickIfVisible('#logprobsViewerClose, #CFGClose, #ANClose')) {
            return true;
          }
          const panels = Array.from(document.querySelectorAll('#movingDivs > div, .draggable, .zoomed_avatar_container, .zoomed_avatar')).reverse();
          const panel = panels.find(visible);
          if (!panel) {
            return false;
          }
          const close = panel.querySelector('.floating_panel_close, .dragClose');
          if (close instanceof HTMLElement && visible(close)) {
            close.click();
          } else {
            panel.remove();
          }
          return true;
        };
        const toggleDrawerForContent = (drawer) => {
          const wrapper = drawer.closest('.drawer');
          const toggle = wrapper && wrapper.querySelector('.drawer-toggle');
          if (toggle instanceof HTMLElement && visible(toggle)) {
            toggle.click();
            return true;
          }
          document.querySelectorAll('.openIcon:not(.drawerPinnedOpen)').forEach((icon) => {
            icon.classList.remove('openIcon');
            icon.classList.add('closedIcon');
          });
          drawer.classList.remove('openDrawer');
          drawer.classList.add('closedDrawer');
          return true;
        };
        const closeOpenDrawer = () => {
          const drawers = Array.from(document.querySelectorAll('.drawer-content.openDrawer:not(.pinnedOpen)'))
            .filter(visible)
            .reverse();
          const drawer = drawers.find((item) => !item.matches('#left-nav-panel.pinnedOpen, #right-nav-panel.pinnedOpen')) || drawers[0];
          return drawer ? toggleDrawerForContent(drawer) : false;
        };
        const closeRightMenuSubview = () => clickIfVisible('#rm_button_back_from_group, #rm_button_back');
        const closeActiveChatToWelcome = () => {
          if (document.querySelector('#chat .welcomePanel')) {
            return false;
          }
          let context = null;
          try {
            context = window.SillyTavern && typeof window.SillyTavern.getContext === 'function'
              ? window.SillyTavern.getContext()
              : null;
          } catch (_) {
          }
          const hasValue = (value) => value !== undefined && value !== null && value !== '';
          const hasTemporaryChat = context &&
            context.name2 === 'Assistant' &&
            Array.isArray(context.chat) &&
            context.chat.length > 0;
          const hasActiveChat = context &&
            (hasValue(context.chatId) ||
              hasValue(context.characterId) ||
              hasValue(context.groupId) ||
              hasTemporaryChat);
          if (!hasActiveChat) {
            return false;
          }
          const closeButtons = Array.from(document.querySelectorAll('#options [id="option_close_chat"], [id="option_close_chat"]'));
          const closeButton = closeButtons.find((button) => button instanceof HTMLElement && !button.classList.contains('displayNone')) ||
            closeButtons.find((button) => button instanceof HTMLElement);
          if (!(closeButton instanceof HTMLElement)) {
            return false;
          }
          closeButton.click();
          return true;
        };
        const closeLegacyPopup = () => {
          if (clickIfVisible('#dialogue_popup_cancel, #dialogue_popup_ok, #dialogue_del_mes_cancel, #select_chat_cross, #character_cross, #bulk_tag_popup_cancel')) {
            return true;
          }
          return hideIfVisible('#shadow_popup, #shadow_select_chat_popup, #bulk_tag_shadow_popup, #character_popup, #select_chat_popup');
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
        if (closeSelect2() ||
          closeHtmlDialog() ||
          closeLegacyPopup() ||
          closeOptionsMenu() ||
          closeFloatingPanel() ||
          closeOpenDrawer() ||
          closeActiveChatToWelcome() ||
          closeRightMenuSubview()) {
          return 'handled';
        }
        return 'idle';
      })();`);
      const normalized = (result ?? '').replace(/"/g, '');
      if (normalized.startsWith('handled')) {
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

    try {
      const result = await this.controller.runJavaScript(`(() => {
        const state = window.__tavernNextBackBridge;
        if (state && typeof state.navigateBack === 'function') {
          return state.navigateBack();
        }
        return 'idle';
      })();`);
      const normalized = (result ?? '').replace(/"/g, '');
      if (normalized === 'history') {
        return true;
      }
    } catch (_err) {
    }
    return false;
  }

  private injectShellThemeProbe(): void {
    this.controller.runJavaScript(`(() => {
      const shellThemeProbeAlreadyInstalled = !!window.__tavernNextShellThemeProbeInstalled;
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
      if (!shellThemeProbeAlreadyInstalled) {
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
        setInterval(report, 2000);
      }
      schedule();
      window.__tavernNextExternalLinkBridgeInstall();

      window.__tavernNextBackBridgeInstall = () => {
        if (window.__tavernNextBackBridge && window.__tavernNextBackBridge.version === 2) {
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
          const intersectsViewport = rect.right > 0 &&
            rect.bottom > 0 &&
            rect.left < window.innerWidth &&
            rect.top < window.innerHeight;
          return rect.width > 0 && rect.height > 0 && intersectsViewport;
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

        const pressEscape = () => {
          const event = new KeyboardEvent('keydown', {
            key: 'Escape',
            code: 'Escape',
            keyCode: 27,
            which: 27,
            bubbles: true,
            cancelable: true
          });
          document.dispatchEvent(event);
          return event.defaultPrevented;
        };

        const hideIfVisible = (selector) => {
          const elements = Array.from(document.querySelectorAll(selector)).reverse();
          const target = elements.find(visible);
          if (!target) {
            return false;
          }
          target.style.display = 'none';
          return true;
        };

        const closeSelect2 = () => {
          const openSelect = Array.from(document.querySelectorAll('.select2-container--open, .select2-dropdown')).find(visible);
          if (!openSelect) {
            return false;
          }
          if (window.jQuery) {
            try {
              window.jQuery('select.select2-hidden-accessible').select2('close');
              return true;
            } catch (_) {
            }
          }
          return pressEscape();
        };

        const closeOptionsMenu = () => {
          if (hideIfVisible('#extensionsMenu.options-content, .options-content')) {
            return true;
          }
          return false;
        };

        const closeFloatingPanel = () => {
          if (clickIfVisible('#logprobsViewerClose, #CFGClose, #ANClose')) {
            return true;
          }
          const panels = Array.from(document.querySelectorAll('#movingDivs > div, .draggable, .zoomed_avatar_container, .zoomed_avatar')).reverse();
          const panel = panels.find(visible);
          if (!panel) {
            return false;
          }
          const close = panel.querySelector('.floating_panel_close, .dragClose');
          if (close instanceof HTMLElement && visible(close)) {
            close.click();
          } else {
            panel.remove();
          }
          return true;
        };

        const toggleDrawerForContent = (drawer) => {
          const wrapper = drawer.closest('.drawer');
          const toggle = wrapper && wrapper.querySelector('.drawer-toggle');
          if (toggle instanceof HTMLElement && visible(toggle)) {
            toggle.click();
            return true;
          }

          const icons = Array.from(document.querySelectorAll('.openIcon:not(.drawerPinnedOpen)'));
          icons.forEach((icon) => {
            icon.classList.remove('openIcon');
            icon.classList.add('closedIcon');
          });
          drawer.classList.remove('openDrawer');
          drawer.classList.add('closedDrawer');
          return true;
        };

        const closeOpenDrawer = () => {
          if (clickIfVisible('#rm_button_back_from_group, #rm_button_back')) {
            return true;
          }

          const drawers = Array.from(document.querySelectorAll('.drawer-content.openDrawer:not(.pinnedOpen), .drawer-content:not(.closedDrawer)'))
            .filter(visible)
            .reverse();
          const drawer = drawers.find((item) => !item.matches('#left-nav-panel.pinnedOpen, #right-nav-panel.pinnedOpen')) || drawers[0];
          if (!drawer) {
            return false;
          }

          return toggleDrawerForContent(drawer);
        };

        const closeLegacyPopup = () => {
          if (clickIfVisible('#dialogue_popup_cancel, #dialogue_popup_ok, #dialogue_del_mes_cancel, #select_chat_cross, #character_cross, #bulk_tag_popup_cancel')) {
            return true;
          }
          if (hideIfVisible('#shadow_popup, #shadow_select_chat_popup, #bulk_tag_shadow_popup, #character_popup, #select_chat_popup')) {
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
          version: 2,
          historyDepth: 0,
          initialHref: location.href,
          closeTopmostUi() {
            if (closeSelect2() ||
              closeHtmlDialog() ||
              closeLegacyPopup() ||
              closeOptionsMenu() ||
              closeFloatingPanel() ||
              closeOpenDrawer()) {
              return 'handled';
            }
            return 'idle';
          },
          navigateBack() {
            if (bridge.historyDepth > 0 || (location.href !== bridge.initialHref && history.length > 1)) {
              bridge.historyDepth = Math.max(0, bridge.historyDepth - 1);
              history.back();
              return 'history';
            }
            return 'idle';
          }
        };

        if (!window.__tavernNextBackBridgeHistoryPatched) {
          window.__tavernNextBackBridgeHistoryPatched = true;
          const originalPushState = history.pushState.bind(history);
          const originalReplaceState = history.replaceState.bind(history);
          history.pushState = (...args) => {
            const before = location.href;
            const result = originalPushState(...args);
            if (location.href !== before) {
              const state = window.__tavernNextBackBridge;
              if (state) {
                state.historyDepth = Math.max(0, state.historyDepth || 0) + 1;
              }
            }
            return result;
          };
          history.replaceState = (...args) => originalReplaceState(...args);
          window.addEventListener('popstate', () => {
            const state = window.__tavernNextBackBridge;
            if (state) {
              state.historyDepth = Math.max(0, state.historyDepth || 0);
            }
          });
          window.addEventListener('hashchange', () => {
            const state = window.__tavernNextBackBridge;
            if (!state) {
              return;
            }
            if (location.href === state.initialHref) {
              state.historyDepth = 0;
            } else {
              state.historyDepth = Math.max(1, state.historyDepth || 0);
            }
          });
        }
        window.__tavernNextBackBridge = bridge;
      };
      window.__tavernNextBackBridgeInstall();
      return shellThemeProbeAlreadyInstalled ? 'already-installed' : 'installed';
    })();`).catch((_err: Error) => {
    });
  }
}
