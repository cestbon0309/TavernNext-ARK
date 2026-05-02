import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asArrayValue, asBooleanValue, asStringValue, setIfPresent } from '../JsonHelpers';
import { OpenAiPayloadBuilder } from './OpenAiPayloadBuilder';
import { omitKeys, setReasoningObject } from './Shared';

export class OpenRouterPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('openrouter').build(payload);
    const body = built.body;
    setIfPresent(body, payload, 'min_p');
    setIfPresent(body, payload, 'top_a');
    setIfPresent(body, payload, 'repetition_penalty');
    setIfPresent(body, payload, 'include_reasoning');
    this.applyTransforms(body, payload);
    this.applyPlugins(body, payload);
    this.applyProvider(body, payload);
    if (asBooleanValue(payload['use_fallback'])) {
      body['route'] = 'fallback';
    }
    const effort = asStringValue(payload['reasoning_effort']);
    if (effort.length > 0 && effort !== 'auto') {
      setReasoningObject(body, effort);
      built.body = omitKeys(body, ['reasoning_effort']);
    }
    return built;
  }

  private applyTransforms(body: JsonRecord, payload: JsonRecord): void {
    if (payload['middleout'] === undefined) {
      return;
    }
    const transforms: JsonArray = [];
    if (asBooleanValue(payload['middleout'])) {
      transforms.push('middle-out');
    }
    body['transforms'] = transforms;
  }

  private applyPlugins(body: JsonRecord, payload: JsonRecord): void {
    if (!asBooleanValue(payload['enable_web_search'])) {
      return;
    }
    const plugin = emptyJsonRecord();
    plugin['id'] = 'web';
    body['plugins'] = [plugin];
  }

  private applyProvider(body: JsonRecord, payload: JsonRecord): void {
    const provider = emptyJsonRecord();
    if (payload['provider'] !== undefined) {
      provider['order'] = payload['provider'];
    }
    if (payload['allow_fallbacks'] !== undefined) {
      provider['allow_fallbacks'] = asBooleanValue(payload['allow_fallbacks'], true);
    }
    const quantizations = asArrayValue(payload['quantizations']);
    if (quantizations.length > 0) {
      provider['quantizations'] = quantizations;
    }
    if (Object.keys(provider).length > 0) {
      body['provider'] = provider;
    }
  }
}
