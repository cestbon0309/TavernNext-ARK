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
import { applyCustomPromptPostProcessing } from './PromptPostProcessing';

export class PayloadBuilderRegistry {
  build(source: ChatCompletionSource, payload: JsonRecord): BuiltChatPayload {
    const prepared = source === 'deepseek' ? payload : applyCustomPromptPostProcessing(payload);
    switch (source) {
      case 'openrouter':
        return new OpenRouterPayloadBuilder().build(prepared);
      case 'custom':
        return new CustomPayloadBuilder().build(prepared);
      case 'claude':
        return new ClaudePayloadBuilder().build(prepared);
      case 'makersuite':
        return new GeminiPayloadBuilder(false).build(prepared);
      case 'vertexai':
        return new GeminiPayloadBuilder(true).build(prepared);
      case 'deepseek':
        return new DeepSeekPayloadBuilder().build(payload);
      case 'cohere':
        return new CoherePayloadBuilder().build(prepared);
      case 'moonshot':
        return new MoonshotPayloadBuilder().build(prepared);
      case 'nanogpt':
        return new NanoGptPayloadBuilder().build(prepared);
      case 'chutes':
        return new ChutesPayloadBuilder().build(prepared);
      case 'zai':
        return new ZaiPayloadBuilder().build(prepared);
      case 'groq':
      case 'siliconflow':
      case 'openai':
      default:
        return new OpenAiPayloadBuilder(source).build(prepared);
    }
  }
}
