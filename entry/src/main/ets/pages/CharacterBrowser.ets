import { CharacterBrowserChatItem, CharacterBrowserItem, CharacterBrowserService } from '../backend/CharacterBrowserService';

const CHARACTER_BROWSER_ANIMATION_MS = 220;
const CHARACTER_BROWSER_ROW_HEIGHT = 124;
const CHARACTER_BROWSER_DELETE_WIDTH = 80;
const CHARACTER_BROWSER_SEARCH_SIZE = 42;

type CharacterItemAction = (item: CharacterBrowserItem) => void;
type CharacterChatAction = (item: CharacterBrowserItem, fileName?: string) => void;
type CharacterToastAction = (message: string) => void;
type CharacterSaveAction = (item: CharacterBrowserItem) => void;
type CharacterDetailStateAction = (open: boolean) => void;
type CharacterDetailBackAction = () => boolean;
type CharacterDetailDirtyAction = (dirty: boolean) => void;
type CharacterWebMutationAction = (action: string, avatar: string, value?: string) => Promise<string>;

@Component
export struct CharacterBrowserCard {
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @Prop item: CharacterBrowserItem = new CharacterBrowserItem();
  @Prop darkMode: boolean = false;
  @Prop grid: boolean = false;
  @State swipeProgress: number = 0;
  onOpen: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };
  onDelete: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };
  onFavorite: CharacterItemAction = (_item: CharacterBrowserItem): void => {
  };

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
            Text(this.item.favorite ? '★' : '☆')
              .fontSize(21)
              .fontColor(this.item.favorite ? '#F6C744' : this.secondaryTextColor())
          }
          .width(34)
          .height(34)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.onFavorite(this.item))
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
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
    .shadow({ radius: 8, color: this.shadowColor(), offsetX: 0, offsetY: 2 })
    .onClick(() => this.onOpen(this.item))
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private gridCard() {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(this.avatarBadgeText())
          .width('100%')
          .aspectRatio(1)
          .textAlign(TextAlign.Center)
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor(this.avatarBadgeColor())
          .borderRadius(14)
        Image(this.avatarUrl())
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text(this.item.favorite ? '★' : '☆')
            .fontSize(19)
            .fontColor(this.item.favorite ? '#F6C744' : '#FFFFFF')
        }
        .width(34)
        .height(34)
        .padding(0)
        .margin({ top: 8, right: 8 })
        .backgroundColor('rgba(0,0,0,0.34)')
        .onClick(() => this.onFavorite(this.item))
      }
      .width('100%')
      .onClick(() => this.onOpen(this.item))

      Text(this.item.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 5 }) {
        ForEach(this.item.tags.slice(0, 2), (tag: string) => {
          Text(tag)
            .fontSize(10)
            .fontColor(this.tagTextColor())
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.tagBackgroundColor())
            .borderRadius(10)
        }, (tag: string) => tag)
        Blank()
        Text(this.formatBytes(this.item.chatSizeBytes))
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
      }
      .width('100%')
    }
    .width('48%')
    .padding(10)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
    .shadow({ radius: 7, color: this.shadowColor(), offsetX: 0, offsetY: 2 })
    .margin({ bottom: 10 })
  }

  private avatarBadgeText(): string {
    const trimmed = this.item.name.trim();
    const badgeSource = trimmed.startsWith('UI Audit ') ? trimmed.slice(9) : trimmed;
    return badgeSource.length > 0 ? badgeSource.slice(0, 1).toUpperCase() : '角';
  }

  private avatarBadgeColor(): string {
    return this.darkMode ? '#3B82F6' : '#4A90E2';
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

  private primaryTextColor(): string {
    return this.darkMode ? '#F7F7FA' : '#0A0A0A';
  }

  private secondaryTextColor(): string {
    return this.darkMode ? 'rgba(228,228,236,0.72)' : 'rgba(73,78,91,0.70)';
  }

  private cardColor(): string {
    return this.darkMode ? 'rgba(28,28,38,0.50)' : 'rgba(255,255,255,0.35)';
  }

  private cardBorderColor(): string {
    return this.darkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)';
  }

  private shadowColor(): string {
    return this.darkMode ? 'rgba(0,0,0,0.22)' : 'rgba(0,0,0,0.10)';
  }

  private tagTextColor(): string {
    return this.darkMode ? '#9BC4FF' : '#356FB3';
  }

  private tagBackgroundColor(): string {
    return this.darkMode ? 'rgba(59,130,246,0.18)' : 'rgba(74,144,226,0.12)';
  }

  private tagBorderColor(): string {
    return this.darkMode ? 'rgba(147,197,253,0.18)' : 'rgba(74,144,226,0.16)';
  }
}

