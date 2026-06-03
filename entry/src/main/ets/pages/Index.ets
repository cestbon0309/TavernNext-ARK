import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { ApplicationStateService } from '../backend/ApplicationStateService';
import { BackendService, BackendStatus } from '../backend/BackendService';
import { ChatBrowserItem } from '../backend/ChatBrowserService';
import { DataRestoreProgressService, DataRestoreProgressState } from '../backend/DataRestoreProgressService';
import { ShellThemeService } from '../backend/ShellThemeService';

const DEFAULT_SHELL_BACKGROUND = '#171717';
const BACK_EXIT_INTERVAL_MS = 2000;
const CHAT_BROWSER_DELETE_ANIMATION_MS = 220;
const CHAT_BROWSER_THEME_ANIMATION_MS = 220;
const CHAT_BROWSER_ROW_HEIGHT = 90;
const CHAT_BROWSER_DELETE_ACTION_WIDTH = 80;

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State url: string = 'http://127.0.0.1:8000';
  @State pageError: string = '';
  @State message: string = 'Starting ArkTS backend...';
  @State shellBackground: string = DEFAULT_SHELL_BACKGROUND;
  @State webReady: boolean = false;
  @State chatBrowserOpen: boolean = false;
  @State chatBrowserOpacity: number = 0;
  @State chatBrowserItems: ChatBrowserItem[] = [];
  @State chatBrowserQuery: string = '';
  @State chatBrowserMessage: string = '';
  @State chatBrowserDarkMode: boolean = false;
  @State chatBrowserRefreshing: boolean = false;
  @State chatBrowserDeletingIds: string[] = [];
  @State restoreProgressActive: boolean = false;
  @State restoreProgressTitle: string = '';
  @State restoreProgressMessage: string = '';
  @State restoreProgressDetail: string = '';
  private lastRestoreGitRepairFailureKey: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private webRevealToken: number = 0;
  private chatBrowserAnimationToken: number = 0;
  private lastBackPressTime: number = 0;
  private handlingBackPress: boolean = false;
  private backendService: BackendService | null = null;
  private persistenceFlushInFlight: boolean = false;

  aboutToAppear(): void {
    webview.WebviewController.setWebDebuggingAccess(true);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const theme = ShellThemeService.getInstance(context);
    this.applyShellBackground(theme.getBackgroundColor());
    theme.subscribe((color: string) => {
      this.applyShellBackground(color);
    });
    const service = BackendService.getInstance(context);
    this.backendService = service;
    ApplicationStateService.getInstance().subscribe((foreground: boolean) => {
      if (!foreground) {
        this.flushWebPersistentState('application-background');
      }
    });
    service.getChatBrowser().subscribeOpen(() => {
      this.openChatBrowser();
    });
    DataRestoreProgressService.getInstance().subscribe((state: DataRestoreProgressState) => {
      this.applyRestoreProgress(state);
    });
    service.start().then((status: BackendStatus) => {
      this.applyStatus(status);
    });
  }

  aboutToDisappear(): void {
    this.flushWebPersistentState('page-disappear');
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

  private applyRestoreProgress(state: DataRestoreProgressState): void {
    this.restoreProgressActive = state.active;
    this.restoreProgressTitle = state.title;
    this.restoreProgressMessage = state.message;
    this.restoreProgressDetail = state.detail;
    if (!state.active && state.failedExtensionGitRepairs.length > 0) {
      this.showExtensionGitRepairFailureDialog(state.failedExtensionGitRepairs);
    }
  }

  private showExtensionGitRepairFailureDialog(failedExtensions: string[]): void {
    const unique = failedExtensions.filter((name: string, index: number, names: string[]): boolean => {
      return name.length > 0 && names.indexOf(name) === index;
    });
    if (unique.length === 0) {
      return;
    }
    const key = unique.join('\n');
    if (key === this.lastRestoreGitRepairFailureKey) {
      return;
    }
    this.lastRestoreGitRepairFailureKey = key;
    AlertDialog.show({
      title: '插件重新安装失败',
      message: `以下插件未能通过原始仓库地址重新安装：\n\n${unique.map((name: string): string => `- ${name}`).join('\n')}\n\n这应该不会影响你继续使用导入包里的插件文件，但插件内更新可能需要稍后手动重新安装。`,
      autoCancel: true,
      primaryButton: {
        value: '知道了',
        action: () => {
        }
      }
    });
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

      if (this.chatBrowserOpen) {
        this.chatBrowserView()
      }

      if (this.restoreProgressActive) {
        this.restoreProgressOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.shellBackground)
  }

  @Builder
  private restoreProgressOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Progress({ value: 0, total: 100, type: ProgressType.Ring })
          .width(72)
          .height(72)
          .color('rgba(0,85,255,1.00)')
          .style({
            strokeWidth: 6,
            status: ProgressStatus.LOADING
          })

        Text(this.restoreProgressTitle.length > 0 ? this.restoreProgressTitle : '正在导入数据')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F6F7F9')
          .textAlign(TextAlign.Center)
          .width('100%')

        Text(this.restoreProgressMessage.length > 0 ? this.restoreProgressMessage : '请稍候...')
          .fontSize(14)
          .fontColor('#D9DEE7')
          .textAlign(TextAlign.Center)
          .width('100%')

        if (this.restoreProgressDetail.length > 0) {
          Text(this.restoreProgressDetail)
            .fontSize(12)
            .fontColor('#AEB7C6')
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('78%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 22, right: 22, top: 28, bottom: 28 })
      .backgroundColor('rgba(26,28,32,0.94)')
      .borderRadius(10)
      .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.48)')
  }

  @Builder
  private chatBrowserView() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Column({ space: 12 }) {
          Row() {
            Text('全部聊天')
              .fontSize(28)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.chatBrowserPrimaryTextColor())
              .lineHeight(42)
              .letterSpacing(-0.7)

            Blank()

            Button({ stateEffect: true }) {
              Stack() {
                Image($r('app.media.figma_chat_top_button'))
                  .width(20)
                  .height(20)
                  .fillColor(this.chatBrowserPrimaryTextColor())
              }
              .width('100%')
              .height('100%')
            }
            .width(36)
            .height(36)
            .padding(0)
            .borderRadius(18)
            .backgroundColor(this.chatBrowserChromeColor())
            .onClick(() => {
              this.closeChatBrowser();
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 8 }) {
            Stack({ alignContent: Alignment.TopStart }) {
              TextInput({ placeholder: '搜索聊天记录', text: this.chatBrowserQuery })
                .width('100%')
                .height(46)
                .fontSize(15)
                .placeholderColor(this.chatBrowserPlaceholderColor())
                .fontColor(this.chatBrowserPrimaryTextColor())
                .backgroundColor(this.chatBrowserInputColor())
                .borderRadius(14)
                .padding({ left: 44, right: 16 })
                .onChange((value: string) => {
                  this.chatBrowserQuery = value;
                })

              Image($r('app.media.figma_chat_search'))
                .width(18)
                .height(18)
                .fillColor(this.chatBrowserIconColor())
                .position({ x: 16, y: 14 })
            }
            .layoutWeight(1)
            .height(46)

            Button({ stateEffect: true }) {
              Stack() {
                Image($r('app.media.ic_public_refresh'))
                  .width(20)
                  .height(20)
                  .fillColor(this.chatBrowserIconColor())
              }
              .width('100%')
              .height('100%')
            }
            .width(46)
            .height(46)
            .padding(0)
            .borderRadius(14)
            .backgroundColor(this.chatBrowserInputColor())
            .opacity(this.chatBrowserRefreshing ? 0.5 : 1)
            .enabled(!this.chatBrowserRefreshing)
            .onClick(() => {
              this.manualRefreshChatBrowserItems();
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })
        .backgroundColor(this.chatBrowserHeaderColor())
        .border({ width: { bottom: 1 }, color: this.chatBrowserHeaderBorderColor() })
        .animation({ duration: CHAT_BROWSER_THEME_ANIMATION_MS, curve: Curve.EaseInOut })

        Column({ space: 12 }) {

          if (this.chatBrowserMessage.length > 0) {
            Text(this.chatBrowserMessage)
              .fontSize(12)
              .fontColor(this.chatBrowserWarningColor())
              .width('100%')
              .padding({ left: 20, right: 20 })
          }

          if (this.chatBrowserRefreshing) {
            Column({ space: 12 }) {
              Progress({ value: 0, total: 100, type: ProgressType.Ring })
                .width(72)
                .height(72)
                .color('rgba(0,85,255,1.00)')
                .style({
                  strokeWidth: 6,
                  status: ProgressStatus.LOADING
                })
              Text('正在刷新聊天缓存...')
                .fontSize(14)
                .fontColor(this.chatBrowserSecondaryTextColor())
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .padding({ left: 20, right: 20 })
          } else if (this.filteredChatBrowserItems().length === 0) {
            Column({ space: 8 }) {
              Text('没有找到聊天')
                .fontSize(16)
                .fontColor(this.chatBrowserPrimaryTextColor())
              Text('换个关键词试试，或先创建聊天。')
                .fontSize(12)
                .fontColor(this.chatBrowserSecondaryTextColor())
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ left: 20, right: 20 })
          } else {
            List({ space: 12 }) {
              ForEach(this.filteredChatBrowserItems(), (item: ChatBrowserItem) => {
                ListItem() {
                  this.chatBrowserRow(item)
                }
                .padding({ left: 20, right: 20 })
                .swipeAction({
                  end: {
                    builder: () => {
                      this.chatBrowserDeleteAction(item)
                    },
                    actionAreaDistance: CHAT_BROWSER_DELETE_ACTION_WIDTH
                  },
                  edgeEffect: SwipeEdgeEffect.Spring
                })
              }, (item: ChatBrowserItem) => item.id)
            }
            .width('100%')
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 16, bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.chatBrowserBackgroundColor())
      .animation({ duration: CHAT_BROWSER_THEME_ANIMATION_MS, curve: Curve.EaseInOut })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.chatBrowserBackgroundColor())
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .opacity(this.chatBrowserOpacity)
    .animation({ duration: CHAT_BROWSER_THEME_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private chatBrowserRow(item: ChatBrowserItem) {
    Row({ space: 14 }) {
      if (this.chatBrowserHasCover(item)) {
        Image(this.chatBrowserCoverUrl(item))
          .width(56)
          .height(56)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.chatBrowserCoverBackgroundColor())
          .borderRadius(28)
          .border({ width: 2, color: this.chatBrowserAvatarBorderColor() })
      } else {
        Text(this.chatBrowserBadgeText(item))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width(56)
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor(item.openable ? this.chatBrowserBadgeColor() : this.chatBrowserDisabledBadgeColor())
          .borderRadius(28)
          .border({ width: 2, color: this.chatBrowserAvatarBorderColor() })
      }

      Column({ space: 6 }) {
        Row() {
          Text(this.chatBrowserDisplayTitle(item))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.chatBrowserPrimaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(this.formatChatBrowserRelativeTime(item))
            .fontSize(13)
            .fontColor(this.chatBrowserSecondaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 16 }) {
          this.chatBrowserMetric($r('app.media.figma_chat_metric'), `${item.chatItems} 条`)
          this.chatBrowserMetric($r('app.media.figma_chat_storage'), item.fileSize)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height(this.isChatBrowserItemDeleting(item) ? 0 : CHAT_BROWSER_ROW_HEIGHT)
    .padding(this.isChatBrowserItemDeleting(item) ? 0 : 16)
    .backgroundColor(this.chatBrowserCardColor())
    .borderRadius(16)
    .border({ width: 1, color: this.chatBrowserBorderColor() })
    .shadow({ radius: 8, color: this.chatBrowserCardShadowColor(), offsetX: 0, offsetY: 2 })
    .opacity(this.isChatBrowserItemDeleting(item) ? 0 : 1)
    .scale({ x: this.isChatBrowserItemDeleting(item) ? 0.96 : 1, y: this.isChatBrowserItemDeleting(item) ? 0.96 : 1 })
    .clip(true)
    .enabled(item.openable && !this.isChatBrowserItemDeleting(item))
    .onClick(() => {
      this.openChatBrowserItem(item);
    })
    .animation({ duration: CHAT_BROWSER_DELETE_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private chatBrowserMetric(icon: Resource, text: string) {
    Row({ space: 6 }) {
      Image(icon)
        .width(15)
        .height(15)
        .fillColor(this.chatBrowserMetricColor())
      Text(text)
        .fontSize(13)
        .fontColor(this.chatBrowserMetricColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private chatBrowserDeleteAction(item: ChatBrowserItem) {
    Button({ stateEffect: true }) {
      Text('删除')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
    }
    .width(CHAT_BROWSER_DELETE_ACTION_WIDTH)
    .height(CHAT_BROWSER_ROW_HEIGHT)
    .padding(0)
    .borderRadius(16)
    .backgroundColor(this.chatBrowserDeleteButtonColor())
    .enabled(!this.isChatBrowserItemDeleting(item))
    .opacity(this.isChatBrowserItemDeleting(item) ? 0.45 : 1)
    .onClick(() => {
      this.confirmDeleteChatBrowserItem(item);
    })
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
    if (this.chatBrowserOpen) {
      this.closeChatBrowser();
      return true;
    }
    this.handleBackPress();
    return true;
  }

  private openChatBrowser(): void {
    const token = ++this.chatBrowserAnimationToken;
    if (!this.chatBrowserOpen) {
      this.chatBrowserOpacity = 0;
      this.chatBrowserOpen = true;
    }
    this.chatBrowserQuery = '';
    this.chatBrowserMessage = '';
    this.refreshChatBrowserItems(false);
    setTimeout(() => {
      if (this.chatBrowserAnimationToken === token && this.chatBrowserOpen) {
        this.chatBrowserOpacity = 1;
      }
    }, 16);
  }

  private closeChatBrowser(): void {
    if (!this.chatBrowserOpen) {
      return;
    }
    const token = ++this.chatBrowserAnimationToken;
    this.chatBrowserOpacity = 0;
    this.chatBrowserMessage = '';
    this.chatBrowserDeletingIds = [];
    setTimeout(() => {
      if (this.chatBrowserAnimationToken === token && this.chatBrowserOpacity === 0) {
        this.chatBrowserOpen = false;
      }
    }, CHAT_BROWSER_THEME_ANIMATION_MS);
  }

  private refreshChatBrowserItems(forceRefresh: boolean = false): void {
    if (this.backendService === null) {
      this.chatBrowserItems = [];
      this.chatBrowserMessage = '后端还没有准备好。';
      return;
    }
    if (forceRefresh) {
      this.chatBrowserRefreshing = true;
      this.chatBrowserMessage = '正在刷新聊天缓存...';
    }
    try {
      this.chatBrowserItems = forceRefresh
        ? this.backendService.getChatBrowser().refreshCache()
        : this.backendService.getChatBrowser().cachedList();
      this.chatBrowserMessage = forceRefresh ? '聊天缓存已刷新。' : '';
      this.chatBrowserDeletingIds = [];
    } finally {
      this.chatBrowserRefreshing = false;
    }
  }

  private manualRefreshChatBrowserItems(): void {
    if (this.backendService === null) {
      this.chatBrowserItems = [];
      this.chatBrowserMessage = '后端还没有准备好。';
      return;
    }
    this.chatBrowserItems = [];
    this.chatBrowserRefreshing = true;
    this.chatBrowserMessage = '';
    setTimeout(() => {
      try {
        this.chatBrowserItems = this.backendService?.getChatBrowser().refreshCache() ?? [];
        this.chatBrowserMessage = '聊天缓存已刷新。';
        this.chatBrowserDeletingIds = [];
      } finally {
        this.chatBrowserRefreshing = false;
      }
    }, 80);
  }

  private filteredChatBrowserItems(): ChatBrowserItem[] {
    const query = this.chatBrowserQuery.trim().toLowerCase();
    if (query.length === 0) {
      return this.chatBrowserItems;
    }
    return this.chatBrowserItems.filter((item: ChatBrowserItem): boolean => {
      const haystack = `${item.title} ${item.subtitle} ${item.chatName} ${item.preview} ${item.fileName}`.toLowerCase();
      return haystack.includes(query);
    });
  }

  private chatBrowserHasCover(item: ChatBrowserItem): boolean {
    return item.kind === 'character' && item.avatar.length > 0;
  }

  private chatBrowserCoverUrl(item: ChatBrowserItem): string {
    return `http://127.0.0.1:8000/characters/${encodeURIComponent(item.avatar)}`;
  }

  private isChatBrowserItemDeleting(item: ChatBrowserItem): boolean {
    return this.chatBrowserDeletingIds.includes(item.id);
  }

  private beginChatBrowserDeleteAnimation(item: ChatBrowserItem): void {
    if (this.isChatBrowserItemDeleting(item)) {
      return;
    }
    this.chatBrowserDeletingIds = [...this.chatBrowserDeletingIds, item.id];
  }

  private finishChatBrowserDeleteAnimation(item: ChatBrowserItem): void {
    if (this.backendService !== null) {
      this.chatBrowserItems = this.backendService.getChatBrowser().removeCachedItem(item);
    } else {
      this.chatBrowserItems = this.chatBrowserItems.filter((candidate: ChatBrowserItem): boolean => {
        return candidate.id !== item.id;
      });
    }
    this.chatBrowserDeletingIds = this.chatBrowserDeletingIds.filter((id: string): boolean => id !== item.id);
    this.chatBrowserMessage = '';
  }

  private animateChatBrowserItemRemoval(item: ChatBrowserItem): void {
    this.beginChatBrowserDeleteAnimation(item);
    setTimeout(() => {
      this.finishChatBrowserDeleteAnimation(item);
    }, CHAT_BROWSER_DELETE_ANIMATION_MS);
  }

  private chatBrowserBadgeText(item: ChatBrowserItem): string {
    if (item.kind === 'group' || item.kind === 'orphan_group') {
      return '群';
    }
    if (item.kind === 'character' || item.kind === 'orphan_character') {
      return '角';
    }
    return '文';
  }

  private chatBrowserBackgroundColor(): string {
    return this.chatBrowserDarkMode ? '#15151C' : '#F5F7FA';
  }

  private chatBrowserHeaderColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(20,20,28,0.48)' : 'rgba(255,255,255,0.20)';
  }

  private chatBrowserHeaderBorderColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.03)';
  }

  private chatBrowserCardColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(28,28,38,0.42)' : 'rgba(255,255,255,0.25)';
  }

  private chatBrowserInputColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(30,30,42,0.70)' : 'rgba(243,243,245,0.80)';
  }

  private chatBrowserChromeColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(236,238,242,0.60)';
  }

  private chatBrowserBorderColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)';
  }

  private chatBrowserPrimaryTextColor(): string {
    return this.chatBrowserDarkMode ? '#F7F7FA' : '#0A0A0A';
  }

  private chatBrowserSecondaryTextColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(228,228,236,0.70)' : 'rgba(113,113,130,0.70)';
  }

  private chatBrowserMetricColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(228,228,236,0.78)' : 'rgba(113,113,130,0.80)';
  }

  private chatBrowserIconColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(228,228,236,0.68)' : 'rgba(113,113,130,0.60)';
  }

  private chatBrowserPlaceholderColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(228,228,236,0.48)' : 'rgba(113,113,130,0.50)';
  }

  private chatBrowserWarningColor(): string {
    return this.chatBrowserDarkMode ? '#F2D675' : '#8A5E00';
  }

  private chatBrowserBadgeColor(): string {
    return this.chatBrowserDarkMode ? '#3B82F6' : '#4A90E2';
  }

  private chatBrowserDisabledBadgeColor(): string {
    return this.chatBrowserDarkMode ? '#8B5CF6' : '#A855F7';
  }

  private chatBrowserCoverBackgroundColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(255,255,255,0.08)' : '#E4E7EB';
  }

  private chatBrowserAvatarBorderColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(147,197,253,0.22)' : 'rgba(74,144,226,0.20)';
  }

  private chatBrowserDeleteButtonColor(): string {
    return '#FF4757';
  }

  private chatBrowserCardShadowColor(): string {
    return this.chatBrowserDarkMode ? 'rgba(0,0,0,0.20)' : 'rgba(0,0,0,0.10)';
  }

  private chatBrowserDisplayTitle(item: ChatBrowserItem): string {
    if (item.title.length === 0) {
      return item.chatName;
    }
    if (item.chatName.length === 0 || item.chatName === item.title) {
      return item.title;
    }
    return `${item.title} - ${item.chatName}`;
  }

  private chatBrowserTimestampMs(item: ChatBrowserItem): number {
    const parsed = Date.parse(item.lastTimestamp);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
    return Math.round(item.mtimeMs);
  }

  private formatChatBrowserRelativeTime(item: ChatBrowserItem): string {
    const timestamp = this.chatBrowserTimestampMs(item);
    const now = Date.now();
    const diffMs = Math.max(0, now - timestamp);
    const minuteMs = 60 * 1000;
    const hourMs = 60 * minuteMs;
    const dayMs = 24 * hourMs;
    if (diffMs < minuteMs) {
      return '刚刚';
    }
    if (diffMs < hourMs) {
      return `${Math.floor(diffMs / minuteMs)}分钟前`;
    }
    if (diffMs < dayMs) {
      return `${Math.floor(diffMs / hourMs)}小时前`;
    }
    if (diffMs < 2 * dayMs) {
      return '昨天';
    }
    if (diffMs < 7 * dayMs) {
      return `${Math.floor(diffMs / dayMs)}天前`;
    }
    if (diffMs < 30 * dayMs) {
      return `${Math.floor(diffMs / (7 * dayMs))}周前`;
    }
    return new Date(timestamp).toLocaleDateString();
  }

  private openChatBrowserItem(item: ChatBrowserItem): void {
    if (!item.openable) {
      this.showToast('这个聊天没有关联角色或群组，无法直接打开。');
      return;
    }

    const payload = JSON.stringify({
      avatar: item.avatar,
      group: item.group,
      file: item.chatName,
    });
    this.closeChatBrowser();
    this.controller.runJavaScript(`(async () => {
      if (typeof window.__tavernNextOpenChat !== 'function') {
        return 'missing';
      }
      return await window.__tavernNextOpenChat(${payload}) ? 'opened' : 'failed';
    })();`).then((result: string) => {
      const normalized = (result ?? '').replace(/"/g, '');
      if (normalized === 'missing' || normalized === 'failed' || normalized === 'false') {
        this.showToast('打开聊天失败。');
      }
    }).catch((_err: Error) => {
      this.showToast('打开聊天失败。');
    });
  }

  private confirmDeleteChatBrowserItem(item: ChatBrowserItem): void {
    AlertDialog.show({
      title: '删除聊天',
      message: `确定删除 ${item.title} - ${item.chatName} 吗？这个操作无法撤销。`,
      autoCancel: true,
      primaryButton: {
        value: '删除',
        action: () => {
          this.deleteChatBrowserItem(item);
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private deleteChatBrowserItem(item: ChatBrowserItem): void {
    if (item.openable) {
      this.deleteOpenableChatBrowserItem(item);
      return;
    }

    if (this.backendService === null) {
      this.showToast('后端还没有准备好。');
      return;
    }
    const deleted = this.backendService.getChatBrowser().deleteItem(item);
    if (!deleted) {
      this.showToast('删除失败，文件可能已经不存在。');
      this.refreshChatBrowserItems(true);
      return;
    }
    this.animateChatBrowserItemRemoval(item);
    this.showToast('聊天已删除。');
    this.controller.runJavaScript(`(() => {
      if (typeof window.__tavernNextRefreshWelcome === 'function') {
        window.__tavernNextRefreshWelcome();
        return 'refreshing';
      }
      return 'idle';
    })();`).catch((_err: Error) => {
    });
  }

  private deleteOpenableChatBrowserItem(item: ChatBrowserItem): void {
    const payload = JSON.stringify({
      avatar: item.avatar,
      group: item.group,
      file: item.chatName,
    });
    this.controller.runJavaScript(`(async () => {
      if (typeof window.__tavernNextDeleteChat !== 'function') {
        return 'missing';
      }
      return await window.__tavernNextDeleteChat(${payload}) ? 'deleted' : 'failed';
    })();`).then((result: string) => {
      const normalized = (result ?? '').replace(/"/g, '');
      if (normalized === 'missing' || normalized === 'failed' || normalized === 'false') {
        this.showToast('删除失败。');
        return;
      }
      this.animateChatBrowserItemRemoval(item);
      this.showToast('聊天已删除。');
    }).catch((_err: Error) => {
      this.showToast('删除失败。');
    });
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message,
        duration: 1800
      });
    } catch (_err) {
    }
  }

  private flushWebPersistentState(reason: string): void {
    if (!this.running || this.persistenceFlushInFlight) {
      return;
    }

    this.persistenceFlushInFlight = true;
    const payload = JSON.stringify(reason);
    this.controller.runJavaScript(`(async () => {
      const flush = window.__tavernNextFlushPersistentState;
      if (typeof flush !== 'function') {
        return 'missing';
      }
      return await flush(${payload}) ? 'ok' : 'failed';
    })();`).then((_result: string) => {
      this.persistenceFlushInFlight = false;
    }).catch((_err: Error) => {
      this.persistenceFlushInFlight = false;
    });
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
      const observeThemeControl = (selector) => {
        const element = document.querySelector(selector);
        if (!element) {
          return;
        }
        element.addEventListener('change', schedule, true);
        element.addEventListener('input', schedule, true);
        new MutationObserver(schedule).observe(element, {
          attributes: true,
          attributeFilter: ['color', 'value', 'style', 'class']
        });
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
        observeThemeControl('#themes');
        observeThemeControl('#blur-tint-color-picker');
        observeThemeControl('#chat-tint-color-picker');
        window.addEventListener('load', schedule);
        window.addEventListener('resize', schedule);
        window.addEventListener('pageshow', schedule);
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
