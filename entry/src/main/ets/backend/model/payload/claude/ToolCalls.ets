import { JsonArray, JsonRecord, emptyJsonRecord } from '../../../HttpTypes';
import { asArrayValue, asRecordValue, asStringValue, cloneJsonValue, messageContentToText } from '../../JsonHelpers';

export class OpenAiToolCall {
  id: string = '';
  name: string = '';
  arguments: Object | string | number | boolean | null | JsonArray = emptyJsonRecord();
  signature: string = '';
}

export function extractOpenAiToolCalls(value: Object | string | number | boolean | null | JsonArray | undefined): OpenAiToolCall[] {
  const entries: JsonArray = [];
  if (Array.isArray(value)) {
    const values: JsonArray = value;
    for (let index = 0; index < values.length; index += 1) {
      const item: Object | string | number | boolean | null = values[index];
      entries.push(item);
    }
  } else if (value !== undefined && value !== null && typeof value === 'object') {
    entries.push(value);
  }
  const calls: OpenAiToolCall[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const item = entries[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const record = item as JsonRecord;
    const fn = asRecordValue(record['function']);
    const name = asStringValue(fn['name']).trim();
    if (name.length === 0) {
      continue;
    }
    const call = new OpenAiToolCall();
    call.id = asStringValue(record['id']) || `tool_call_${index}`;
    call.name = name;
    call.arguments = parseToolCallArguments(fn['arguments'] ?? fn['args']);
    call.signature = asStringValue(record['signature']);
    calls.push(call);
  }
  return calls;
}

export function messageToolCallId(message: JsonRecord): string {
  return asStringValue(message['tool_call_id']);
}

export function messageToolName(message: JsonRecord): string {
  return asStringValue(message['name']);
}

export function messageToolResultText(message: JsonRecord): string {
  return messageContentToText(message['content']);
}

export function normalizeToolResultPayload(content: string): JsonRecord {
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    const empty = emptyJsonRecord();
    empty['content'] = '';
    return empty;
  }
  try {
    const parsed = JSON.parse(trimmed) as Object;
    if (parsed !== null && !Array.isArray(parsed) && typeof parsed === 'object') {
      return parsed as JsonRecord;
    }
    const wrapper = emptyJsonRecord();
    wrapper['content'] = parsed as Object | string | number | boolean | null;
    return wrapper;
  } catch (_err) {
    const wrapper = emptyJsonRecord();
    wrapper['content'] = content;
    return wrapper;
  }
}

export function fallbackToolName(): string {
  return 'tool';
}

function parseToolCallArguments(value: Object | string | number | boolean | null | JsonArray | undefined):
  Object | string | number | boolean | null | JsonArray {
  if (value === undefined || value === null) {
    return emptyJsonRecord();
  }
  if (typeof value === 'string') {
    try {
      return JSON.parse(value) as Object;
    } catch (_err) {
      return value;
    }
  }
  return cloneJsonValue(value) as Object | string | number | boolean | null | JsonArray;
}