@Component
export struct CharacterBrowserDetail {
  @Prop item: CharacterBrowserItem = new CharacterBrowserItem();
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @Prop darkMode: boolean = false;
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
  private initialSignature: string = '';
  private service: CharacterBrowserService = new CharacterBrowserService();
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
    .backgroundColor(this.browserBackgroundColor())
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private detailHeader() {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text('‹')
          .fontSize(30)
          .fontColor(this.primaryTextColor())
      }
      .width(42)
      .height(42)
      .padding(0)
      .backgroundColor(this.chromeColor())
      .onClick(() => {
        if (this.onBackRequest()) {
          this.onBack();
        }
      })

      Text(this.name.length > 0 ? this.name : '角色详情')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text(this.favorite ? '★' : '☆')
          .fontSize(22)
          .fontColor(this.favorite ? '#F6C744' : this.secondaryTextColor())
      }
      .width(42)
      .height(42)
      .padding(0)
      .backgroundColor(this.chromeColor())
      .onClick(() => {
        this.favorite = !this.favorite;
        this.markDirty();
      })

      Button('保存', { stateEffect: true })
        .height(42)
        .padding({ left: 16, right: 16 })
        .fontColor('#FFFFFF')
        .backgroundColor('#4A90E2')
        .borderRadius(14)
        .enabled(!this.saving)
        .onClick(() => this.save())
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.headerColor())
    .border({ width: { bottom: 1 }, color: this.cardBorderColor() })
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
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
      this.actionButton('开始聊天', () => this.onOpenChat(this.currentItem()))
      this.actionButton('导出 PNG', () => this.exportCard('png'))
      this.actionButton('导出 JSON', () => this.exportCard('json'))
      this.actionButton('复制角色', () => this.duplicateCard())
      this.actionButton('删除角色', () => this.deleteCard())
    }
    .width('100%')
  }

  @Builder
  private actionButton(label: string, action: () => void) {
    Button(label, { stateEffect: true })
      .height(42)
      .padding({ left: 12, right: 12 })
      .fontSize(12)
      .fontColor(label === '删除角色' ? '#E14D5A' : this.primaryTextColor())
      .backgroundColor(label === '开始聊天' ? 'rgba(74,144,226,0.18)' : this.cardColor())
      .border({ width: 1, color: label === '删除角色' ? 'rgba(225,77,90,0.28)' : this.cardBorderColor() })
      .borderRadius(12)
      .onClick(action)
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
      this.sectionHeader('创作者笔记', this.expandedCreator, () => this.expandedCreator = !this.expandedCreator)
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
      this.sectionHeader('高级设定', this.expandedAdvanced, () => this.expandedAdvanced = !this.expandedAdvanced)
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
      this.sectionHeader(`备选问候语 (${this.alternateGreetings.length})`, this.expandedGreetings,
        () => this.expandedGreetings = !this.expandedGreetings)
      if (this.expandedGreetings) {
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
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardColor())
    .border({ width: 1, color: this.cardBorderColor() })
    .borderRadius(14)
  }

  @Builder
  private sectionHeader(title: string, expanded: boolean, action: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .layoutWeight(1)
      Text(expanded ? '⌃' : '⌄')
        .fontSize(21)
        .fontColor(this.secondaryTextColor())
    }
    .width('100%')
    .height(32)
    .onClick(action)
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
      this.alternateGreetings,
      this.favorite
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

  private avatarBadgeColor(): string {
    return this.darkMode ? '#3B82F6' : '#4A90E2';
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

  private browserBackgroundColor(): string {
    return this.darkMode ? '#15151C' : '#F5F7FA';
  }

  private headerColor(): string {
    return this.darkMode ? '#282832' : '#E8EBEF';
  }

  private chromeColor(): string {
    return this.darkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)';
  }

  private inputColor(): string {
    return this.darkMode ? 'rgba(30,30,42,0.72)' : 'rgba(243,243,245,0.84)';
  }

  private cardColor(): string {
    return this.darkMode ? 'rgba(28,28,38,0.50)' : 'rgba(255,255,255,0.36)';
  }

  private cardBorderColor(): string {
    return this.darkMode ? 'rgba(255,255,255,0.09)' : 'rgba(0,0,0,0.06)';
  }

  private primaryTextColor(): string {
    return this.darkMode ? '#F7F7FA' : '#0A0A0A';
  }

  private secondaryTextColor(): string {
    return this.darkMode ? 'rgba(228,228,236,0.70)' : 'rgba(73,78,91,0.70)';
  }

  private tagTextColor(): string {
    return this.darkMode ? '#9BC4FF' : '#356FB3';
  }

  private tagBackgroundColor(): string {
    return this.darkMode ? 'rgba(59,130,246,0.18)' : 'rgba(74,144,226,0.12)';
  }

  private tagBorderColor(): string {
    return this.darkMode ? 'rgba(147,197,253,0.18)' : 'rgba(74,144,226,0.16)';
  }
}

