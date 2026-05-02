import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asArrayValue, asStringValue, messageContentToText, setIfPresent } from '../JsonHelpers';
import { applyCustomBodyOverrides } from './Shared';

export class GeminiInteractionsPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    let body = this.buildBody(payload);
    body = applyCustomBodyOverrides(body, asStringValue(payload['custom_include_body']),
      asStringValue(payload['custom_exclude_body']));
    return new BuiltChatPayload('/interactions', body);
  }

  private buildBody(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    request['model'] = asStringValue(payload['model']);
    request['input'] = this.input(payload);
    const system = this.systemInstruction(payload);
    if (system.length > 0) {
      request['system_instruction'] = system;
    }
    const generationConfig = emptyJsonRecord();
    setIfPresent(generationConfig, payload, 'temperature');
    if (payload['top_p'] !== undefined) {
      generationConfig['top_p'] = payload['top_p'];
    }
    if (payload['top_k'] !== undefined) {
      generationConfig['top_k'] = payload['top_k'];
    }
    if (payload['max_tokens'] !== undefined || payload['max_completion_tokens'] !== undefined) {
      generationConfig['max_output_tokens'] = payload['max_completion_tokens'] ?? payload['max_tokens'];
    }
    if (Object.keys(generationConfig).length > 0) {
      request['generation_config'] = generationConfig;
    }
    return request;
  }

  private input(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      if (asStringValue(message['role']) === 'system') {
        continue;
      }
      const next = emptyJsonRecord();
      next['role'] = asStringValue(message['role']);
      next['content'] = messageContentToText(message['content']);
      result.push(next);
    }
    return result;
  }

  private systemInstruction(payload: JsonRecord): string {
    const lines: string[] = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item !== null && !Array.isArray(item) && typeof item === 'object' &&
        asStringValue((item as JsonRecord)['role']) === 'system') {
        lines.push(messageContentToText((item as JsonRecord)['content']));
      }
    }
    return lines.join('\n');
  }
}
