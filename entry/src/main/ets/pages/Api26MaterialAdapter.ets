import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial } from '@kit.UIDesignKit';

export class Api26MaterialAdapter {
  static isSupported(): boolean {
    try {
      return deviceInfo.sdkApiVersion >= 26 && hdsMaterial.getSystemMaterialTypes().length > 0;
    } catch (_err) {
      return false;
    }
  }

  static search(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: { color: undefined }
    });
  }

}
