import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { ChatJsonValue } from '../ChatCompletionTypes';
import {
  asArrayValue,
  asBooleanValue,
  asRecordValue,
  asStringValue,
  cloneJsonValue,
  messageContentToText,
  setIfPresent,
  setValueIfPresent,
} from '../JsonHelpers';
import { CustomParameters } from '../CustomParameters';

export const INTERNAL_CHAT_FIELDS: string[] = [
  'chat_completion_source',
  'reverse_proxy',
  'proxy_password',
  'custom_api_format',
  'custom_prompt_post_processing',
  'custom_include_body',
  'custom_exclude_body',
  'custom_include_headers',
  'custom_claude_prompt_caching',
  'custom_url',
  'bypass_status_check',
  'vertexai_auth_mode',
  'vertexai_region',
  'vertexai_express_project_id',
  'zai_endpoint',
];

export function copyKeys(target: JsonRecord, source: JsonRecord, keys: string[]): void {
  for (const key of keys) {
    setIfPresent(target, source, key);
  }
}

export function applyCustomBodyOverrides(body: JsonRecord, includeRaw: string, excludeRaw: string): JsonRecord {
  const custom = new CustomParameters();
  const included = custom.parseObject(includeRaw);
  Object.keys(included).forEach((key: string) => body[key] = included[key]);
  const excluded = custom.parseKeyList(excludeRaw);
  if (excluded.length === 0) {
    return body;
  }
  const next = emptyJsonRecord();
  Object.keys(body).forEach((key: string) => {
    if (!excluded.includes(key)) {
      next[key] = body[key];
    }
  });
  return next;
}

export function omitKeys(source: JsonRecord, keys: string[]): JsonRecord {
  const next = emptyJsonRecord();
  Object.keys(source).forEach((key: string) => {
    if (!keys.includes(key)) {
      next[key] = cloneJsonValue(source[key]);
    }
  });
  return next;
}

export function messagesToPrompt(messages: ChatJsonValue | JsonArray | undefined): string {
  if (typeof messages === 'string') {
    return messages;
  }
  if (!Array.isArray(messages)) {
    return '';
  }
  const lines: string[] = [];
  const items: JsonArray = messages;
  for (let index = 0; index < items.length; index += 1) {
    const item: Object | string | number | boolean | null = items[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const message = item as JsonRecord;
    const role = asStringValue(message['role']) || 'user';
    const content = messageContentToText(message['content']);
    lines.push(`${role}: ${content}`);
  }
  lines.push('assistant:');
  return lines.join('\n');
}

export function buildResponseFormatFromJsonSchema(payload: JsonRecord): JsonRecord | null {
  if (payload['response_format'] !== undefined && payload['response_format'] !== null &&
    !Array.isArray(payload['response_format']) && typeof payload['response_format'] === 'object') {
    return cloneJsonValue(payload['response_format']) as JsonRecord;
  }
  const schema = asRecordValue(payload['json_schema']);
  const value = schema['value'];
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return null;
  }
  const jsonSchema = emptyJsonRecord();
  jsonSchema['name'] = asStringValue(schema['name']) || 'response';
  jsonSchema['strict'] = schema['strict'] === undefined ? true : schema['strict'];
  jsonSchema['schema'] = cloneJsonValue(value);
  const responseFormat = emptyJsonRecord();
  responseFormat['type'] = 'json_schema';
  responseFormat['json_schema'] = jsonSchema;
  return responseFormat;
}

export function copyLogprobs(target: JsonRecord, source: JsonRecord): void {
  const raw = source['logprobs'];
  if (raw === undefined || raw === null) {
    return;
  }
  if (typeof raw === 'boolean') {
    target['logprobs'] = raw;
    if (raw) {
      setIfPresent(target, source, 'top_logprobs');
    }
    return;
  }
  const count = Number(raw);
  if (Number.isFinite(count) && count > 0) {
    target['logprobs'] = true;
    target['top_logprobs'] = count;
  }
}

export function isOpenAiReasoningModel(model: string): boolean {
  const value = model.trim().toLowerCase();
  return value.startsWith('o1') || value.startsWith('o3') || value.startsWith('o4') || value.startsWith('gpt-5');
}

export function normalizeReasoningEffort(raw: string): string {
  const value = raw.trim().toLowerCase();
  return value === 'min' ? 'minimal' : value;
}

export function setThinkingFlag(body: JsonRecord, enabled: boolean): void {
  const thinking = emptyJsonRecord();
  thinking['type'] = enabled ? 'enabled' : 'disabled';
  body['thinking'] = thinking;
}

export function setReasoningObject(body: JsonRecord, effort: string): void {
  if (effort.length === 0 || effort === 'auto') {
    return;
  }
  const reasoning = emptyJsonRecord();
  reasoning['effort'] = normalizeReasoningEffort(effort);
  body['reasoning'] = reasoning;
}

export function openAiToolDeclarations(toolsValue: ChatJsonValue | JsonArray | undefined): JsonArray {
  const tools = asArrayValue(toolsValue);
  const result: JsonArray = [];
  for (const item of tools) {
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const tool = item as JsonRecord;
    const fn = asRecordValue(tool['function']);
    if (Object.keys(fn).length === 0) {
      result.push(cloneJsonValue(tool) as Object);
      continue;
    }
    result.push(cloneJsonValue(fn) as Object);
  }
  return result;
}

export function openAiToolsToFunctionTools(toolsValue: ChatJsonValue | JsonArray | undefined): JsonArray {
  const tools = asArrayValue(toolsValue);
  const result: JsonArray = [];
  for (const item of tools) {
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
      continue;
    }
    const next = emptyJsonRecord();
    next['name'] = asStringValue(fn['name']);
    setValueIfPresent(next, 'description', fn['description']);
    setValueIfPresent(next, 'parameters', fn['parameters']);
    result.push(next);
  }
  return result;
}

export function isTruthy(value: ChatJsonValue | JsonArray | undefined): boolean {
  return asBooleanValue(value, false);
}
