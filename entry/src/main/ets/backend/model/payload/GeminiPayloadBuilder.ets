import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import {
  asArrayValue,
  asBooleanValue,
  asRecordValue,
  asStringValue,
  messageContentToText,
  parseDataUrl,
  setIfPresent,
} from '../JsonHelpers';
import { buildResponseFormatFromJsonSchema, openAiToolDeclarations } from './Shared';

export class GeminiPayloadBuilder {
  private vertexAi: boolean = false;

  constructor(vertexAi: boolean = false) {
    this.vertexAi = vertexAi;
  }

  build(payload: JsonRecord): BuiltChatPayload {
    const body = this.buildGeminiBody(payload);
    const model = encodeURIComponent(asStringValue(payload['model']));
    const method = asBooleanValue(payload['stream']) ? 'streamGenerateContent?alt=sse' : 'generateContent';
    const endpoint = this.vertexAi ? `/publishers/google/models/${model}:${method}` : `/v1beta/models/${model}:${method}`;
    return new BuiltChatPayload(endpoint, body);
  }

  private buildGeminiBody(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    const system = this.systemInstruction(payload);
    if (system.length > 0) {
      const systemInstruction = emptyJsonRecord();
      systemInstruction['parts'] = [this.textPart(system)];
      request['systemInstruction'] = systemInstruction;
    }
    request['contents'] = this.contents(payload);
    const generationConfig = this.generationConfig(payload);
    if (Object.keys(generationConfig).length > 0) {
      request['generationConfig'] = generationConfig;
    }
    const tools = this.tools(payload);
    if (tools.length > 0) {
      request['tools'] = tools;
    }
    return request;
  }

  private systemInstruction(payload: JsonRecord): string {
    const lines: string[] = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      if (asStringValue(message['role']) === 'system') {
        lines.push(messageContentToText(message['content']));
      }
    }
    return lines.join('\n');
  }

  private contents(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']);
      if (role === 'system') {
        continue;
      }
      const next = emptyJsonRecord();
      next['role'] = role === 'assistant' ? 'model' : 'user';
      next['parts'] = role === 'tool' ? this.functionResponseParts(message) : this.parts(message['content']);
      this.mergeAdjacent(result, next);
    }
    if (result.length === 0) {
      const fallback = emptyJsonRecord();
      fallback['role'] = 'user';
      fallback['parts'] = [this.textPart('')];
      result.push(fallback);
    }
    return result;
  }

  private parts(content: Object | string | number | boolean | null | JsonArray | undefined): JsonArray {
    if (!Array.isArray(content)) {
      return [this.textPart(messageContentToText(content))];
    }
    const result: JsonArray = [];
    const parts: JsonArray = content;
    for (let index = 0; index < parts.length; index += 1) {
      const item: Object | string | number | boolean | null = parts[index];
      if (typeof item === 'string') {
        result.push(this.textPart(item));
        continue;
      }
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      if (asStringValue(record['type']) === 'image_url') {
        const imageUrl = asRecordValue(record['image_url']);
        const dataUrl = parseDataUrl(asStringValue(imageUrl['url']));
        if (dataUrl !== null) {
          const inlineData = emptyJsonRecord();
          inlineData['mimeType'] = asStringValue(dataUrl['mimeType']);
          inlineData['data'] = asStringValue(dataUrl['data']);
          const part = emptyJsonRecord();
          part['inlineData'] = inlineData;
          result.push(part);
        }
        continue;
      }
      result.push(this.textPart(messageContentToText(record['text'] ?? record['content'])));
    }
    return result.length > 0 ? result : [this.textPart('')];
  }

  private functionResponseParts(message: JsonRecord): JsonArray {
    const response = emptyJsonRecord();
    response['name'] = asStringValue(message['name']) || asStringValue(message['tool_call_id']);
    const body = emptyJsonRecord();
    body['content'] = messageContentToText(message['content']);
    response['response'] = body;
    const part = emptyJsonRecord();
    part['functionResponse'] = response;
    return [part];
  }

  private textPart(text: string): JsonRecord {
    const part = emptyJsonRecord();
    part['text'] = text.length > 0 ? text : ' ';
    return part;
  }

  private mergeAdjacent(contents: JsonArray, next: JsonRecord): void {
    if (contents.length === 0) {
      contents.push(next);
      return;
    }
    const last = contents[contents.length - 1];
    if (last !== null && !Array.isArray(last) && typeof last === 'object' &&
      asStringValue((last as JsonRecord)['role']) === asStringValue(next['role'])) {
      const parts = asArrayValue((last as JsonRecord)['parts']);
      for (const part of asArrayValue(next['parts'])) {
        parts.push(part);
      }
      (last as JsonRecord)['parts'] = parts;
      return;
    }
    contents.push(next);
  }

  private generationConfig(payload: JsonRecord): JsonRecord {
    const config = emptyJsonRecord();
    setIfPresent(config, payload, 'temperature');
    if (payload['top_p'] !== undefined) {
      config['topP'] = payload['top_p'];
    }
    if (payload['top_k'] !== undefined) {
      config['topK'] = payload['top_k'];
    }
    const maxTokens = payload['max_tokens'] ?? payload['max_completion_tokens'];
    if (maxTokens !== undefined) {
      config['maxOutputTokens'] = maxTokens;
    }
    if (payload['stop'] !== undefined) {
      config['stopSequences'] = payload['stop'];
    }
    const responseFormat = buildResponseFormatFromJsonSchema(payload);
    if (responseFormat !== null) {
      config['responseMimeType'] = 'application/json';
      const schema = asRecordValue(asRecordValue(responseFormat['json_schema'])['schema']);
      if (Object.keys(schema).length > 0) {
        config['responseSchema'] = schema;
      }
    }
    if (payload['include_reasoning'] !== undefined) {
      const thinkingConfig = emptyJsonRecord();
      thinkingConfig['includeThoughts'] = asBooleanValue(payload['include_reasoning']);
      config['thinkingConfig'] = thinkingConfig;
    }
    return config;
  }

  private tools(payload: JsonRecord): JsonArray {
    const declarations = openAiToolDeclarations(payload['tools']);
    if (declarations.length === 0) {
      return [];
    }
    const tool = emptyJsonRecord();
    tool['functionDeclarations'] = declarations;
    return [tool];
  }
}
