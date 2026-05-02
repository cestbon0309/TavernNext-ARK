import { JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asStringValue, setIfPresent } from '../JsonHelpers';
import {
  buildResponseFormatFromJsonSchema,
  copyKeys,
  copyLogprobs,
  isOpenAiReasoningModel,
  messagesToPrompt,
  normalizeReasoningEffort,
} from './Shared';

const CHAT_KEYS: string[] = [
  'messages',
  'model',
  'temperature',
  'max_tokens',
  'max_completion_tokens',
  'stream',
  'presence_penalty',
  'frequency_penalty',
  'top_p',
  'top_k',
  'stop',
  'logit_bias',
  'seed',
  'n',
  'user',
  'tools',
  'tool_choice',
];

const TEXT_KEYS: string[] = [
  'model',
  'prompt',
  'suffix',
  'max_tokens',
  'temperature',
  'top_p',
  'n',
  'stream',
  'logprobs',
  'echo',
  'stop',
  'presence_penalty',
  'frequency_penalty',
  'best_of',
  'logit_bias',
  'user',
  'seed',
];

const LEGACY_COMPLETION_MODELS: string[] = [
  'text-davinci-003',
  'text-davinci-002',
  'text-curie-001',
  'text-babbage-001',
  'text-ada-001',
  'davinci-002',
  'babbage-002',
  'gpt-3.5-turbo-instruct',
];

export class OpenAiPayloadBuilder {
  private source: string;

  constructor(source: string = 'openai') {
    this.source = source;
  }

  build(payload: JsonRecord): BuiltChatPayload {
    if (this.isTextCompletion(payload)) {
      return new BuiltChatPayload('/completions', this.buildTextCompletionPayload(payload));
    }
    return new BuiltChatPayload('/chat/completions', this.buildChatCompletionPayload(payload));
  }

  private buildChatCompletionPayload(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    copyKeys(request, payload, CHAT_KEYS);
    copyLogprobs(request, payload);
    const responseFormat = buildResponseFormatFromJsonSchema(payload);
    if (responseFormat !== null) {
      request['response_format'] = responseFormat;
    }
    this.setOpenAiReasoningFields(request, payload);
    return request;
  }

  private buildTextCompletionPayload(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    copyKeys(request, payload, TEXT_KEYS);
    if (request['prompt'] === undefined) {
      request['prompt'] = messagesToPrompt(payload['messages']);
    }
    return request;
  }

  private isTextCompletion(payload: JsonRecord): boolean {
    if (typeof payload['messages'] === 'string') {
      return true;
    }
    const model = asStringValue(payload['model']).trim().toLowerCase();
    return model.startsWith('text-') || LEGACY_COMPLETION_MODELS.includes(model);
  }

  private setOpenAiReasoningFields(request: JsonRecord, payload: JsonRecord): void {
    const model = asStringValue(payload['model']);
    const effort = asStringValue(payload['reasoning_effort']).trim();
    if ((this.source === 'openai' || this.source === 'custom') && effort.length > 0 && effort !== 'auto' &&
      isOpenAiReasoningModel(model)) {
      request['reasoning_effort'] = normalizeReasoningEffort(effort);
    }
    if (model.trim().toLowerCase().startsWith('gpt-5')) {
      setIfPresent(request, payload, 'verbosity');
    }
  }
}
