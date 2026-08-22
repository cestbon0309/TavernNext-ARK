import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BackendService } from '../backend/BackendService';
import { CharacterBrowserChatItem, CharacterBrowserItem, CharacterBrowserRefreshListener,
  CharacterBrowserService } from '../backend/CharacterBrowserService';
import { ColorMetrics, ComponentContent, LengthMetrics, window } from '@kit.ArkUI';
import { ActionBarButton, ActionBarStyle, BlurStrategy, hdsMaterial, HdsActionBar, HdsNavigation,
  HdsNavigationMenuContentOptions, HdsNavigationTitleMode, IconStyleMode, ScrollEffectType,
  TitleSize } from '@kit.UIDesignKit';

const CHARACTER_BROWSER_ANIMATION_MS = 220;
const CHARACTER_BROWSER_ROW_HEIGHT = 124;
const CHARACTER_BROWSER_DELETE_WIDTH = 80;
const CHARACTER_BROWSER_SEARCH_SIZE = 42;
const CHARACTER_BROWSER_REFRESH_OFFSET = 72;
const CHARACTER_BROWSER_REFRESH_TRIGGER_OFFSET = 128;
const CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE = 24;
const CHARACTER_BROWSER_REFRESH_INDICATOR_GAP = 36;
const CHARACTER_BROWSER_REFRESH_SETTLE_SHIFT = 43;
const CHARACTER_BROWSER_REFRESH_MIN_MS = 600;
const CHARACTER_BROWSER_REFRESH_SPACER_HEIGHT = 236;
const CHARACTER_BROWSER_FAVORITE_DEBOUNCE_MS = 1000;
const CHARACTER_BROWSER_SORT_SEGMENT_WIDTH = 44;
const CHARACTER_BROWSER_IMPORT_MENU_ID = 'CharacterBrowserImportMenu';
const CHARACTER_BROWSER_REFRESH_INDICATOR_TOP = CHARACTER_BROWSER_REFRESH_SPACER_HEIGHT + 12 -
  CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE - CHARACTER_BROWSER_REFRESH_INDICATOR_GAP;

type CharacterItemAction = (item: CharacterBrowserItem) => void;
type CharacterChatAction = (item: CharacterBrowserItem, fileName?: string) => void;
type CharacterToastAction = (message: string) => void;
type CharacterSaveAction = (item: CharacterBrowserItem) => void;
type CharacterDetailStateAction = (open: boolean) => void;
type CharacterDetailBackAction = () => boolean;
type CharacterDetailDirtyAction = (dirty: boolean) => void;
type CharacterWebMutationAction = (action: string, avatar: string, value?: string) => Promise<string>;

class CharacterBrowserImportMenuActions {
  fromAlbum: () => void = (): void => {
  };
  fromFiles: () => void = (): void => {
  };
  fromUrl: () => void = (): void => {
  };
  create: () => void = (): void => {
  };
}

@Component
struct CharacterBrowserImportMenu {
  actions: CharacterBrowserImportMenuActions = new CharacterBrowserImportMenuActions();

  build() {
    Menu() {
      MenuItem({ content: '从相册导入' })
        .onClick(() => this.actions.fromAlbum())
      MenuItem({ content: '从文件管理器导入' })
        .onClick(() => this.actions.fromFiles())
      MenuItem({ content: '从 URL 导入' })
        .onClick(() => this.actions.fromUrl())
      MenuItem({ content: '创建新角色卡' })
        .onClick(() => this.actions.create())
    }
    .width(224)
    .backgroundColor(Color.Transparent)
    .menuItemDivider({
      strokeWidth: LengthMetrics.px(1),
      color: $r('app.color.native_browser_character_card_border'),
      startMargin: LengthMetrics.vp(16)
    })
  }
}

@Builder
function characterBrowserImportMenu(actions: CharacterBrowserImportMenuActions) {
  CharacterBrowserImportMenu({ actions })
}

class CharacterBrowserDataSource implements IDataSource {
  private items: CharacterBrowserItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): CharacterBrowserItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replace(items: CharacterBrowserItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@Component
export struct CharacterBrowserCard {
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @Prop item: CharacterBrowserItem = new CharacterBrowserItem();
  @Prop grid: boolean = false;
  @State swipeProgress: number = 0;
  @State favorite: boolean = false;
  private favoriteBeforeTouch: boolean = false;
  private favoriteTouchActive: boolean = false;
  private favoriteClickHandledByTouch: boolean = false;
  onOpen: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };
  onDelete: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };
  onFavorite: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };

  aboutToAppear(): void {
    this.favorite = this.item.favorite;
  }

  build() {
    if (this.grid) {
      this.gridCard();
    } else {
      ListItem() {
        this.listCard()
      }
      .padding({ left: 20, right: 20 })
      .swipeAction({
        end: {
          builder: () => {
            this.deleteAction()
          },
          actionAreaDistance: CHARACTER_BROWSER_DELETE_WIDTH + 12
        },
        edgeEffect: SwipeEdgeEffect.Spring,
        onOffsetChange: (offset: number) => {
          this.swipeProgress = Math.max(0, Math.min(1, Math.abs(offset) / CHARACTER_BROWSER_DELETE_WIDTH));
        }
      })
    }
  }

  @Builder
  private deleteAction() {
    Stack({ alignContent: Alignment.End }) {
      Button({ stateEffect: true }) {
        Text('删除')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width(CHARACTER_BROWSER_DELETE_WIDTH)
      .height(CHARACTER_BROWSER_ROW_HEIGHT)
      .padding(0)
      .backgroundColor('#FF4757')
      .borderRadius(14)
      .opacity(this.swipeProgress)
      .onClick(() => {
        this.onDelete(this.item);
      })
      .animation({ duration: 120, curve: Curve.EaseOut })
    }
    .width(CHARACTER_BROWSER_DELETE_WIDTH + 12)
    .height(CHARACTER_BROWSER_ROW_HEIGHT)
  }

  @Builder
  private listCard() {
    Row({ space: 13 }) {
      Stack() {
        Text(this.avatarBadgeText())
          .width(64)
          .height(64)
          .textAlign(TextAlign.Center)
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor(this.avatarBadgeColor())
          .borderRadius(18)
        Image(this.avatarUrl())
          .width(64)
          .height(64)
          .objectFit(ImageFit.Cover)
          .borderRadius(18)
          .backgroundColor(Color.Transparent)
      }
      .width(64)
      .height(64)
      .border({ width: 1, color: this.cardBorderColor() })

      Column({ space: 6 }) {
        Row() {
          Text(this.item.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            Text(this.favorite ? '★' : '☆')
              .fontSize(21)
              .fontColor(this.favorite ? '#F6C744' : this.secondaryTextColor())
          }
          .width(34)
          .height(34)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onTouch((event: TouchEvent) => this.handleFavoriteTouch(event))
          .onClick(() => this.handleFavoriteClick())
        }
        .width('100%')

        Text(this.item.description.length > 0 ? this.item.description :
          (this.item.creatorNotes.length > 0 ? this.item.creatorNotes : '暂无角色描述'))
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
          .width('100%')

        Row({ space: 8 }) {
          ForEach(this.item.tags.slice(0, 3), (tag: string) => {
            Text(tag)
              .fontSize(11)
              .fontColor(this.tagTextColor())
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.tagBackgroundColor())
              .borderRadius(12)
              .border({ width: 1, color: this.tagBorderColor() })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (tag: string) => tag)
          Blank()
          Text(this.formatBytes(this.item.chatSizeBytes))
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(this.swipeProgress > 0.99 ? CHARACTER_BROWSER_ROW_HEIGHT : CHARACTER_BROWSER_ROW_HEIGHT)
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(22)
    .shadow({ radius: 14, color: this.shadowColor(), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onOpen(this.item))
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private gridCard() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(this.avatarBadgeText())
          .width('100%')
          .aspectRatio(1)
          .textAlign(TextAlign.Center)
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor(this.avatarBadgeColor())
        Image(this.avatarUrl())
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Color.Transparent)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text(this.favorite ? '★' : '☆')
            .fontSize(19)
            .fontColor(this.favorite ? '#F6C744' : '#FFFFFF')
        }
        .width(34)
        .height(34)
        .padding(0)
        .margin({ top: 9, right: 9 })
        .backgroundColor('rgba(18,18,20,0.58)')
        .border({ width: 1, color: 'rgba(255,255,255,0.20)' })
        .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
        .onTouch((event: TouchEvent) => this.handleFavoriteTouch(event))
        .onClick(() => this.handleFavoriteClick())
      }
      .width('100%')
      .onClick(() => this.onOpen(this.item))

      Column({ space: 3 }) {
        Text(this.item.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 5 }) {
          if (this.item.tags.length > 0) {
            Text(this.item.tags[0])
              .fontSize(10)
              .fontColor('rgba(255,255,255,0.82)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Blank()
          Text(this.formatBytes(this.item.chatSizeBytes))
            .fontSize(10)
            .fontColor('rgba(255,255,255,0.72)')
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 11, right: 11, top: 10, bottom: 8 })
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
      .onClick(() => this.onOpen(this.item))
    }
    .width('100%')
    .aspectRatio(1)
    .border({ width: 1, color: this.gridBorderColor() })
    .borderRadius(18)
    .shadow({ radius: 10, color: this.shadowColor(), offsetX: 0, offsetY: 3 })
    .clip(true)
    .margin({ bottom: 7 })
  }

  private handleFavoriteTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Down && !this.favoriteTouchActive) {
      this.favoriteClickHandledByTouch = false;
      this.favoriteTouchActive = true;
      this.favoriteBeforeTouch = this.favorite;
      this.favorite = !this.favorite;
      return;
    }
    if (event.type === TouchType.Up && this.favoriteTouchActive) {
      this.favoriteTouchActive = false;
      this.favoriteClickHandledByTouch = true;
      this.dispatchFavorite();
      return;
    }
    if (event.type === TouchType.Cancel && this.favoriteTouchActive) {
      this.favoriteTouchActive = false;
      this.favoriteClickHandledByTouch = false;
      this.favorite = this.favoriteBeforeTouch;
    }
  }

  private handleFavoriteClick(): void {
    if (this.favoriteClickHandledByTouch) {
      this.favoriteClickHandledByTouch = false;
      return;
    }
    this.favorite = !this.favorite;
    this.dispatchFavorite();
  }

  private dispatchFavorite(): void {
    const updated = this.item.clone();
    updated.favorite = this.favorite;
    setTimeout(() => this.onFavorite(updated), 0);
  }

  private avatarBadgeText(): string {
    const trimmed = this.item.name.trim();
    const badgeSource = trimmed.startsWith('UI Audit ') ? trimmed.slice(9) : trimmed;
    return badgeSource.length > 0 ? badgeSource.slice(0, 1).toUpperCase() : '角';
  }

  private avatarBadgeColor(): ResourceColor {
    return $r('app.color.native_browser_accent');
  }

  private avatarUrl(): string {
    if (this.item.avatar.length === 0) {
      return '';
    }
    return `${this.backendUrl}/characters/${encodeURIComponent(this.item.avatar)}`;
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(0)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private primaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_primary_text');
  }

  private secondaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_character_secondary_text');
  }

  private cardColor(): ResourceColor {
    return $r('app.color.native_browser_character_card');
  }

  private cardBorderColor(): ResourceColor {
    return $r('app.color.native_browser_character_card_border');
  }

  private shadowColor(): ResourceColor {
    return $r('app.color.native_browser_card_shadow');
  }

  private gridBorderColor(): ResourceColor {
    return $r('app.color.native_browser_grid_border');
  }

  private tagTextColor(): ResourceColor {
    return $r('app.color.native_browser_tag_text');
  }

  private tagBackgroundColor(): ResourceColor {
    return $r('app.color.native_browser_tag_background');
  }

  private tagBorderColor(): ResourceColor {
    return $r('app.color.native_browser_tag_border');
  }
}

