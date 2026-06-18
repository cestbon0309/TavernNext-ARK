type WebPromptDialogConfirmAction = (value: string) => void;
type WebPromptDialogCancelAction = () => void;

@CustomDialog
struct WebPromptDialog {
  controller: CustomDialogController;
  title: string = '';
  message: string = '';
  value: string = '';
  onConfirm: WebPromptDialogConfirmAction = (_value: string): void => {
  };
  onCancel: WebPromptDialogCancelAction = (): void => {
  };
  @State inputValue: string = '';

  aboutToAppear(): void {
    this.inputValue = this.value;
  }

  build() {
    Column({ space: 16 }) {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18202A')
        .width('100%')

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(15)
          .fontColor('#4B5563')
          .width('100%')
      }

      TextInput({ text: this.inputValue })
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor('#18202A')
        .backgroundColor('#F3F4F6')
        .borderRadius(10)
        .border({ width: 1, color: '#D1D5DB' })
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.inputValue = value;
        })

      Row({ space: 12 }) {
        Button('取消', { stateEffect: true })
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#F3F4F6')
          .fontColor('#18202A')
          .onClick(() => {
            this.onCancel();
            this.controller.close();
          })

        Button('确定', { stateEffect: true })
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#3B82F6')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.onConfirm(this.inputValue);
            this.controller.close();
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

export class WebDialogService {
  handleAlert(message: string, onConfirm: () => void): void {
    AlertDialog.show({
      title: '提示',
      message,
      autoCancel: false,
      primaryButton: {
        value: '确定',
        action: onConfirm
      }
    });
  }

  handleConfirm(message: string, onConfirm: () => void, onCancel: () => void): void {
    let handled = false;
    const confirmOnce = (): void => {
      if (handled) {
        return;
      }
      handled = true;
      onConfirm();
    };
    const cancelOnce = (): void => {
      if (handled) {
        return;
      }
      handled = true;
      onCancel();
    };
    AlertDialog.show({
      title: '确认',
      message,
      autoCancel: true,
      cancel: cancelOnce,
      primaryButton: {
        value: '确定',
        action: confirmOnce
      },
      secondaryButton: {
        value: '取消',
        action: cancelOnce
      }
    });
  }

  handlePrompt(message: string, value: string, onConfirm: WebPromptDialogConfirmAction,
    onCancel: WebPromptDialogCancelAction): void {
    let handled = false;
    const confirmOnce = (input: string): void => {
      if (handled) {
        return;
      }
      handled = true;
      onConfirm(input);
    };
    const cancelOnce = (): void => {
      if (handled) {
        return;
      }
      handled = true;
      onCancel();
    };
    const dialog = new CustomDialogController({
      builder: WebPromptDialog({
        title: '输入',
        message,
        value,
        onConfirm: confirmOnce,
        onCancel: cancelOnce
      }),
      autoCancel: true,
      cancel: cancelOnce,
      customStyle: true
    });
    dialog.open();
  }
}
