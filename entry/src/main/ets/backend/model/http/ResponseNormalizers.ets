import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import {
  asArrayValue,
  asNumberValue,
  asRecordValue,
  asStringValue,
  cloneJsonValue,
  currentUnixTimestamp,
  messageContentToText,
} from '../JsonHelpers';

export function normalizeClaudeResponse(raw: JsonRecord): JsonRecord {
  if (Array.isArray(raw['choices'])) {
    return raw;
  }
  const response = baseCompletion(asStringValue(raw['id']) || `chatcmpl-claude-${currentUnixTimestamp()}`,
    asStringValue(raw['model']));
  const message = emptyJsonRecord();
  message['role'] = 'assistant';
  const content: string[] = [];
  const toolCalls: JsonArray = [];
  for (const item of asArrayValue(raw['content'])) {
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const block = item as JsonRecord;
    const type = asStringValue(block['type']);
    if (type === 'text') {
      content.push(asStringValue(block['text']));
    } else if (type === 'tool_use') {
      toolCalls.push(openAiToolCall(asStringValue(block['id']), asStringValue(block['name']), block['input']));
    }
  }
  message['content'] = content.join('');
  if (toolCalls.length > 0) {
    message['tool_calls'] = toolCalls;
  }
  setChoice(response, message, finishReason(asStringValue(raw['stop_reason'])));
  const usage = asRecordValue(raw['usage']);
  setUsage(response, asNumberValue(usage['input_tokens']), asNumberValue(usage['output_tokens']));
  return response;
}

export function normalizeGeminiResponse(raw: JsonRecord): JsonRecord {
  if (Array.isArray(raw['choices'])) {
    return raw;
  }
  const response = baseCompletion(`chatcmpl-gemini-${currentUnixTimestamp()}`, asStringValue(raw['modelVersion']));
  const candidates = asArrayValue(raw['candidates']);
  const candidate = candidates.length > 0 && candidates[0] !== null && !Array.isArray(candidates[0]) &&
    typeof candidates[0] === 'object' ? candidates[0] as JsonRecord : emptyJsonRecord();
  const contentRecord = asRecordValue(candidate['content']);
  const message = emptyJsonRecord();
  message['role'] = 'assistant';
  const text: string[] = [];
  const toolCalls: JsonArray = [];
  for (const part of asArrayValue(contentRecord['parts'])) {
    if (part === null || Array.isArray(part) || typeof part !== 'object') {
      continue;
    }
    const record = part as JsonRecord;
    if (record['text'] !== undefined) {
      text.push(asStringValue(record['text']));
    }
    const functionCall = asRecordValue(record['functionCall']);
    if (Object.keys(functionCall).length > 0) {
      toolCalls.push(openAiToolCall('', asStringValue(functionCall['name']), functionCall['args']));
    }
  }
  message['content'] = text.join('');
  if (toolCalls.length > 0) {
    message['tool_calls'] = toolCalls;
  }
  setChoice(response, message, geminiFinishReason(asStringValue(candidate['finishReason']), toolCalls.length > 0));
  const usage = asRecordValue(raw['usageMetadata']);
  setUsage(response, asNumberValue(usage['promptTokenCount']), asNumberValue(usage['candidatesTokenCount']),
    asNumberValue(usage['totalTokenCount']));
  return response;
}

export function normalizeCohereResponse(raw: JsonRecord): JsonRecord {
  if (Array.isArray(raw['choices'])) {
    return raw;
  }
  const response = baseCompletion(asStringValue(raw['id']) || `chatcmpl-cohere-${currentUnixTimestamp()}`,
    asStringValue(raw['model']));
  const sourceMessage = asRecordValue(raw['message']);
  const message = emptyJsonRecord();
  message['role'] = asStringValue(sourceMessage['role']) || 'assistant';
  message['content'] = cohereContentText(sourceMessage['content']);
  const toolCalls = asArrayValue(sourceMessage['tool_calls']);
  if (toolCalls.length > 0) {
    message['tool_calls'] = toolCalls;
  }
  setChoice(response, message, finishReason(asStringValue(raw['finish_reason'])));
  const usage = asRecordValue(raw['usage']);
  const tokens = asRecordValue(usage['tokens']);
  setUsage(response, asNumberValue(tokens['input_tokens']), asNumberValue(tokens['output_tokens']));
  return response;
}

