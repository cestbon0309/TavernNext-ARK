import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import {
  asArrayValue,
  asBooleanValue,
  asNumberValue,
  asRecordValue,
  asStringValue,
  cloneJsonValue,
  messageContentToText,
  parseDataUrl,
} from '../JsonHelpers';
import { applyCustomBodyOverrides } from './Shared';
import {
  OpenAiToolCall,
  extractOpenAiToolCalls,
  fallbackToolName,
  messageToolCallId,
  messageToolName,
  messageToolResultText,
  normalizeToolResultPayload,
} from './claude/ToolCalls';

export class GeminiInteractionsPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    let body = this.buildBody(payload);
    body = applyCustomBodyOverrides(body, asStringValue(payload['custom_include_body']),
      asStringValue(payload['custom_exclude_body']));
    return new BuiltChatPayload('/interactions', body);
  }

  private buildBody(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    const model = asStringValue(payload['model']).trim();
    if (model.length === 0) {
      throw new Error('Gemini Interactions request is missing model');
    }
    request['model'] = model;
    request['input'] = this.input(payload);
    request['stream'] = asBooleanValue(payload['stream']);
    request['store'] = false;
    const system = this.systemInstruction(payload);
    if (system.length > 0) {
      request['system_instruction'] = system;
    }
    const generationConfig = emptyJsonRecord();
    if (payload['temperature'] !== undefined && payload['temperature'] !== null) {
      generationConfig['temperature'] = cloneJsonValue(payload['temperature']);
    }
    if (payload['top_p'] !== undefined) {
      generationConfig['top_p'] = cloneJsonValue(payload['top_p']);
    }
    if (payload['top_k'] !== undefined && asNumberValue(payload['top_k']) > 0) {
      generationConfig['top_k'] = Math.trunc(asNumberValue(payload['top_k']));
    }
    const maxTokens = payload['max_output_tokens'] ?? payload['max_completion_tokens'] ?? payload['max_tokens'];
    if (asNumberValue(maxTokens) > 0) {
      generationConfig['max_output_tokens'] = Math.trunc(asNumberValue(maxTokens));
    }
    if (Object.keys(generationConfig).length > 0) {
      request['generation_config'] = generationConfig;
    }
    const tools = this.tools(payload);
    if (tools.length > 0) {
      request['tools'] = tools;
    }
    const schema = asRecordValue(payload['json_schema']);
    if (schema['value'] !== undefined && schema['value'] !== null) {
      request['response_format'] = cloneJsonValue(schema['value']);
    }
    return request;
  }

  private input(payload: JsonRecord): Object | string | number | boolean | null | JsonArray {
    const messagesValue = payload['messages'];
    if (typeof messagesValue === 'string') {
      return messagesValue;
    }
    const result: JsonArray = [];
    const messages = asArrayValue(messagesValue);
    const toolNameById: Record<string, string> = {};
    let index = 0;
    while (index < messages.length) {
      const item = messages[index];
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        index += 1;
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']).trim().toLowerCase() || 'user';
      if (role === 'system') {
        index += 1;
        continue;
      }
      if (role === 'tool' || role === 'function') {
        const results: JsonArray = [];
        while (index < messages.length) {
          const toolItem = messages[index];
          if (toolItem === null || Array.isArray(toolItem) || typeof toolItem !== 'object') {
            index += 1;
            continue;
          }
          const toolMessage = toolItem as JsonRecord;
          const toolRole = asStringValue(toolMessage['role']).trim().toLowerCase() || 'tool';
          if (toolRole !== 'tool' && toolRole !== 'function') {
            break;
          }
          const callId = messageToolCallId(toolMessage).trim();
          if (callId.length === 0) {
            throw new Error('Tool message is missing tool_call_id required for Gemini Interactions function_result');
          }
          const result = emptyJsonRecord();
          result['type'] = 'function_result';
          result['name'] = messageToolName(toolMessage) ||
            (toolNameById[callId] !== undefined ? toolNameById[callId] : fallbackToolName());
          result['call_id'] = callId;
          result['result'] = normalizeToolResultPayload(messageToolResultText(toolMessage));
          results.push(result);
          index += 1;
        }
        result.push(this.turn('user', results));
        continue;
      }
      if (role === 'assistant') {
        const calls = extractOpenAiToolCalls(message['tool_calls']);
        for (const call of calls) {
          toolNameById[call.id] = call.name;
        }
        result.push(this.turn('model', this.messageNativeOutputs(message) ?? this.syntheticModelOutputs(message, calls)));
        index += 1;
        continue;
      }
      const next = emptyJsonRecord();
      next['role'] = 'user';
      const blocks = this.contentBlocks(message['content']);
      next['content'] = this.blocksToContent(blocks);
      result.push(next);
      index += 1;
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

  private tools(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    for (const item of asArrayValue(payload['tools'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const tool = item as JsonRecord;
      if (asStringValue(tool['type']) !== 'function') {
        result.push(cloneJsonValue(tool) as Object);
        continue;
      }
      const fn = asRecordValue(tool['function']);
      if (Object.keys(fn).length === 0) {
        result.push(cloneJsonValue(tool) as Object);
        continue;
      }
      const mapped = emptyJsonRecord();
      mapped['type'] = 'function';
      if (asStringValue(fn['name']).length > 0) {
        mapped['name'] = asStringValue(fn['name']);
      }
      if (asStringValue(fn['description']).length > 0) {
        mapped['description'] = asStringValue(fn['description']);
      }
      if (fn['parameters'] !== undefined) {
        mapped['parameters'] = cloneJsonValue(fn['parameters']);
      }
      result.push(mapped);
    }
    return result;
  }

  private messageNativeOutputs(message: JsonRecord): JsonArray | null {
    const native = asRecordValue(message['native']);
    const interactions = asRecordValue(native['gemini_interactions']);
    if (interactions['outputs'] === undefined || !Array.isArray(interactions['outputs'])) {
      return null;
    }
    return cloneJsonValue(interactions['outputs']) as JsonArray;
  }

  private syntheticModelOutputs(message: JsonRecord, calls: OpenAiToolCall[]): JsonArray {
    const outputs: JsonArray = [];
    const text = messageContentToText(message['content']);
    if (text.trim().length > 0) {
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = text;
      outputs.push(block);
    }
    for (const call of calls) {
      outputs.push(this.functionCallOutput(call));
    }
    const signature = asStringValue(message['signature']).trim();
    if (signature.length > 0) {
      const block = emptyJsonRecord();
      block['type'] = 'thought';
      block['signature'] = signature;
      outputs.push(block);
    }
    return outputs;
  }

  private functionCallOutput(call: OpenAiToolCall): JsonRecord {
    const output = emptyJsonRecord();
    output['type'] = 'function_call';
    output['id'] = call.id;
    output['name'] = call.name;
    output['arguments'] = cloneJsonValue(call.arguments);
    if (call.signature.length > 0) {
      output['signature'] = call.signature;
    }
    return output;
  }

  private contentBlocks(content: Object | string | number | boolean | null | JsonArray | undefined): JsonArray {
    if (content === undefined || content === null) {
      return [];
    }
    if (typeof content === 'string') {
      if (content.trim().length === 0) {
        return [];
      }
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = content;
      return [block];
    }
    if (!Array.isArray(content)) {
      const block = emptyJsonRecord();
      block['type'] = 'text';
      block['text'] = String(content);
      return [block];
    }
    const result: JsonArray = [];
    const parts: JsonArray = content;
    for (let index = 0; index < parts.length; index += 1) {
      const item: Object | string | number | boolean | null = parts[index];
      if (typeof item === 'string') {
        const block = emptyJsonRecord();
        block['type'] = 'text';
        block['text'] = item;
        result.push(block);
        continue;
      }
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      const type = asStringValue(record['type']);
      if (type === 'text' && asStringValue(record['text']).length > 0) {
        const block = emptyJsonRecord();
        block['type'] = 'text';
        block['text'] = asStringValue(record['text']);
        result.push(block);
        continue;
      }
      if (type === 'image_url' || type === 'audio_url' || type === 'video_url') {
        const block = this.mediaBlock(record, type);
        if (block !== null) {
          result.push(block);
          continue;
        }
      }
      if (type === 'image' || type === 'audio' || type === 'video' || type === 'text') {
        result.push(cloneJsonValue(record) as Object);
        continue;
      }
      if (asStringValue(record['text']).length > 0) {
        const block = emptyJsonRecord();
        block['type'] = 'text';
        block['text'] = asStringValue(record['text']);
        result.push(block);
        continue;
      }
      result.push(cloneJsonValue(record) as Object);
    }
    return result;
  }

  private mediaBlock(record: JsonRecord, type: string): JsonRecord | null {
    const key = type === 'image_url' ? 'image_url' : type === 'audio_url' ? 'audio_url' : 'video_url';
    const url = asStringValue(asRecordValue(record[key])['url']).trim();
    if (url.length === 0) {
      return null;
    }
    const block = emptyJsonRecord();
    block['type'] = type === 'image_url' ? 'image' : type === 'audio_url' ? 'audio' : 'video';
    const dataUrl = parseDataUrl(url);
    if (dataUrl !== null) {
      block['mime_type'] = asStringValue(dataUrl['mimeType']);
      block['data'] = asStringValue(dataUrl['data']);
    } else {
      block['uri'] = url;
    }
    return block;
  }

  private blocksToContent(blocks: JsonArray): Object | string | number | boolean | null | JsonArray {
    if (blocks.length === 1) {
      const only = blocks[0];
      if (only !== null && !Array.isArray(only) && typeof only === 'object') {
        const record = only as JsonRecord;
        if (asStringValue(record['type']) === 'text' && asStringValue(record['text']).length > 0) {
          return asStringValue(record['text']);
        }
      }
    }
    return blocks;
  }

  private turn(role: string, content: Object | string | number | boolean | null | JsonArray): JsonRecord {
    const turn = emptyJsonRecord();
    turn['role'] = role;
    turn['content'] = content;
    return turn;
  }
}
