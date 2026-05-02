import { JsonRecord } from '../../HttpTypes';
import { BuiltChatPayload, ChatCompletionSource } from '../ChatCompletionTypes';
import { ClaudePayloadBuilder } from './ClaudePayloadBuilder';
import { CoherePayloadBuilder } from './CoherePayloadBuilder';
import { CustomPayloadBuilder } from './CustomPayloadBuilder';
import { DeepSeekPayloadBuilder } from './DeepSeekPayloadBuilder';
import { GeminiPayloadBuilder } from './GeminiPayloadBuilder';
import { OpenAiPayloadBuilder } from './OpenAiPayloadBuilder';
import { OpenRouterPayloadBuilder } from './OpenRouterPayloadBuilder';
import {
  ChutesPayloadBuilder,
  MoonshotPayloadBuilder,
  NanoGptPayloadBuilder,
  ZaiPayloadBuilder,
} from './OpenAiCompatiblePayloadBuilders';

export class PayloadBuilderRegistry {
  build(source: ChatCompletionSource, payload: JsonRecord): BuiltChatPayload {
    switch (source) {
      case 'openrouter':
        return new OpenRouterPayloadBuilder().build(payload);
      case 'custom':
        return new CustomPayloadBuilder().build(payload);
      case 'claude':
        return new ClaudePayloadBuilder().build(payload);
      case 'makersuite':
        return new GeminiPayloadBuilder(false).build(payload);
      case 'vertexai':
        return new GeminiPayloadBuilder(true).build(payload);
      case 'deepseek':
        return new DeepSeekPayloadBuilder().build(payload);
      case 'cohere':
        return new CoherePayloadBuilder().build(payload);
      case 'moonshot':
        return new MoonshotPayloadBuilder().build(payload);
      case 'nanogpt':
        return new NanoGptPayloadBuilder().build(payload);
      case 'chutes':
        return new ChutesPayloadBuilder().build(payload);
      case 'zai':
        return new ZaiPayloadBuilder().build(payload);
      case 'groq':
      case 'siliconflow':
      case 'openai':
      default:
        return new OpenAiPayloadBuilder(source).build(payload);
    }
  }
}
