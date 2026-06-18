export type WebPromptDialogConfirmAction = (value: string) => void;
export type WebPromptDialogCancelAction = () => void;
export type WebPromptDialogShowAction = (message: string, value: string, onConfirm: WebPromptDialogConfirmAction,
  onCancel: WebPromptDialogCancelAction) => void;

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

  handlePrompt(message: string, value: string, showDialog: WebPromptDialogShowAction,
    onConfirm: WebPromptDialogConfirmAction, onCancel: WebPromptDialogCancelAction): void {
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
    showDialog(message, value, confirmOnce, cancelOnce);
  }
}
