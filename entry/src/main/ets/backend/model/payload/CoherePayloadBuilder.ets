import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asArrayValue, asRecordValue, asStringValue, messageContentToText, setIfPresent } from '../JsonHelpers';
import { buildResponseFormatFromJsonSchema, openAiToolDeclarations } from './Shared';

export class CoherePayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const request = emptyJsonRecord();
    request['model'] = asStringValue(payload['model']);
    request['messages'] = this.messages(payload);
    setIfPresent(request, payload, 'temperature');
    if (payload['top_k'] !== undefined) {
      request['k'] = payload['top_k'];
    }
    if (payload['top_p'] !== undefined) {
      request['p'] = payload['top_p'];
    }
    if (payload['max_tokens'] !== undefined || payload['max_completion_tokens'] !== undefined) {
      request['max_tokens'] = payload['max_tokens'] ?? payload['max_completion_tokens'];
    }
    if (payload['stop'] !== undefined) {
      request['stop_sequences'] = payload['stop'];
    }
    setIfPresent(request, payload, 'stream');
    request['documents'] = [];
    const tools = this.tools(payload);
    if (tools.length > 0) {
      request['tools'] = tools;
    }
    const responseFormat = buildResponseFormatFromJsonSchema(payload);
    if (responseFormat !== null) {
      const value = emptyJsonRecord();
      value['type'] = 'json_schema';
      value['schema'] = asRecordValue(asRecordValue(responseFormat['json_schema'])['schema']);
      request['response_format'] = value;
    }
    return new BuiltChatPayload('/chat', request);
  }

  private messages(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const next = emptyJsonRecord();
      next['role'] = this.role(asStringValue(message['role']));
      next['content'] = messageContentToText(message['content']);
      result.push(next);
    }
    if (result.length === 0) {
      const fallback = emptyJsonRecord();
      fallback['role'] = 'user';
      fallback['content'] = "Let's get started.";
      result.push(fallback);
    }
    return result;
  }

  private role(value: string): string {
    switch (value) {
      case 'assistant':
        return 'assistant';
      case 'system':
        return 'system';
      case 'tool':
        return 'tool';
      default:
        return 'user';
    }
  }

  private tools(payload: JsonRecord): JsonArray {
    const declarations = openAiToolDeclarations(payload['tools']);
    const result: JsonArray = [];
    for (const item of declarations) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const fn = item as JsonRecord;
      const tool = emptyJsonRecord();
      tool['name'] = asStringValue(fn['name']);
      setIfPresent(tool, fn, 'description');
      setIfPresent(tool, fn, 'parameters');
      result.push(tool);
    }
    return result;
  }
}