export function normalizeOpenAiResponsesResponse(raw: JsonRecord): JsonRecord {
  if (Array.isArray(raw['choices'])) {
    return raw;
  }
  const response = baseCompletion(asStringValue(raw['id']) || `chatcmpl-resp-${currentUnixTimestamp()}`,
    asStringValue(raw['model']));
  const message = emptyJsonRecord();
  message['role'] = 'assistant';
  const text: string[] = [];
  const toolCalls: JsonArray = [];
  for (const item of asArrayValue(raw['output'])) {
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const output = item as JsonRecord;
    const type = asStringValue(output['type']);
    if (type === 'message') {
      for (const content of asArrayValue(output['content'])) {
        if (content !== null && !Array.isArray(content) && typeof content === 'object') {
          text.push(asStringValue((content as JsonRecord)['text']));
        }
      }
    } else if (type === 'function_call') {
      toolCalls.push(openAiToolCall(asStringValue(output['call_id']), asStringValue(output['name']),
        asStringValue(output['arguments'])));
    }
  }
  message['content'] = text.join('');
  if (toolCalls.length > 0) {
    message['tool_calls'] = toolCalls;
  }
  setChoice(response, message, finishReason(asStringValue(raw['status'])));
  const usage = asRecordValue(raw['usage']);
  setUsage(response, asNumberValue(usage['input_tokens']), asNumberValue(usage['output_tokens']),
    asNumberValue(usage['total_tokens']));
  return response;
}