@Component
export struct CharacterBrowserDetail {
  @Prop item: CharacterBrowserItem = new CharacterBrowserItem();
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @State name: string = '';
  @State description: string = '';
  @State personality: string = '';
  @State scenario: string = '';
  @State firstMessage: string = '';
  @State exampleMessages: string = '';
  @State creatorNotes: string = '';
  @State creator: string = '';
  @State version: string = '';
  @State depthPrompt: string = '';
  @State depth: string = '4';
  @State depthRole: string = 'system';
  @State talkativeness: number = 0.5;
  @State tags: string[] = [];
  @State alternateGreetings: string[] = [];
  @State tagInput: string = '';
  @State favorite: boolean = false;
  @State chats: CharacterBrowserChatItem[] = [];
  @State expandedAdvanced: boolean = false;
  @State expandedCreator: boolean = false;
  @State expandedGreetings: boolean = false;
  @State saving: boolean = false;
  @State saved: boolean = false;
  @State savedAvatar: string = '';
  @State savedName: string = '';
  @State safeAreaTop: number = 0;
  @State safeAreaBottom: number = 0;
  private initialSignature: string = '';
  private service: CharacterBrowserService = new CharacterBrowserService();
  private favoriteBeforeTouch: boolean = false;
  private favoriteTouchActive: boolean = false;
  private favoriteClickHandledByTouch: boolean = false;
  private favoriteTimer: number = 0;
  onBack: () => void = (): void => {
  };
  onBackRequest: CharacterDetailBackAction = (): boolean => true;
  onOpenChat: CharacterChatAction = (_item: CharacterBrowserItem, _fileName?: string): void => {
  };
  onWebMutation: CharacterWebMutationAction = async (_action: string, _avatar: string, _value?: string): Promise<string> => {
    return '';
  };
  onDirtyChange: CharacterDetailDirtyAction = (_dirty: boolean): void => {
  };
  onDeleted: () => void = (): void => {
  };
  onChanged: CharacterSaveAction = (_item: CharacterBrowserItem): void => {
  };
  onToast: CharacterToastAction = (_message: string): void => {
  };

  aboutToAppear(): void {
    this.copyFromItem(this.item);
    this.updateSafeAreaInsets();
    this.loadChats();
  }

