import { HttpResponse, HttpStreamSend, JsonArray, JsonRecord } from '../HttpTypes';

export type ChatJsonValue = Object | string | number | boolean | null | JsonArray;

export type ChatCompletionSource =
  'openai' | 'openrouter' | 'custom' | 'claude' | 'makersuite' | 'vertexai' |
  'deepseek' | 'cohere' | 'groq' | 'moonshot' | 'nanogpt' | 'chutes' |
  'siliconflow' | 'zai';

export type AnthropicBetaHeaderMode = 'none' | 'prompt_caching_only' | 'claude_defaults';

export class ChatCompletionApiConfig {
  baseUrl: string = '';
  apiKey: string = '';
  authorizationHeader: string = '';
  extraHeaders: Record<string, string> = {};
  anthropicBetaHeaderMode: AnthropicBetaHeaderMode = 'none';
  requiresKey: boolean = true;
}

export class BuiltChatPayload {
  endpointPath: string;
  body: JsonRecord;

  constructor(endpointPath: string, body: JsonRecord) {
    this.endpointPath = endpointPath;
    this.body = body;
  }
}

export type ChatStreamSend = HttpStreamSend;

export interface ChatPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload;
}

export interface ChatCompletionTransport {
  listModels(source: ChatCompletionSource, config: ChatCompletionApiConfig): Promise<HttpResponse>;
  generate(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord): Promise<HttpResponse>;
  generateStream(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord, send: ChatStreamSend): Promise<void>;
}

export class ChatProviderError extends Error {
  statusCode: number;

  constructor(message: string, statusCode: number = 500) {
    super(message);
    this.statusCode = statusCode;
  }
}