export function normalizeGeminiInteractionsResponse(raw: JsonRecord): JsonRecord {
  if (Array.isArray(raw['choices'])) {
    return raw;
  }
  const response = baseCompletion(asStringValue(raw['id']) || 'gemini-interactions-chat-completion',
    asStringValue(raw['model']) || asStringValue(raw['modelVersion']));
  const message = emptyJsonRecord();
  message['role'] = 'assistant';
  const outputs = asArrayValue(raw['outputs']);
  const textParts: string[] = [];
  const reasoningParts: string[] = [];
  const toolCalls: JsonArray = [];
  for (let index = 0; index < outputs.length; index += 1) {
    const item = outputs[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const output = item as JsonRecord;
    const type = asStringValue(output['type']);
    if (type === 'text') {
      const text = asStringValue(output['text']).trim();
      if (text.length > 0) {
        textParts.push(text);
      }
    } else if (type === 'thought') {
      const summary = asStringValue(output['summary']).trim();
      if (summary.length > 0) {
        reasoningParts.push(summary);
      }
    } else if (type === 'function_call') {
      const id = asStringValue(output['id']).trim() || `tool_call_${index}`;
      const name = asStringValue(output['name']).trim() || 'tool';
      toolCalls.push(openAiToolCall(id, name, output['arguments'], asStringValue(output['signature']).trim()));
    }
  }
  message['content'] = outputs.length > 0 ? textParts.join('\n\n') : messageContentToText(raw['output'] ?? raw['content']);
  if (reasoningParts.length > 0) {
    message['reasoning_content'] = reasoningParts.join('\n\n');
  }
  if (toolCalls.length > 0) {
    message['tool_calls'] = toolCalls;
  }
  if (outputs.length > 0) {
    const native = emptyJsonRecord();
    const wrapper = emptyJsonRecord();
    wrapper['outputs'] = cloneJsonValue(outputs) as JsonArray;
    native['gemini_interactions'] = wrapper;
    message['native'] = native;
  }
  setChoice(response, message, toolCalls.length > 0 ? 'tool_calls' : 'stop');
  const usage = thisGeminiInteractionsUsage(raw);
  if (usage !== null) {
    response['usage'] = usage;
  }
  return response;
}

function baseCompletion(id: string, model: string): JsonRecord {
  const response = emptyJsonRecord();
  response['id'] = id;
  response['object'] = 'chat.completion';
  response['created'] = currentUnixTimestamp();
  response['model'] = model;
  response['choices'] = [];
  const usage = emptyJsonRecord();
  usage['prompt_tokens'] = 0;
  usage['completion_tokens'] = 0;
  usage['total_tokens'] = 0;
  response['usage'] = usage;
  return response;
}

function setChoice(response: JsonRecord, message: JsonRecord, finish: string): void {
  const choice = emptyJsonRecord();
  choice['index'] = 0;
  choice['message'] = message;
  choice['finish_reason'] = finish;
  response['choices'] = [choice];
}

function setUsage(response: JsonRecord, prompt: number, completion: number, total: number = -1): void {
  const usage = emptyJsonRecord();
  usage['prompt_tokens'] = prompt;
  usage['completion_tokens'] = completion;
  usage['total_tokens'] = total >= 0 ? total : prompt + completion;
  response['usage'] = usage;
}

function finishReason(value: string): string {
  switch (value) {
    case 'end_turn':
    case 'stop':
    case 'COMPLETE':
    case 'completed':
      return 'stop';
    case 'max_tokens':
    case 'MAX_TOKENS':
      return 'length';
    case 'tool_use':
      return 'tool_calls';
    default:
      return value.length > 0 ? value : 'stop';
  }
}

function geminiFinishReason(value: string, hasToolCalls: boolean): string {
  if (hasToolCalls) {
    return 'tool_calls';
  }
  switch (value) {
    case 'MAX_TOKENS':
      return 'length';
    case 'STOP':
      return 'stop';
    default:
      return value.length > 0 ? value.toLowerCase() : 'stop';
  }
}

function openAiToolCall(id: string, name: string, args: Object | string | number | boolean | null | JsonArray | undefined,
  signature: string = ''): JsonRecord {
  const fn = emptyJsonRecord();
  fn['name'] = name;
  fn['arguments'] = typeof args === 'string' ? args : JSON.stringify(args ?? {});
  const call = emptyJsonRecord();
  call['id'] = id.length > 0 ? id : `call_${currentUnixTimestamp()}`;
  call['type'] = 'function';
  call['function'] = fn;
  if (signature.length > 0) {
    call['signature'] = signature;
  }
  return call;
}

function thisGeminiInteractionsUsage(raw: JsonRecord): JsonRecord | null {
  const usage = asRecordValue(raw['usage']);
  if (Object.keys(usage).length === 0) {
    return null;
  }
  const prompt = asNumberValue(usage['input_tokens'], asNumberValue(usage['prompt_tokens']));
  const completion = asNumberValue(usage['output_tokens'], asNumberValue(usage['completion_tokens']));
  const total = asNumberValue(usage['total_tokens'], asNumberValue(usage['totalTokens'], prompt + completion));
  const mapped = emptyJsonRecord();
  mapped['prompt_tokens'] = prompt;
  mapped['completion_tokens'] = completion;
  mapped['total_tokens'] = total;
  return mapped;
}

function cohereContentText(value: Object | string | number | boolean | null | JsonArray | undefined): string {
  if (!Array.isArray(value)) {
    return messageContentToText(value);
  }
  const parts: string[] = [];
  const items: JsonArray = value;
  for (let index = 0; index < items.length; index += 1) {
    const item: Object | string | number | boolean | null = items[index];
    if (item !== null && !Array.isArray(item) && typeof item === 'object') {
      parts.push(asStringValue((item as JsonRecord)['text']));
    } else if (typeof item === 'string') {
      parts.push(item);
    }
  }
  return parts.join('');
}