  build() {
    Column() {
      this.detailHeader()
      Scroll() {
        Column({ space: 12 }) {
          this.summaryCard()
          this.actionBar()
          this.chatHistory()
          this.tagsSection()
          this.textAreaSection('角色描述', this.description, (value: string): void => {
            this.description = value;
            this.markDirty();
          }, '描述角色的外貌、性格、背景与能力……支持 Markdown', 4)
          this.textAreaSection('首条消息', this.firstMessage, (value: string): void => {
            this.firstMessage = value;
            this.markDirty();
          }, '角色在新对话开始时发送的第一条消息……', 3)
          this.collapsibleCreator()
          this.collapsibleAdvanced()
          this.collapsibleGreetings()
          Button(this.saved ? '已保存' : (this.saving ? '正在保存…' : '保存更改'), { stateEffect: true })
            .width('100%')
            .height(48)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#4A90E2')
            .borderRadius(14)
            .enabled(!this.saving)
            .onClick(() => this.save())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 28 })
      }
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.safeAreaBottom })
    .backgroundColor(this.browserBackgroundColor())
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
    .onAreaChange(() => this.updateSafeAreaInsets())
  }

  @Builder
  private detailHeader() {
    Row({ space: 10 }) {
      HdsActionBar({
        endButtons: [this.detailBackAction()],
        actionBarStyle: this.detailActionStyle(),
        blurStrategy: BlurStrategy.ADAPTIVE
      })
        .width(42)
        .height(42)

      Text(this.name.length > 0 ? this.name : '角色详情')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image(this.favorite ? $r('app.media.ic_public_favorite') : $r('app.media.ic_public_favorite_outline'))
          .width(22)
          .height(22)
          .fillColor(this.favorite ? '#F6C744' : this.primaryTextColor())
      }
      .width(42)
      .height(42)
      .padding(0)
      .backgroundColor(this.chromeColor())
      .border({ width: 1, color: this.cardBorderColor() })
      .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
      .shadow(ShadowStyle.OUTER_DEFAULT_SM)
      .accessibilityText(this.favorite ? '取消收藏' : '收藏')
      .onTouch((event: TouchEvent) => this.handleFavoriteTouch(event))
      .onClick(() => this.handleFavoriteClick())

      HdsActionBar({
        endButtons: [this.detailSaveAction()],
        actionBarStyle: this.detailActionStyle(),
        blurStrategy: BlurStrategy.ADAPTIVE
      })
        .width(42)
        .height(42)
        .accessibilityText('保存')
    }
    .width('100%')
    .height(64 + this.safeAreaTop)
    .padding({ left: 16, right: 16, top: this.safeAreaTop })
    .backgroundColor(this.headerColor())
    .border({ width: { bottom: 1 }, color: this.cardBorderColor() })
  }

  private updateSafeAreaInsets(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow = context.windowStage.getMainWindowSync();
      const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutoutArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const topPx = Math.max(systemArea.topRect.height, cutoutArea.topRect.height);
      const nextTop = this.getUIContext().px2vp(topPx);
      const nextBottom = this.getUIContext().px2vp(systemArea.bottomRect.height);
      if (nextTop !== this.safeAreaTop) {
        this.safeAreaTop = nextTop;
      }
      if (nextBottom !== this.safeAreaBottom) {
        this.safeAreaBottom = nextBottom;
      }
    } catch (_err) {
      this.safeAreaTop = 0;
      this.safeAreaBottom = 0;
    }
  }

  @Builder
  private summaryCard() {
    Row({ space: 13 }) {
      Stack() {
        Text(this.avatarBadgeText())
          .width(64)
          .height(64)
          .textAlign(TextAlign.Center)
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor(this.avatarBadgeColor())
          .borderRadius(14)
        Image(this.avatarUrl())
          .width(64)
          .height(64)
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
      }
      .width(64)
      .height(64)
      Column({ space: 5 }) {
        TextInput({ text: this.name, placeholder: '角色名称' })
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .backgroundColor(Color.Transparent)
          .padding(0)
          .onChange((value: string) => {
          this.name = value;
          this.markDirty();
        })
        Text(`${this.formatDate(this.item.dateAddedMs)} · ${this.chats.length} 个对话`)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private actionBar() {
    Row({ space: 8 }) {
      this.actionButton('新建聊天', () => this.onOpenChat(this.currentItem()))
      this.exportActionButton()
      this.actionButton('复制角色', () => this.duplicateCard())
      this.actionButton('删除角色', () => this.deleteCard())
    }
    .width('100%')
  }

  @Builder
  private actionButton(label: string, action: () => void) {
    Button(label, { stateEffect: true })
      .layoutWeight(1)
      .height(42)
      .padding({ left: 4, right: 4 })
      .fontSize(12)
      .fontColor(label === '删除角色' ? '#E14D5A' : this.primaryTextColor())
      .backgroundColor(label === '新建聊天' ? 'rgba(74,144,226,0.18)' : this.cardColor())
      .border({ width: 1, color: label === '删除角色' ? 'rgba(225,77,90,0.28)' : this.cardBorderColor() })
      .borderRadius(12)
      .onClick(action)
  }

  @Builder
  private exportActionButton() {
    Button('导出', { stateEffect: true })
      .layoutWeight(1)
      .height(42)
      .padding({ left: 4, right: 4 })
      .fontSize(12)
      .fontColor(this.primaryTextColor())
      .backgroundColor(this.cardColor())
      .border({ width: 1, color: this.cardBorderColor() })
      .borderRadius(12)
      .accessibilityText('导出角色')
      .bindMenu([
        {
          value: '导出 PNG',
          action: (): void => this.exportCard('png')
        },
        {
          value: '导出 JSON',
          action: (): void => this.exportCard('json')
        }
      ], {
        title: '选择导出格式',
        placement: Placement.Bottom,
        enableArrow: true
      })
  }

  @Builder
  private chatHistory() {
    Column() {
      Row() {
        Text('对话记录')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
        Text(` ${this.chats.length} 个`)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
        Blank()
        Button('刷新', { stateEffect: true })
          .height(30)
          .fontSize(12)
          .fontColor(this.tagTextColor())
          .backgroundColor(Color.Transparent)
          .onClick(() => this.loadChats())
      }
      .width('100%')
      .padding({ left: 14, right: 8, top: 12, bottom: 10 })

      if (this.chats.length === 0) {
        Text('还没有对话记录')
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 18, bottom: 22 })
      } else {
        ForEach(this.chats.slice(0, 12), (chat: CharacterBrowserChatItem) => {
          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Row() {
                Text(this.fileStem(chat.fileName))
                  .fontSize(14)
                  .fontColor(this.primaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.relativeTime(chat.lastChatMs))
                  .fontSize(11)
                  .fontColor(this.secondaryTextColor())
              }
              Text(`${chat.messageCount} 条 · ${this.formatBytes(chat.fileSizeBytes)}${chat.preview.length > 0 ? ` · ${chat.preview}` : ''}`)
                .fontSize(11)
                .fontColor(this.secondaryTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            Text('›')
              .fontSize(22)
              .fontColor(this.secondaryTextColor())
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .border({ width: { top: 1 }, color: this.cardBorderColor() })
          .onClick(() => this.onOpenChat(this.currentItem(), chat.fileName))
        }, (chat: CharacterBrowserChatItem) => chat.fileName)
      }
    }
    .width('100%')
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private tagsSection() {
    Column({ space: 8 }) {
      Text('标签')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.secondaryTextColor())
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.tags, (tag: string) => {
          Row({ space: 4 }) {
            Text(tag)
              .fontSize(12)
              .fontColor(this.tagTextColor())
            Button('×', { stateEffect: true })
              .width(20)
              .height(20)
              .padding(0)
              .fontSize(15)
              .fontColor(this.tagTextColor())
              .backgroundColor(Color.Transparent)
              .onClick(() => this.removeTag(tag))
          }
          .padding({ left: 9, right: 5, top: 4, bottom: 4 })
          .backgroundColor(this.tagBackgroundColor())
          .borderRadius(12)
          .border({ width: 1, color: this.tagBorderColor() })
        }, (tag: string) => tag)
        TextInput({ text: this.tagInput, placeholder: '添加标签，回车确认' })
          .width(160)
          .height(30)
          .fontSize(12)
          .fontColor(this.primaryTextColor())
          .placeholderColor(this.secondaryTextColor())
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .onChange((value: string) => this.tagInput = value)
          .onSubmit(() => this.addTag())
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private textAreaSection(title: string, value: string, onChange: (value: string) => void, placeholder: string,
    rows: number) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.secondaryTextColor())
        .width('100%')
      TextArea({ text: value, placeholder })
        .width('100%')
        .height(rows * 26 + 24)
        .fontSize(14)
        .fontColor(this.primaryTextColor())
        .placeholderColor(this.secondaryTextColor())
        .backgroundColor(this.inputColor())
        .borderRadius(10)
        .padding(10)
        .onChange(onChange)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private collapsibleCreator() {
    Column() {
      this.sectionHeader('创作者笔记', () => this.expandedCreator, () => this.toggleCreator())
      if (this.expandedCreator) {
        TextArea({ text: this.creatorNotes, placeholder: '给使用者的提示或背景说明……（不会影响 AI 行为）' })
          .width('100%')
          .height(140)
          .fontSize(14)
          .fontColor(this.primaryTextColor())
          .placeholderColor(this.secondaryTextColor())
          .backgroundColor(this.inputColor())
          .borderRadius(10)
          .padding(10)
          .onChange((value: string) => {
              this.creatorNotes = value;
              this.markDirty();
            })
          .margin({ top: 10 })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 }))
            .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private collapsibleAdvanced() {
    Column() {
      this.sectionHeader('高级设定', () => this.expandedAdvanced, () => this.toggleAdvanced())
      if (this.expandedAdvanced) {
        Column({ space: 10 }) {
          TextArea({ text: this.personality, placeholder: '性格摘要' })
            .height(90)
            .width('100%')
            .fontSize(14)
            .fontColor(this.primaryTextColor())
            .placeholderColor(this.secondaryTextColor())
            .backgroundColor(this.inputColor())
            .borderRadius(10)
            .padding(10)
            .onChange((value: string) => {
              this.personality = value;
              this.markDirty();
            })
          TextArea({ text: this.scenario, placeholder: '场景设定' })
            .height(100)
            .width('100%')
            .fontSize(14)
            .fontColor(this.primaryTextColor())
            .placeholderColor(this.secondaryTextColor())
            .backgroundColor(this.inputColor())
            .borderRadius(10)
            .padding(10)
            .onChange((value: string) => {
              this.scenario = value;
              this.markDirty();
            })
          Text('话量倾向')
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
          Slider({ value: this.talkativeness, min: 0, max: 1, step: 0.05, style: SliderStyle.OutSet })
            .blockColor('#4A90E2')
            .trackColor(this.inputColor())
            .selectedColor('#4A90E2')
            .onChange((value: number) => {
              this.talkativeness = value;
              this.markDirty();
            })
          TextInput({ text: this.depthPrompt, placeholder: '角色注入提示词' })
            .height(42)
            .fontSize(13)
            .fontColor(this.primaryTextColor())
            .placeholderColor(this.secondaryTextColor())
            .backgroundColor(this.inputColor())
            .borderRadius(10)
            .padding({ left: 10, right: 10 })
            .onChange((value: string) => {
              this.depthPrompt = value;
              this.markDirty();
            })
          Row({ space: 8 }) {
            TextInput({ text: this.depth, placeholder: '深度' })
              .layoutWeight(1)
              .height(42)
              .fontSize(13)
              .fontColor(this.primaryTextColor())
              .placeholderColor(this.secondaryTextColor())
              .backgroundColor(this.inputColor())
              .borderRadius(10)
              .padding({ left: 10, right: 10 })
              .onChange((value: string) => {
                this.depth = value;
                this.markDirty();
              })
            Select([{ value: 'system' }, { value: 'user' }, { value: 'assistant' }])
              .selected(this.depthRole === 'user' ? 1 : this.depthRole === 'assistant' ? 2 : 0)
              .value(this.depthRole)
              .height(42)
              .layoutWeight(1)
              .onSelect((_index: number, value?: string) => {
                if (value !== undefined) {
                  this.depthRole = value;
                   this.markDirty();
                }
              })
          }
        }
        .width('100%')
        .margin({ top: 10 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 }))
          .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private collapsibleGreetings() {
    Column() {
      this.sectionHeader(`备选问候语 (${this.alternateGreetings.length})`, () => this.expandedGreetings,
        () => this.toggleGreetings())
      if (this.expandedGreetings) {
        Column() {
          ForEach(this.alternateGreetings, (greeting: string, index: number) => {
            Row({ space: 6 }) {
              TextArea({ text: greeting, placeholder: '备选问候语' })
                .layoutWeight(1)
                .height(90)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .placeholderColor(this.secondaryTextColor())
                .backgroundColor(this.inputColor())
                .borderRadius(10)
                .padding(8)
                .onChange((value: string) => this.updateGreeting(index, value))
              Button('×', { stateEffect: true })
                .width(30)
                .height(30)
                .padding(0)
                .fontSize(18)
                .fontColor('#E14D5A')
                .backgroundColor(Color.Transparent)
                .onClick(() => this.removeGreeting(index))
            }
            .width('100%')
            .margin({ bottom: 8 })
          }, (greeting: string, index: number) => `${index}-${greeting.slice(0, 12)}`)
          Button('+ 添加问候语', { stateEffect: true })
            .width('100%')
            .height(38)
            .fontColor(this.tagTextColor())
            .backgroundColor(this.inputColor())
            .borderRadius(10)
            .onClick(() => {
              this.alternateGreetings = [...this.alternateGreetings, ''];
              this.markDirty();
            })
        }
        .width('100%')
        .margin({ top: 10 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 }))
          .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private sectionHeader(title: string, expanded: () => boolean, action: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
        .onClick(action)
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image(expanded() ? $r('app.media.ic_chevron_up') : $r('app.media.ic_chevron_down'))
          .width(18)
          .height(18)
          .fillColor(this.secondaryTextColor())
      }
      .width(30)
      .height(30)
      .padding(0)
      .backgroundColor(this.inputColor())
      .border({ width: 1, color: this.cardBorderColor() })
      .accessibilityText(expanded() ? `收起${title}` : `展开${title}`)
      .onClick(action)
    }
    .width('100%')
    .height(32)
  }

  private toggleCreator(): void {
    this.getUIContext().animateTo({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedCreator = !this.expandedCreator;
    });
  }

  private toggleAdvanced(): void {
    this.getUIContext().animateTo({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedAdvanced = !this.expandedAdvanced;
    });
  }

  private toggleGreetings(): void {
    this.getUIContext().animateTo({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedGreetings = !this.expandedGreetings;
    });
  }

  private copyFromItem(item: CharacterBrowserItem): void {
    this.savedAvatar = item.avatar;
    this.savedName = item.name;
    this.name = item.name;
    this.description = item.description;
    this.personality = item.personality;
    this.scenario = item.scenario;
    this.firstMessage = item.firstMessage;
    this.exampleMessages = item.exampleMessages;
    this.creatorNotes = item.creatorNotes;
    this.creator = item.creator;
    this.version = item.version;
    this.depthPrompt = item.depthPrompt;
    this.depth = `${item.depth}`;
    this.depthRole = item.depthRole;
    this.talkativeness = item.talkativeness;
    this.tags = [...item.tags];
    this.alternateGreetings = [...item.alternateGreetings];
    this.favorite = item.favorite;
    this.initialSignature = this.editSignature();
    this.onDirtyChange(false);
  }

  private editSignature(): string {
    return JSON.stringify([
      this.name,
      this.description,
      this.personality,
      this.scenario,
      this.firstMessage,
      this.exampleMessages,
      this.creatorNotes,
      this.creator,
      this.version,
      this.depthPrompt,
      this.depth,
      this.depthRole,
      this.talkativeness,
      this.tags,
      this.alternateGreetings
    ]);
  }

  private markDirty(): void {
    this.onDirtyChange(this.editSignature() !== this.initialSignature);
  }

  private currentItem(): CharacterBrowserItem {
    const next = this.item.clone();
    next.avatar = this.savedAvatar.length > 0 ? this.savedAvatar : this.item.avatar;
    next.id = next.avatar;
    next.name = this.name.trim() || this.savedName;
    next.description = this.description;
    next.personality = this.personality;
    next.scenario = this.scenario;
    next.firstMessage = this.firstMessage;
    next.exampleMessages = this.exampleMessages;
    next.creatorNotes = this.creatorNotes;
    next.creator = this.creator;
    next.version = this.version;
    next.depthPrompt = this.depthPrompt;
    next.depth = Number(this.depth) || 4;
    next.depthRole = this.depthRole;
    next.talkativeness = this.talkativeness;
    next.tags = [...this.tags];
    next.alternateGreetings = [...this.alternateGreetings];
    next.favorite = this.favorite;
    return next;
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    const next = this.currentItem();
    if (next.name.length === 0) {
      this.onToast('角色名称不能为空。');
      return;
    }
    this.saving = true;
    let renamedAvatar = '';
    const renamed = next.name !== this.savedName;
    try {
      if (renamed) {
        renamedAvatar = await this.onWebMutation('rename', this.savedAvatar, next.name);
        if (renamedAvatar.length === 0 || renamedAvatar === 'failed') {
          throw new Error('rename returned empty avatar');
        }
        next.avatar = renamedAvatar;
        next.id = renamedAvatar;
        this.savedAvatar = renamedAvatar;
        this.savedName = next.name;
      }
      if (!await this.service.save(this.backendUrl, next)) {
        throw new Error('save failed');
      }
      this.savedAvatar = next.avatar;
      this.savedName = next.name;
      this.initialSignature = this.editSignature();
      this.onDirtyChange(false);
      this.saved = true;
      this.onChanged(next);
      if (renamed) {
        this.loadChats();
      }
      const refreshed = await this.onWebMutation('refresh', next.avatar);
      if (refreshed !== 'ok') {
        this.onToast('角色已保存，但 WebUI 列表同步失败。');
      }
      this.onToast(renamed ? '角色已改名并保存。' : '角色已保存。');
      setTimeout(() => this.saved = false, 1500);
    } catch (_err) {
      if (renamedAvatar.length > 0) {
        this.onToast('角色已改名，但其他字段保存失败，请再次点击保存。');
      } else {
        this.onToast('保存角色失败。');
      }
    } finally {
      this.saving = false;
    }
  }

  private deleteCard(): void {
    AlertDialog.show({
      title: '删除角色',
      message: `确定删除「${this.name}」吗？相关聊天记录也会删除，此操作无法撤销。`,
      autoCancel: true,
      primaryButton: {
        value: '删除',
        action: () => {
          this.onWebMutation('delete', this.currentAvatar()).then((result: string) => {
            if (result !== 'ok') {
              this.onToast(result === 'cancelled' ? '删除已取消。' : '删除角色失败。');
              return;
            }
            this.onToast('角色已删除。');
            this.onDeleted();
          }).catch((_err: Error) => this.onToast('删除角色失败。'));
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private duplicateCard(): void {
    this.onWebMutation('duplicate', this.currentAvatar()).then((result: string) => {
      if (result.startsWith('ok:')) {
        this.onToast('角色已复制。');
        this.onBack();
      } else {
        this.onToast('复制角色失败。');
      }
    }).catch((_err: Error) => this.onToast('复制角色失败。'));
  }

  private exportCard(format: string): void {
    this.service.export(this.backendUrl, this.currentAvatar(), format).then((success: boolean) => {
      this.onToast(success ? '已打开分享面板。' : '导出角色失败。');
    }).catch((_err: Error) => this.onToast('导出角色失败。'));
  }

  private loadChats(): void {
    this.service.chats(this.backendUrl, this.currentAvatar()).then((items: CharacterBrowserChatItem[]) => {
      this.chats = items.sort((left: CharacterBrowserChatItem, right: CharacterBrowserChatItem): number => {
        return right.lastChatMs - left.lastChatMs;
      });
    }).catch((_err: Error) => {
      this.chats = [];
    });
  }

  private addTag(): void {
    const tag = this.tagInput.trim();
    if (tag.length > 0 && !this.tags.includes(tag)) {
      this.tags = [...this.tags, tag];
      this.markDirty();
    }
    this.tagInput = '';
  }

  private removeTag(tag: string): void {
    this.tags = this.tags.filter((candidate: string): boolean => candidate !== tag);
    this.markDirty();
  }

  private updateGreeting(index: number, value: string): void {
    const greetings = [...this.alternateGreetings];
    greetings[index] = value;
    this.alternateGreetings = greetings;
    this.markDirty();
  }

  private removeGreeting(index: number): void {
    this.alternateGreetings = this.alternateGreetings.filter((_value: string, current: number): boolean => current !== index);
    this.markDirty();
  }

  private avatarBadgeText(): string {
    const trimmed = this.name.trim();
    const badgeSource = trimmed.startsWith('UI Audit ') ? trimmed.slice(9) : trimmed;
    return badgeSource.length > 0 ? badgeSource.slice(0, 1).toUpperCase() : '角';
  }

  private avatarBadgeColor(): ResourceColor {
    return $r('app.color.native_browser_accent');
  }

  private currentAvatar(): string {
    return this.savedAvatar.length > 0 ? this.savedAvatar : this.item.avatar;
  }

  private avatarUrl(): string {
    return `${this.backendUrl}/characters/${encodeURIComponent(this.currentAvatar())}`;
  }

  private fileStem(value: string): string {
    const dot = value.lastIndexOf('.');
    return dot > 0 ? value.slice(0, dot) : value;
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(0)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private formatDate(timestamp: number): string {
    if (timestamp <= 0) {
      return '未记录时间';
    }
    const date = new Date(timestamp);
    return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
  }

  private relativeTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '暂无';
    }
    const diff = Math.max(0, Date.now() - timestamp);
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (diff < minute) {
      return '刚刚';
    }
    if (diff < hour) {
      return `${Math.floor(diff / minute)}分钟前`;
    }
    if (diff < day) {
      return `${Math.floor(diff / hour)}小时前`;
    }
    return `${Math.floor(diff / day)}天前`;
  }

  private detailBackAction(): ActionBarButton {
    return this.detailActionButton($r('app.media.ic_public_back'), '返回', (): void => {
      if (this.onBackRequest()) {
        this.onBack();
      }
    });
  }

  private detailSaveAction(): ActionBarButton {
    return this.detailActionButton($r('app.media.ic_public_save'), '保存', (): void => {
      setTimeout(() => this.save(), CHARACTER_BROWSER_ANIMATION_MS);
    }, '#4A90E2');
  }

  private handleFavoriteTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Down && !this.favoriteTouchActive) {
      this.favoriteClickHandledByTouch = false;
      this.favoriteTouchActive = true;
      this.favoriteBeforeTouch = this.favorite;
      this.favorite = !this.favorite;
      return;
    }
    if (event.type === TouchType.Up && this.favoriteTouchActive) {
      this.favoriteTouchActive = false;
      this.favoriteClickHandledByTouch = true;
      this.scheduleFavoriteSave();
      return;
    }
    if (event.type === TouchType.Cancel && this.favoriteTouchActive) {
      this.favoriteTouchActive = false;
      this.favoriteClickHandledByTouch = false;
      this.favorite = this.favoriteBeforeTouch;
    }
  }

  private handleFavoriteClick(): void {
    if (this.favoriteClickHandledByTouch) {
      this.favoriteClickHandledByTouch = false;
      return;
    }
    this.favorite = !this.favorite;
    this.scheduleFavoriteSave();
  }

  private scheduleFavoriteSave(): void {
    clearTimeout(this.favoriteTimer);
    this.favoriteTimer = setTimeout(() => this.persistFavorite(), CHARACTER_BROWSER_FAVORITE_DEBOUNCE_MS);
  }

  private persistFavorite(): void {
    this.favoriteTimer = 0;
    const avatar = this.currentAvatar();
    const favorite = this.favorite;
    this.item.favorite = favorite;
    this.service.setFavorite(this.backendUrl, avatar, favorite).then((success: boolean) => {
      if (success) {
        this.onWebMutation('refresh', avatar).catch((_err: Error) => {
        });
      }
    }).catch((_err: Error) => {
    });
  }

  private detailActionButton(icon: Resource, label: string, action: () => void,
    iconColor: ResourceColor = this.primaryTextColor(), enabled: boolean = true): ActionBarButton {
    return new ActionBarButton({
      width: LengthMetrics.vp(42),
      shadowStyle: ShadowStyle.OUTER_DEFAULT_SM,
      enabled: enabled,
      baseIcon: icon,
      iconFillColor: ColorMetrics.resourceColor(iconColor),
      iconSize: LengthMetrics.vp(22),
      accessibilityText: label,
      hoverTips: label,
      onClick: action
    });
  }

  private detailActionStyle(): ActionBarStyle {
    return new ActionBarStyle({
      height: LengthMetrics.vp(42),
      backgroundBlurStyle: BlurStyle.COMPONENT_REGULAR,
      innerSpace: LengthMetrics.vp(0),
      startSpace: LengthMetrics.vp(0),
      endSpace: LengthMetrics.vp(0),
      margin: LengthMetrics.vp(0)
    });
  }

  private browserBackgroundColor(): ResourceColor {
    return $r('app.color.native_browser_detail_background');
  }

  private headerColor(): ResourceColor {
    return $r('app.color.native_browser_header');
  }

  private inputColor(): ResourceColor {
    return $r('app.color.native_browser_detail_input');
  }

  private chromeColor(): ResourceColor {
    return $r('app.color.native_browser_chrome');
  }

  private cardColor(): ResourceColor {
    return $r('app.color.native_browser_detail_card');
  }

  private cardBorderColor(): ResourceColor {
    return $r('app.color.native_browser_character_card_border');
  }

  private primaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_primary_text');
  }

  private secondaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_character_secondary_text');
  }

  private tagTextColor(): ResourceColor {
    return $r('app.color.native_browser_tag_text');
  }

  private tagBackgroundColor(): ResourceColor {
    return $r('app.color.native_browser_tag_background');
  }

  private tagBorderColor(): ResourceColor {
    return $r('app.color.native_browser_tag_border');
  }
}

@Component
export struct CharacterBrowserPanel {
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @Prop detailOpen: boolean = false;
  @State items: CharacterBrowserItem[] = [];
  @State query: string = '';
  @State activeFilter: string = 'all';
  @State sortMode: string = 'name';
  @State gridMode: boolean = true;
  @State refreshing: boolean = false;
  @State loading: boolean = true;
  @State refreshOffset: number = 0;
  @State detail: CharacterBrowserItem | null = null;
  private service: CharacterBrowserService = new CharacterBrowserService();
  private gridScroller: Scroller = new Scroller();
  private listScroller: Scroller = new Scroller();
  private dataSource: CharacterBrowserDataSource = new CharacterBrowserDataSource();
  private favoriteTimers: Map<string, number> = new Map();
  private importMenuContent: ComponentContent<CharacterBrowserImportMenuActions> | null = null;
  private refreshListener: CharacterBrowserRefreshListener = (items: CharacterBrowserItem[]): void => {
    this.applyItems(items);
    this.loading = false;
  };
  onClose: () => void = (): void => {
  };
  onOpenChat: CharacterChatAction = (_item: CharacterBrowserItem, _fileName?: string): void => {
  };
  onWebMutation: CharacterWebMutationAction = async (_action: string, _avatar: string, _value?: string): Promise<string> => {
    return '';
  };
  onBackRequest: CharacterDetailBackAction = (): boolean => true;
  onDirtyChange: CharacterDetailDirtyAction = (_dirty: boolean): void => {
  };
  onDetailChange: CharacterDetailStateAction = (_open: boolean): void => {
  };
  onToast: CharacterToastAction = (_message: string): void => {
  };

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.service = BackendService.getInstance(context).getCharacterBrowser();
    this.service.subscribeRefresh(this.refreshListener);
    const hasCachedList = this.service.hasCachedList();
    if (hasCachedList) {
      this.applyItems(this.service.cachedList());
      this.loading = false;
      return;
    }
    this.loading = true;
    this.service.initializeCacheAsync().then((items: CharacterBrowserItem[]) => {
      this.applyItems(items);
      this.loading = false;
    }).catch((_err: Error) => {
      this.loading = false;
      this.onToast('读取角色卡失败。');
    });
  }

  aboutToDisappear(): void {
    this.service.unsubscribeRefresh(this.refreshListener);
  }

  build() {
    if (this.detail !== null && this.detailOpen) {
      CharacterBrowserDetail({
        item: this.detail,
        backendUrl: this.backendUrl,
        onBack: (): void => {
          this.detail = null;
          this.onDetailChange(false);
        },
        onOpenChat: this.onOpenChat,
        onWebMutation: this.onWebMutation,
        onBackRequest: this.onBackRequest,
        onDirtyChange: (dirty: boolean): void => {
          this.onDirtyChange(dirty);
        },
        onDeleted: (): void => {
          this.detail = null;
          this.onDetailChange(false);
        },
        onChanged: (item: CharacterBrowserItem): void => {
          this.detail = item;
        },
        onToast: this.onToast
      })
    } else {
      this.listView();
    }
  }

  @Builder
  private listView() {
    HdsNavigation() {
      Column() {
        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(42)
              .height(42)
              .color(this.tagTextColor())
            Text('正在读取角色卡…')
              .fontSize(14)
              .fontColor(this.secondaryTextColor())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.gridMode) {
          Refresh({
            refreshing: $$this.refreshing,
            offset: CHARACTER_BROWSER_REFRESH_OFFSET,
            builder: () => {
              this.refreshPlaceholder()
            }
          }) {
            Grid(this.gridScroller) {
              GridItem() {
                this.refreshIndicator()
              }
              .columnStart(0)
              .columnEnd(1)
              if (this.displayedItems().length === 0) {
                GridItem() {
                  this.emptyState()
                }
                .columnStart(0)
                .columnEnd(1)
              } else {
                LazyForEach(this.dataSource, (item: CharacterBrowserItem) => {
                  GridItem() {
                      CharacterBrowserCard({
                        item,
                        backendUrl: this.backendUrl,
                        grid: true,
                        onOpen: (selected: CharacterBrowserItem): void => this.openDetail(selected),
                        onFavorite: (selected: CharacterBrowserItem): void => this.toggleFavorite(selected)
                      })
                  }
                  .width('100%')
                }, (item: CharacterBrowserItem) => item.id)
              }
              GridItem() {
                Row()
                  }
              .width('100%')
              .height(108)
              .columnStart(0)
              .columnEnd(1)
            }
            .width('100%')
            .height('100%')
            .columnsTemplate('1fr 1fr')
            .columnsGap(8)
            .rowsGap(7)
            .padding({ left: 8, right: 8 })
            .cachedCount(2)
            .scrollBar(BarState.Off)
            .translate({ y: this.refreshing ? -CHARACTER_BROWSER_REFRESH_SETTLE_SHIFT : 0 })
            .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .height('100%')
          .refreshOffset(CHARACTER_BROWSER_REFRESH_TRIGGER_OFFSET)
          .pullToRefresh(true)
          .onOffsetChange((offset: number) => {
            this.refreshOffset = Math.max(0, offset);
          })
          .onRefreshing(() => this.refresh(true))
        } else {
          Refresh({
            refreshing: $$this.refreshing,
            offset: CHARACTER_BROWSER_REFRESH_OFFSET,
            builder: () => {
              this.refreshPlaceholder()
            }
          }) {
            List({ space: 10, scroller: this.listScroller }) {
              ListItem() {
                Column() {
                  LoadingProgress()
                    .width(CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE)
                    .height(CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE)
                    .color(this.secondaryTextColor())
                    .opacity(this.refreshIndicatorOpacity())
                }
                  .height('100%')
                  .width('100%')
                  .padding({ top: CHARACTER_BROWSER_REFRESH_INDICATOR_TOP })
                  .alignItems(HorizontalAlign.Center)
              }
              .height(CHARACTER_BROWSER_REFRESH_SPACER_HEIGHT)
              if (this.displayedItems().length === 0) {
                ListItem() {
                  this.emptyState()
                }
              } else {
                LazyForEach(this.dataSource, (item: CharacterBrowserItem) => {
                  CharacterBrowserCard({
                    item,
                    backendUrl: this.backendUrl,
                    grid: false,
                    onOpen: (selected: CharacterBrowserItem): void => this.openDetail(selected),
                    onDelete: (selected: CharacterBrowserItem): void => this.confirmDelete(selected),
                    onFavorite: (selected: CharacterBrowserItem): void => this.toggleFavorite(selected)
                  })
                }, (item: CharacterBrowserItem) => item.id)
              }
              ListItem() {
                Row()
                  .width('100%')
                  .height(94)
              }
            }
            .width('100%')
            .height('100%')
            .cachedCount(6)
            .scrollBar(BarState.Off)
            .translate({ y: this.refreshing ? -CHARACTER_BROWSER_REFRESH_SETTLE_SHIFT : 0 })
            .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .height('100%')
          .refreshOffset(CHARACTER_BROWSER_REFRESH_TRIGGER_OFFSET)
          .pullToRefresh(true)
          .onOffsetChange((offset: number) => {
            this.refreshOffset = Math.max(0, offset);
          })
          .onRefreshing(() => this.refresh(true))
        }
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .titleBar({
      padding: {
        start: LengthMetrics.vp(20),
        end: LengthMetrics.vp(20)
      },
      content: {
        title: {
          mainTitle: '角色卡',
          mainTitleSize: TitleSize.TITLE_S
        },
        menu: this.navigationMenu(),
        bottomBuilder: {
          builder: () => this.titleBarBottom(),
          height: 134
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          enableRefreshOffsetChange: true
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: $r('app.color.native_browser_gradient_mask'),
            maskExtraHeight: 28,
            blurRadius: 28
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.primaryTextColor(),
              subTitleColor: this.secondaryTextColor()
            },
            menuStyle: {
              backgroundColor: $r('app.color.native_browser_control_background'),
              iconColor: this.primaryTextColor()
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('app.color.native_browser_gradient_mask'),
            maskExtraHeight: 28,
            blurRadius: 28
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.primaryTextColor(),
              subTitleColor: this.secondaryTextColor()
            },
            menuStyle: {
              backgroundColor: $r('app.color.native_browser_control_background'),
              iconColor: this.primaryTextColor()
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        blurStrategy: BlurStrategy.ADAPTIVE,
        thermoCtrl: true
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .withTheme({ enableThemeColorMode: true })
    .bindToScrollable([this.gridScroller, this.listScroller])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor(this.browserBackgroundColor())
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private titleBarBottom() {
    Column() {
      Row() {
        Search({ placeholder: '搜索角色名称或描述', value: this.query })
        .layoutWeight(1)
        .height(CHARACTER_BROWSER_SEARCH_SIZE)
        .textFont({ size: 15 })
        .fontColor(this.primaryTextColor())
        .placeholderColor(this.secondaryTextColor())
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .borderRadius(CHARACTER_BROWSER_SEARCH_SIZE / 2)
        .accessibilityText('搜索角色名称或描述')
        .onChange((value: string) => this.setQuery(value))
      }
      .width('100%')
      .height(CHARACTER_BROWSER_SEARCH_SIZE)
      .padding({ left: 24, right: 24 })
      this.filterBar()
      this.resultToolbar()
    }
    .width('100%')
    .height(134)
  }

  @Builder
  private filterBar() {
    Scroll() {
      Row({ space: 8 }) {
        this.filterPill('全部', () => this.setFilter('all'))
        this.filterPill('★ 收藏', () => {
          this.setFilter(this.activeFilter === 'fav' ? 'all' : 'fav');
        })
        ForEach(this.allTags(), (tag: string) => {
          this.filterPill(tag, () => {
            this.setFilter(this.activeFilter === tag ? 'all' : tag);
          });
        }, (tag: string) => tag)
      }
      .padding({ left: 20, right: 20 })
    }
    .width('100%')
    .height(42)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Start)
    .accessibilityText('横向滚动筛选标签')
  }

  @Builder
  private filterPill(label: string, action: () => void) {
    Button(label, { stateEffect: true })
      .height(30)
      .padding({ left: 11, right: 11 })
      .fontSize(12)
      .fontColor(this.filterPillActive(label) ? '#FFFFFF' : this.secondaryTextColor())
      .backgroundColor(this.filterPillActive(label) ? '#4A90E2' : this.chromeColor())
      .border({ width: 1, color: this.filterPillActive(label) ? '#4A90E2' : this.cardBorderColor() })
      .borderRadius(15)
      .onClick(action)
  }

  private filterPillActive(label: string): boolean {
    if (label === '全部') {
      return this.activeFilter === 'all';
    }
    if (label === '★ 收藏') {
      return this.activeFilter === 'fav';
    }
    return this.activeFilter === label;
  }

  @Builder
  private resultToolbar() {
    Row({ space: 8 }) {
      Text(`${this.displayedItems().length} 个结果`)
        .fontSize(13)
        .fontColor(this.secondaryTextColor())
      Blank()
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width(CHARACTER_BROWSER_SORT_SEGMENT_WIDTH)
          .height(30)
          .backgroundColor('#4A90E2')
          .borderRadius(15)
          .position({ x: 1 + this.sortModeIndex() * CHARACTER_BROWSER_SORT_SEGMENT_WIDTH, y: 1 })
          .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn })
        Row() {
          this.sortSegment('名称', 'name')
          this.sortSegment('数量', 'chatCount')
          this.sortSegment('时间', 'created')
        }
        .position({ x: 1, y: 1 })
      }
      .width(CHARACTER_BROWSER_SORT_SEGMENT_WIDTH * 3 + 2)
      .height(32)
      .backgroundColor(this.chromeColor())
      .border({ width: 1, color: this.cardBorderColor() })
      .borderRadius(16)
      .clip(true)
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image(this.gridMode ? $r('app.media.ic_view_list') : $r('app.media.ic_view_grid'))
          .width(18)
          .height(18)
          .fillColor(this.tagTextColor())
      }
        .width(32)
        .height(32)
        .padding(0)
        .backgroundColor(this.chromeColor())
        .border({ width: 1, color: this.cardBorderColor() })
        .accessibilityText(this.gridMode ? '切换到列表' : '切换到网格')
        .onClick(() => this.gridMode = !this.gridMode)
    }
    .width('100%')
    .height(44)
    .padding({ left: 20, right: 20 })
  }

  @Builder
  private sortSegment(label: string, mode: string) {
    Button(label, { stateEffect: true })
      .width(CHARACTER_BROWSER_SORT_SEGMENT_WIDTH)
      .height(30)
      .padding(0)
      .fontSize(12)
      .fontWeight(this.sortMode === mode ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.sortMode === mode ? '#FFFFFF' : this.secondaryTextColor())
      .backgroundColor(Color.Transparent)
      .borderRadius(15)
      .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        this.sortMode = mode;
        this.updateDataSource();
      })
  }

  private sortModeIndex(): number {
    if (this.sortMode === 'chatCount') {
      return 1;
    }
    if (this.sortMode === 'created') {
      return 2;
    }
    return 0;
  }

  private displayedItems(): CharacterBrowserItem[] {
    return this.filteredItems(this.items);
  }

  private filteredItems(items: CharacterBrowserItem[]): CharacterBrowserItem[] {
    let result = items.filter((item: CharacterBrowserItem): boolean => {
      const query = this.query.trim().toLowerCase();
      const matchesQuery = query.length === 0 || `${item.name} ${item.description} ${item.creatorNotes} ${item.tags.join(' ')}`
        .toLowerCase().includes(query);
      const matchesFilter = this.activeFilter === 'all' ||
        (this.activeFilter === 'fav' && item.favorite) || item.tags.includes(this.activeFilter);
      return matchesQuery && matchesFilter;
    });
    result = [...result];
    if (this.sortMode === 'name') {
      result.sort((left: CharacterBrowserItem, right: CharacterBrowserItem): number => left.name.localeCompare(right.name, 'zh'));
    } else if (this.sortMode === 'chatCount') {
      result.sort((left: CharacterBrowserItem, right: CharacterBrowserItem): number => right.chatSizeBytes - left.chatSizeBytes);
    } else {
      result.sort((left: CharacterBrowserItem, right: CharacterBrowserItem): number => right.dateAddedMs - left.dateAddedMs);
    }
    return result;
  }

  private allTags(): string[] {
    const tags: string[] = [];
    for (const item of this.items) {
      for (const tag of item.tags) {
        if (!tags.includes(tag)) {
          tags.push(tag);
        }
      }
    }
    return tags;
  }

  private setQuery(value: string): void {
    this.query = value;
    this.updateDataSource();
  }

  private setFilter(value: string): void {
    this.activeFilter = value;
    this.updateDataSource();
  }

  private applyItems(items: CharacterBrowserItem[]): void {
    this.items = items;
    this.dataSource.replace(this.filteredItems(items));
  }

  private updateDataSource(): void {
    this.dataSource.replace(this.filteredItems(this.items));
  }

  @Builder
  private refreshPlaceholder() {
    Row()
      .width(1)
      .height(1)
      .opacity(0)
  }

  @Builder
  private refreshIndicator() {
    Column() {
      LoadingProgress()
        .width(CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE)
        .height(CHARACTER_BROWSER_REFRESH_INDICATOR_SIZE)
        .color(this.secondaryTextColor())
        .opacity(this.refreshIndicatorOpacity())
    }
    .width('100%')
    .height(CHARACTER_BROWSER_REFRESH_SPACER_HEIGHT)
    .padding({ top: CHARACTER_BROWSER_REFRESH_INDICATOR_TOP })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private emptyState() {
    Column({ space: 8 }) {
      Text('没有找到角色')
        .fontSize(18)
        .fontColor(this.primaryTextColor())
      Text('尝试调整搜索词或过滤条件。')
        .fontSize(13)
        .fontColor(this.secondaryTextColor())
      Button('新建角色', { stateEffect: true })
        .height(38)
        .fontColor('#FFFFFF')
        .backgroundColor('#4A90E2')
        .borderRadius(12)
        .onClick(() => this.createCharacter())
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private refreshIndicatorOpacity(): number {
    if (this.refreshing) {
      return 1;
    }
    return Math.min(1, this.refreshOffset / CHARACTER_BROWSER_REFRESH_TRIGGER_OFFSET);
  }

  private refresh(forceRefresh: boolean = false): void {
    if (!forceRefresh) {
      this.applyItems(this.service.cachedList());
      this.loading = !this.service.hasCachedList();
      return;
    }
    const startedAt = Date.now();
    this.refreshing = true;
    this.service.refreshCacheAsync().then((items: CharacterBrowserItem[]) => {
      this.applyItems(items);
      this.loading = false;
    }).catch((_err: Error) => {
      this.loading = false;
      this.onToast('读取角色卡失败。');
    }).finally(() => {
      const remainingMs = Math.max(0, CHARACTER_BROWSER_REFRESH_MIN_MS - (Date.now() - startedAt));
      setTimeout(() => this.refreshing = false, remainingMs);
    });
  }

  private openDetail(item: CharacterBrowserItem): void {
    this.service.get(this.backendUrl, item.avatar).then((full: CharacterBrowserItem) => {
      this.detail = full;
      this.onDetailChange(true);
    }).catch((_err: Error) => {
      this.onToast('读取角色详情失败。');
    });
  }

  private toggleFavorite(item: CharacterBrowserItem): void {
    for (const candidate of this.items) {
      if (candidate.id === item.id) {
        candidate.favorite = item.favorite;
        break;
      }
    }
    this.updateDataSource();
    const pendingTimer = this.favoriteTimers.get(item.id);
    if (pendingTimer !== undefined) {
      clearTimeout(pendingTimer);
    }
    const timer = setTimeout(() => {
      this.favoriteTimers.delete(item.id);
      this.persistFavorite(item);
    }, CHARACTER_BROWSER_FAVORITE_DEBOUNCE_MS);
    this.favoriteTimers.set(item.id, timer);
  }

  private persistFavorite(item: CharacterBrowserItem): void {
    this.service.setFavorite(this.backendUrl, item.avatar, item.favorite).then((success: boolean) => {
      if (success) {
        this.onWebMutation('refresh', item.avatar).catch((_err: Error) => {
        });
      }
    }).catch((_err: Error) => {
      });
  }

  private confirmDelete(item: CharacterBrowserItem): void {
    AlertDialog.show({
      title: '删除角色',
      message: `确定删除「${item.name}」吗？相关聊天记录也会删除。`,
      autoCancel: true,
      primaryButton: {
        value: '删除',
        action: () => {
          this.onWebMutation('delete', item.avatar).then((result: string) => {
            if (result === 'ok') {
              this.applyItems(this.items.filter((candidate: CharacterBrowserItem): boolean => candidate.id !== item.id));
              this.onToast('角色已删除。');
            } else {
              this.onToast(result === 'cancelled' ? '删除已取消。' : '删除角色失败。');
            }
          }).catch((_err: Error) => this.onToast('删除角色失败。'));
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  private createCharacter(): void {
    let dialog: CustomDialogController | null = null;
    const close = (): void => {
      dialog?.close();
    };
    dialog = new CustomDialogController({
      builder: CharacterBrowserNameDialog({
        title: '新建角色',
        value: '',
        onClose: close,
        onConfirm: (value: string): void => {
          this.service.create(this.backendUrl, value.trim()).then((success: boolean) => {
            if (success) {
              this.onToast('角色已创建。');
              this.onWebMutation('refresh', '').then((result: string) => {
                if (result !== 'ok') {
                  this.onToast('角色已创建，但 WebUI 列表同步失败。');
                }
              }).catch((_err: Error) => {
                this.onToast('角色已创建，但 WebUI 列表同步失败。');
              });
            } else {
              this.onToast('创建角色失败。');
            }
          }).catch((_err: Error) => this.onToast('创建角色失败。'));
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    dialog.open();
  }

  private showImportMenu(): void {
    try {
      const uiContext = this.getUIContext();
      const actions = new CharacterBrowserImportMenuActions();
      actions.fromAlbum = (): void => this.runImportMenuAction(() => this.importFromAlbum());
      actions.fromFiles = (): void => this.runImportMenuAction(() => this.importFromFiles());
      actions.fromUrl = (): void => this.runImportMenuAction(() => this.showUrlImportDialog());
      actions.create = (): void => this.runImportMenuAction(() => this.createCharacter());
      const content = new ComponentContent(uiContext, wrapBuilder(characterBrowserImportMenu), actions);
      this.importMenuContent = content;
      uiContext.getPromptAction().openMenu(content, { id: CHARACTER_BROWSER_IMPORT_MENU_ID }, {
        placement: Placement.BottomRight,
        mask: false,
        backgroundColor: Color.Transparent,
        backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
        onDisappear: (): void => {
          if (this.importMenuContent === content) {
            this.importMenuContent = null;
          }
        }
      }).catch((_err: Error) => {
        if (this.importMenuContent === content) {
          this.importMenuContent = null;
        }
        this.onToast('打开导入菜单失败。');
      });
    } catch (_err) {
      this.onToast('打开导入菜单失败。');
    }
  }

  private runImportMenuAction(action: () => void): void {
    const content = this.importMenuContent;
    this.importMenuContent = null;
    if (content === null) {
      action();
      return;
    }
    this.getUIContext().getPromptAction().closeMenu(content).then(() => action(), () => action());
  }

  private importFromAlbum(): void {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    const mimeTypeFilter = new photoAccessHelper.MimeTypeFilter();
    mimeTypeFilter.mimeTypeArray = ['image/png'];
    options.mimeTypeFilter = mimeTypeFilter;
    new photoAccessHelper.PhotoViewPicker().select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
      if (result.photoUris.length > 0) {
        this.importCharacterUri(result.photoUris[0]);
      }
    }).catch((_err: Error) => this.onToast('打开相册失败。'));
  }

  private importFromFiles(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const documentPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,
      fileSuffixFilters: ['角色卡|.png,.json']
    };
    documentPicker.select(options).then((uris: string[]) => {
      if (uris.length > 0) {
        this.importCharacterUri(uris[0]);
      }
    }).catch((_err: Error) => this.onToast('打开文件管理器失败。'));
  }

  private showUrlImportDialog(): void {
    let dialog: CustomDialogController | null = null;
    const close = (): void => {
      dialog?.close();
    };
    dialog = new CustomDialogController({
      builder: CharacterBrowserNameDialog({
        title: '从 URL 导入',
        value: '',
        placeholder: 'https://example.com/character.png',
        confirmLabel: '导入',
        inputType: InputType.URL,
        onClose: close,
        onConfirm: (value: string): void => this.importCharacterUrl(value)
      }),
      autoCancel: true,
      customStyle: true
    });
    dialog.open();
  }

  private importCharacterUri(uri: string): void {
    this.onToast('正在导入角色卡…');
    this.service.importFromUri(this.backendUrl, uri).then((success: boolean) => {
      this.finishCharacterImport(success);
    }).catch((_err: Error) => this.onToast('导入角色卡失败。'));
  }

  private importCharacterUrl(value: string): void {
    const url = value.trim();
    if (!/^https?:\/\//i.test(url)) {
      this.onToast('请输入有效的 HTTP 或 HTTPS 地址。');
      return;
    }
    this.onToast('正在下载并导入角色卡…');
    this.service.importFromUrl(this.backendUrl, url).then((success: boolean) => {
      this.finishCharacterImport(success);
    }).catch((_err: Error) => this.onToast('从 URL 导入角色卡失败。'));
  }

  private finishCharacterImport(success: boolean): void {
    if (!success) {
      this.onToast('导入失败，请确认文件是有效的 PNG 或 JSON 角色卡。');
      return;
    }
    this.onToast('角色卡已导入。');
    this.onWebMutation('refresh', '').catch((_err: Error) => {
    });
  }

  private navigationMenu(): HdsNavigationMenuContentOptions {
    return {
      value: [
        {
          content: {
            label: '导入或创建角色',
            icon: $r('app.media.ic_public_add'),
            type: IconStyleMode.SMALL,
            componentId: CHARACTER_BROWSER_IMPORT_MENU_ID,
            action: (): void => this.showImportMenu()
          }
        },
        {
          content: {
            label: '关闭角色卡',
            icon: $r('app.media.ic_browser_close'),
            type: IconStyleMode.SMALL,
            action: (): void => this.onClose()
          }
        }
      ]
    };
  }

  private primaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_primary_text');
  }

  private browserBackgroundColor(): ResourceColor {
    return $r('app.color.native_browser_background');
  }

  private chromeColor(): ResourceColor {
    return $r('app.color.native_browser_chrome');
  }

  private cardBorderColor(): ResourceColor {
    return $r('app.color.native_browser_character_card_border');
  }

  private secondaryTextColor(): ResourceColor {
    return $r('app.color.native_browser_character_secondary_text');
  }

  private tagTextColor(): ResourceColor {
    return $r('app.color.native_browser_tag_text');
  }
}

@CustomDialog
struct CharacterBrowserNameDialog {
  controller: CustomDialogController;
  title: string = '';
  value: string = '';
  placeholder: string = '角色名称';
  confirmLabel: string = '创建';
  inputType: InputType = InputType.Normal;
  onClose: () => void = (): void => {
  };
  onConfirm: (value: string) => void = (_value: string): void => {
  };
  @State inputValue: string = '';

  aboutToAppear(): void {
    this.inputValue = this.value;
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18202A')
        .width('100%')
      TextInput({ text: this.inputValue, placeholder: this.placeholder })
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor('#18202A')
        .backgroundColor('#F3F4F6')
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .type(this.inputType)
        .onChange((value: string) => this.inputValue = value)
      Row({ space: 10 }) {
        Button('取消', { stateEffect: true })
          .layoutWeight(1)
          .height(42)
          .fontColor('#18202A')
          .backgroundColor('#F3F4F6')
          .onClick(() => {
            this.onClose();
          })
        Button(this.confirmLabel, { stateEffect: true })
          .layoutWeight(1)
          .height(42)
          .fontColor('#FFFFFF')
          .backgroundColor('#3B82F6')
          .onClick(() => {
            const value = this.inputValue.trim();
            if (value.length === 0) {
              return;
            }
            this.onClose();
            this.onConfirm(value);
          })
      }
      .width('100%')
    }
    .width('82%')
    .constraintSize({ maxWidth: 420 })
    .padding({ left: 22, right: 22, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
