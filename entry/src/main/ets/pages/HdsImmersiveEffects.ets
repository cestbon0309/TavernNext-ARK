import { hdsEffect } from '@kit.UIDesignKit';

export class HdsImmersiveEffects {
  static search(darkMode: boolean): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER,
        options: {
          color: darkMode ? 'rgba(132,188,255,0.62)' : 'rgba(54,132,246,0.46)',
          intensity: darkMode ? 0.18 : 0.12,
          height: 28,
          bloom: darkMode ? 0.06 : 0.04
        }
      })
      .buildEffect();
  }
}
