import { JsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asBooleanValue, asStringValue, setIfPresent } from '../JsonHelpers';
import { OpenAiPayloadBuilder } from './OpenAiPayloadBuilder';
import { setReasoningObject, setThinkingFlag } from './Shared';

export class MoonshotPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('moonshot').build(payload);
    if (built.endpointPath === '/chat/completions' && payload['include_reasoning'] !== undefined) {
      setThinkingFlag(built.body, asBooleanValue(payload['include_reasoning']));
    }
    return built;
  }
}

export class ZaiPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('zai').build(payload);
    if (built.endpointPath === '/chat/completions' && payload['include_reasoning'] !== undefined) {
      setThinkingFlag(built.body, asBooleanValue(payload['include_reasoning']));
    }
    return built;
  }
}

export class NanoGptPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('nanogpt').build(payload);
    if (built.endpointPath !== '/chat/completions') {
      throw new Error('NanoGPT only supports chat completions.');
    }
    setIfPresent(built.body, payload, 'min_p');
    setIfPresent(built.body, payload, 'top_a');
    setIfPresent(built.body, payload, 'repetition_penalty');
    if (asBooleanValue(payload['enable_web_search'])) {
      const model = asStringValue(built.body['model']);
      if (model.length > 0 && !model.endsWith(':online')) {
        built.body['model'] = `${model}:online`;
      }
    }
    const effort = this.nanoGptReasoningEffort(asStringValue(payload['reasoning_effort']));
    if (effort.length > 0) {
      setReasoningObject(built.body, effort);
    }
    return built;
  }

  private nanoGptReasoningEffort(raw: string): string {
    switch (raw.trim().toLowerCase()) {
      case 'min':
        return 'none';
      case 'low':
        return 'minimal';
      case 'medium':
        return 'low';
      case 'high':
        return 'medium';
      case 'max':
      case 'xhigh':
        return 'high';
      default:
        return '';
    }
  }
}

export class ChutesPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('chutes').build(payload);
    setIfPresent(built.body, payload, 'min_p');
    setIfPresent(built.body, payload, 'repetition_penalty');
    setIfPresent(built.body, payload, 'reasoning_effort');
    return built;
  }
}