@Component
export struct CharacterBrowserPanel {
  @Prop backendUrl: string = 'http://127.0.0.1:8000';
  @Prop darkMode: boolean = false;
  @Prop detailOpen: boolean = false;
  @State items: CharacterBrowserItem[] = [];
  @State query: string = '';
  @State activeFilter: string = 'all';
  @State sortMode: string = 'name';
  @State gridMode: boolean = false;
  @State refreshing: boolean = false;
  @State loading: boolean = true;
  @State searchCollapsed: boolean = false;
  @State detail: CharacterBrowserItem | null = null;
  private service: CharacterBrowserService = new CharacterBrowserService();
  onClose: () => void = (): void => {
  };
  onToggleTheme: () => void = (): void => {
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
    this.refresh();
  }

  build() {
    if (this.detail !== null && this.detailOpen) {
      CharacterBrowserDetail({
        item: this.detail,
        backendUrl: this.backendUrl,
        darkMode: this.darkMode,
        onBack: (): void => {
          this.detail = null;
          this.onDetailChange(false);
          this.refresh();
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
          this.refresh();
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
    Column() {
      this.header()
      this.filterBar()
      this.resultToolbar()
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
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.displayedItems().length === 0) {
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
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.gridMode) {
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween,
            alignItems: ItemAlign.Start, alignContent: FlexAlign.Start }) {
            ForEach(this.displayedItems(), (item: CharacterBrowserItem) => {
              CharacterBrowserCard({
                item,
                darkMode: this.darkMode,
                backendUrl: this.backendUrl,
                grid: true,
                onOpen: (selected: CharacterBrowserItem): void => this.openDetail(selected),
                onFavorite: (selected: CharacterBrowserItem): void => this.toggleFavorite(selected)
              })
            }, (item: CharacterBrowserItem) => item.id)
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .padding({ left: 16, right: 16, top: 12, bottom: 26 })
        }
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Refresh({ refreshing: $$this.refreshing, offset: 48 }) {
          List({ space: 10 }) {
            ForEach(this.displayedItems(), (item: CharacterBrowserItem) => {
              CharacterBrowserCard({
                item,
                darkMode: this.darkMode,
                backendUrl: this.backendUrl,
                grid: false,
                onOpen: (selected: CharacterBrowserItem): void => this.openDetail(selected),
                onDelete: (selected: CharacterBrowserItem): void => this.confirmDelete(selected),
                onFavorite: (selected: CharacterBrowserItem): void => this.toggleFavorite(selected)
              })
            }, (item: CharacterBrowserItem) => item.id)
          }
          .width('100%')
          .edgeEffect(EdgeEffect.Spring)
        }
        .layoutWeight(1)
        .pullToRefresh(true)
        .onRefreshing(() => this.refresh())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.browserBackgroundColor())
    .animation({ duration: CHARACTER_BROWSER_ANIMATION_MS, curve: Curve.EaseInOut })
  }

  @Builder
  private header() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Row()
          .width('100%')
          .height(this.searchCollapsed ? 64 : 132)
          .backgroundColor(this.headerColor())
          .border({ width: { bottom: 1 }, color: this.cardBorderColor() })
          .animation({ duration: 360, curve: Curve.FastOutSlowIn })
      }

      Row() {
        Column({ space: 2 }) {
          Text('角色卡')
            .fontSize(28)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(`${this.items.length} 个角色`)
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text('◐')
            .fontSize(20)
            .fontColor(this.primaryTextColor())
        }
        .width(42)
        .height(42)
        .padding(0)
        .backgroundColor(this.chromeColor())
        .onClick(() => this.onToggleTheme())
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text('＋')
            .fontSize(24)
            .fontColor(this.tagTextColor())
        }
        .width(42)
        .height(42)
        .padding(0)
        .backgroundColor(this.chromeColor())
        .onClick(() => this.createCharacter())
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text('×')
            .fontSize(24)
            .fontColor(this.primaryTextColor())
        }
        .width(42)
        .height(42)
        .padding(0)
        .backgroundColor(this.chromeColor())
        .onClick(() => this.onClose())
      }
      .width('100%')
      .height(46)
      .padding({ left: 20, right: 20 })
      .position({ x: 0, y: 10 })

      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row()
            .width('100%')
            .height(CHARACTER_BROWSER_SEARCH_SIZE)
            .backgroundColor(this.chromeColor())
            .borderRadius(21)
            .border({ width: 1, color: this.cardBorderColor() })
          TextInput({ placeholder: '搜索角色名称或描述', text: this.query })
            .width('100%')
            .height(CHARACTER_BROWSER_SEARCH_SIZE)
            .fontSize(15)
            .fontColor(this.primaryTextColor())
            .placeholderColor(this.secondaryTextColor())
            .backgroundColor(Color.Transparent)
            .padding({ left: 42, right: 12 })
            .opacity(this.searchCollapsed ? 0 : 1)
            .enabled(!this.searchCollapsed)
            .onChange((value: string) => this.query = value)
          Image($r('app.media.ic_public_search'))
            .width(20)
            .height(20)
            .fillColor(this.secondaryTextColor())
            .position({ x: this.searchCollapsed ? 11 : 14, y: 11 })
        }
        .layoutWeight(1)
        .height(CHARACTER_BROWSER_SEARCH_SIZE)
        .onClick(() => {
          if (this.searchCollapsed) {
            this.searchCollapsed = false;
          }
        })
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Text('↻')
            .fontSize(24)
            .fontColor(this.primaryTextColor())
        }
        .width(42)
        .height(42)
        .padding(0)
        .backgroundColor(this.chromeColor())
        .onClick(() => this.refresh())
      }
      .width('100%')
      .height(CHARACTER_BROWSER_SEARCH_SIZE)
      .padding({ left: 20, right: 20 })
      .position({ x: 0, y: 70 })
      .opacity(this.searchCollapsed ? 0 : 1)
      .animation({ duration: 360, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(this.searchCollapsed ? 64 : 132)
    .clip(false)
    .animation({ duration: 360, curve: Curve.FastOutSlowIn })
  }

  @Builder
  private filterBar() {
    Scroll() {
      Row({ space: 8 }) {
        this.filterPill('全部', () => this.activeFilter = 'all')
        this.filterPill('★ 收藏', () => {
          this.activeFilter = this.activeFilter === 'fav' ? 'all' : 'fav';
        })
        if (this.activeFilter !== 'all' || this.query.length > 0) {
          this.filterPill('× 清除', () => {
            this.activeFilter = 'all';
            this.query = '';
          });
        }
        ForEach(this.allTags(), (tag: string) => {
          this.filterPill(tag, () => {
            this.activeFilter = this.activeFilter === tag ? 'all' : tag;
          });
        }, (tag: string) => tag)
      }
      .padding({ left: 20, right: 20 })
    }
    .width('100%')
    .height(42)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
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
    return label !== '× 清除' && this.activeFilter === label;
  }

  @Builder
  private resultToolbar() {
    Row() {
      Text(`${this.displayedItems().length} 个结果`)
        .fontSize(13)
        .fontColor(this.secondaryTextColor())
      Blank()
      Button(this.sortLabel(), { stateEffect: true })
        .height(32)
        .fontSize(12)
        .fontColor(this.secondaryTextColor())
        .backgroundColor(this.chromeColor())
        .border({ width: 1, color: this.cardBorderColor() })
        .borderRadius(9)
        .onClick(() => this.cycleSort())
      Button(this.gridMode ? '列表' : '网格', { stateEffect: true })
        .height(32)
        .fontSize(12)
        .fontColor(this.tagTextColor())
        .backgroundColor(this.chromeColor())
        .border({ width: 1, color: this.cardBorderColor() })
        .borderRadius(9)
        .onClick(() => this.gridMode = !this.gridMode)
    }
    .width('100%')
    .height(44)
    .padding({ left: 20, right: 20 })
  }

  private displayedItems(): CharacterBrowserItem[] {
    let result = this.items.filter((item: CharacterBrowserItem): boolean => {
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

  private sortLabel(): string {
    if (this.sortMode === 'chatCount') {
      return '按聊天数';
    }
    if (this.sortMode === 'created') {
      return '按时间';
    }
    return '按名称';
  }

  private cycleSort(): void {
    this.sortMode = this.sortMode === 'name' ? 'chatCount' : this.sortMode === 'chatCount' ? 'created' : 'name';
  }

  private refresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.service.list(this.backendUrl).then((items: CharacterBrowserItem[]) => {
      this.items = items;
      this.loading = false;
    }).catch((_err: Error) => {
      this.loading = false;
      this.onToast('读取角色卡失败。');
    }).finally(() => {
      setTimeout(() => this.refreshing = false, 420);
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
    const updated = item.clone();
    updated.favorite = !updated.favorite;
    this.service.setFavorite(this.backendUrl, updated.avatar, updated.favorite).then((success: boolean) => {
      if (!success) {
        this.onToast('收藏状态保存失败。');
        return;
      }
      this.items = this.items.map((candidate: CharacterBrowserItem): CharacterBrowserItem => {
        return candidate.id === item.id ? updated : candidate;
      });
      this.onWebMutation('refresh', updated.avatar).then((result: string) => {
        if (result !== 'ok') {
          this.onToast('收藏已保存，但 WebUI 列表同步失败。');
        }
      }).catch((_err: Error) => {
        this.onToast('收藏已保存，但 WebUI 列表同步失败。');
      });
    }).catch((_err: Error) => this.onToast('收藏状态保存失败。'));
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
              this.items = this.items.filter((candidate: CharacterBrowserItem): boolean => candidate.id !== item.id);
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
              this.refresh();
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

  private primaryTextColor(): string {
    return this.darkMode ? '#F7F7FA' : '#0A0A0A';
  }

  private browserBackgroundColor(): string {
    return this.darkMode ? '#15151C' : '#F5F7FA';
  }

  private headerColor(): string {
    return this.darkMode ? '#282832' : '#E8EBEF';
  }

  private chromeColor(): string {
    return this.darkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)';
  }

  private cardBorderColor(): string {
    return this.darkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.06)';
  }

  private secondaryTextColor(): string {
    return this.darkMode ? 'rgba(228,228,236,0.70)' : 'rgba(73,78,91,0.70)';
  }

  private tagTextColor(): string {
    return this.darkMode ? '#9BC4FF' : '#356FB3';
  }
}

@CustomDialog
struct CharacterBrowserNameDialog {
  controller: CustomDialogController;
  title: string = '';
  value: string = '';
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
      TextInput({ text: this.inputValue, placeholder: '角色名称' })
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor('#18202A')
        .backgroundColor('#F3F4F6')
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
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
        Button('创建', { stateEffect: true })
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
