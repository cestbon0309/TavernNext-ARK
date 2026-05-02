import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import {
  asArrayValue,
  asRecordValue,
  asStringValue,
  messageContentToText,
  parseDataUrl,
  setIfPresent,
  setValueIfPresent,
} from '../JsonHelpers';
import { applyCustomBodyOverrides, buildResponseFormatFromJsonSchema, omitKeys, openAiToolDeclarations } from './Shared';

export class ClaudePayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    return new BuiltChatPayload('/messages', this.buildClaudePayload(payload));
  }

  buildPassthrough(payload: JsonRecord): BuiltChatPayload {
    const built = this.build(payload);
    built.body = applyCustomBodyOverrides(built.body, asStringValue(payload['custom_include_body']),
      asStringValue(payload['custom_exclude_body']));
    return built;
  }

  private buildClaudePayload(payload: JsonRecord): JsonRecord {
    let request = emptyJsonRecord();
    request['model'] = asStringValue(payload['model']);
    request['messages'] = this.convertMessages(payload);
    request['max_tokens'] = payload['max_tokens'] ?? payload['max_completion_tokens'] ?? 300;
    setIfPresent(request, payload, 'temperature');
    setIfPresent(request, payload, 'top_p');
    setIfPresent(request, payload, 'top_k');
    setValueIfPresent(request, 'stop_sequences', payload['stop']);
    setIfPresent(request, payload, 'stream');
    const system = this.systemBlocks(payload);
    if (system.length > 0) {
      request['system'] = system;
    }
    const tools = this.claudeTools(payload);
    if (tools.length > 0) {
      request['tools'] = tools;
      this.applyToolChoice(request, payload);
    }
    this.applyJsonSchemaTool(request, payload);
    request = this.applyThinking(request, payload);
    return request;
  }

  private systemBlocks(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    const messages = asArrayValue(payload['messages']);
    for (const item of messages) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      if (asStringValue(message['role']) !== 'system') {
        continue;
      }
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = messageContentToText(message['content']) || '\u200b';
      result.push(block);
    }
    return result;
  }

  private convertMessages(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    const messages = asArrayValue(payload['messages']);
    for (const item of messages) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const sourceRole = asStringValue(message['role']);
      if (sourceRole === 'system') {
        continue;
      }
      const next = emptyJsonRecord();
      next['role'] = sourceRole === 'assistant' ? 'assistant' : 'user';
      next['content'] = sourceRole === 'tool' ? this.toolResultContent(message) : this.contentBlocks(message['content']);
      this.mergeAdjacent(result, next);
    }
    if (result.length === 0) {
      const fallback = emptyJsonRecord();
      fallback['role'] = 'user';
      fallback['content'] = this.contentBlocks('');
      result.push(fallback);
    }
    return result;
  }

  private contentBlocks(content: Object | string | number | boolean | null | JsonArray | undefined): JsonArray {
    const result: JsonArray = [];
    if (Array.isArray(content)) {
      const parts: JsonArray = content;
      for (let index = 0; index < parts.length; index += 1) {
        const part: Object | string | number | boolean | null = parts[index];
        this.appendContentPart(result, part);
      }
    } else {
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = messageContentToText(content) || '\u200b';
      result.push(block);
    }
    if (result.length === 0) {
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = '\u200b';
      result.push(block);
    }
    return result;
  }

  private appendContentPart(result: JsonArray, part: Object | string | number | boolean | null): void {
    if (typeof part === 'string') {
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = part;
      result.push(block);
      return;
    }
    if (part === null || Array.isArray(part) || typeof part !== 'object') {
      return;
    }
    const record = part as JsonRecord;
    const type = asStringValue(record['type']);
    if (type === 'image_url') {
      const imageUrl = asRecordValue(record['image_url']);
      const dataUrl = parseDataUrl(asStringValue(imageUrl['url']));
      if (dataUrl !== null) {
        const source = emptyJsonRecord();
        source['type'] = 'base64';
        source['media_type'] = asStringValue(dataUrl['mimeType']);
        source['data'] = asStringValue(dataUrl['data']);
        const block = emptyJsonRecord();
        block['type'] = 'image';
        block['source'] = source;
        result.push(block);
      }
      return;
    }
    const block = emptyJsonRecord();
    block['type'] = 'text';
    block['text'] = messageContentToText(record['text'] ?? record['content']) || '\u200b';
    result.push(block);
  }

  private toolResultContent(message: JsonRecord): JsonArray {
    const block = emptyJsonRecord();
    block['type'] = 'tool_result';
    block['tool_use_id'] = asStringValue(message['tool_call_id']);
    block['content'] = messageContentToText(message['content']);
    return [block];
  }

  private mergeAdjacent(messages: JsonArray, next: JsonRecord): void {
    if (messages.length === 0) {
      messages.push(next);
      return;
    }
    const last = messages[messages.length - 1];
    if (last !== null && !Array.isArray(last) && typeof last === 'object' &&
      asStringValue((last as JsonRecord)['role']) === asStringValue(next['role'])) {
      const content = asArrayValue((last as JsonRecord)['content']);
      for (const block of asArrayValue(next['content'])) {
        content.push(block);
      }
      (last as JsonRecord)['content'] = content;
      return;
    }
    messages.push(next);
  }

  private claudeTools(payload: JsonRecord): JsonArray {
    const declarations = openAiToolDeclarations(payload['tools']);
    const result: JsonArray = [];
    for (const item of declarations) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const fn = item as JsonRecord;
      const tool = emptyJsonRecord();
      tool['name'] = asStringValue(fn['name']);
      setValueIfPresent(tool, 'description', fn['description']);
      tool['input_schema'] = fn['parameters'] ?? emptyJsonRecord();
      result.push(tool);
    }
    return result;
  }

  private applyToolChoice(request: JsonRecord, payload: JsonRecord): void {
    const choice = payload['tool_choice'];
    if (typeof choice === 'string') {
      if (choice === 'auto' || choice === 'any') {
        const value = emptyJsonRecord();
        value['type'] = choice;
        request['tool_choice'] = value;
      }
      return;
    }
    const record = asRecordValue(choice);
    const fn = asRecordValue(record['function']);
    const name = asStringValue(fn['name']);
    if (name.length > 0) {
      const value = emptyJsonRecord();
      value['type'] = 'tool';
      value['name'] = name;
      request['tool_choice'] = value;
    }
  }

  private applyJsonSchemaTool(request: JsonRecord, payload: JsonRecord): void {
    const responseFormat = buildResponseFormatFromJsonSchema(payload);
    if (responseFormat === null) {
      return;
    }
    const jsonSchema = asRecordValue(responseFormat['json_schema']);
    const tool = emptyJsonRecord();
    tool['name'] = asStringValue(jsonSchema['name']) || 'response';
    tool['description'] = 'Return the response as JSON.';
    tool['input_schema'] = jsonSchema['schema'] ?? emptyJsonRecord();
    const tools = asArrayValue(request['tools']);
    tools.push(tool);
    request['tools'] = tools;
    const choice = emptyJsonRecord();
    choice['type'] = 'tool';
    choice['name'] = asStringValue(tool['name']);
    request['tool_choice'] = choice;
  }

  private applyThinking(request: JsonRecord, payload: JsonRecord): JsonRecord {
    const effort = asStringValue(payload['reasoning_effort']).trim().toLowerCase();
    if (effort.length === 0 || effort === 'auto') {
      return request;
    }
    const budgets: Record<string, number> = {
      'min': 1024,
      'low': 2048,
      'medium': 4096,
      'high': 8192,
      'max': 16384,
      'xhigh': 16384,
    };
    const thinking = emptyJsonRecord();
    thinking['type'] = 'enabled';
    thinking['budget_tokens'] = budgets[effort] ?? 4096;
    request['thinking'] = thinking;
    return omitKeys(request, ['temperature', 'top_p', 'top_k']);
  }
}
