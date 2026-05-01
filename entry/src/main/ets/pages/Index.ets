import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BackendService, BackendStatus } from '../backend/BackendService';

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State url: string = 'http://127.0.0.1:8000';
  @State pageError: string = '';
  @State message: string = 'Starting ArkTS backend...';
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    webview.WebviewController.setWebDebuggingAccess(true);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const service = BackendService.getInstance(context);
    service.start().then((status: BackendStatus) => {
      this.applyStatus(status);
    });
  }

  private applyStatus(status: BackendStatus): void {
    this.running = status.running;
    this.url = status.url;
    this.message = status.message;
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
          .onPageBegin(() => {
            this.pageError = '';
          })
          .onErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.pageError = `WebView failed to load SillyTavern: ${event.error.getErrorInfo()}`;
            }
          })
          .onHttpErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.pageError = 'SillyTavern page returned an HTTP error.';
            }
          })
      } else {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(48)
            .height(48)
          Text(this.message)
            .fontSize(16)
            .fontColor('#333333')
        }
        .width('100%')
        .height('100%')
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
  }
}
