import { JsonArray, JsonRecord, emptyJsonRecord } from '../../../HttpTypes';
import { asArrayValue, asRecordValue, asStringValue, cloneJsonValue, setValueIfPresent } from '../../JsonHelpers';
import { OpenAiToolCall } from './ToolCalls';

export function convertOpenAiToolCallsToClaudeBlocks(toolCalls: OpenAiToolCall[]): JsonArray {
  const blocks: JsonArray = [];
  for (const toolCall of toolCalls) {
    const block = emptyJsonRecord();
    block['type'] = 'tool_use';
    block['id'] = toolCall.id;
    block['name'] = toolCall.name;
    block['input'] = cloneJsonValue(toolCall.arguments);
    blocks.push(block);
  }
  return blocks;
}

export function mapOpenAiToolsToClaude(toolsValue: Object | string | number | boolean | null | JsonArray | undefined): JsonArray {
  const tools = asArrayValue(toolsValue);
  const mappedTools: JsonArray = [];
  for (const item of tools) {
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const tool = item as JsonRecord;
    if (asStringValue(tool['type']) !== 'function') {
      continue;
    }
    const fn = asRecordValue(tool['function']);
    const name = asStringValue(fn['name']).trim();
    if (name.length === 0) {
      continue;
    }
    const mapped = emptyJsonRecord();
    mapped['name'] = name;
    setValueIfPresent(mapped, 'description', fn['description']);
    mapped['input_schema'] = fn['parameters'] ?? defaultInputSchema();
    mappedTools.push(mapped);
  }
  return mappedTools;
}

export function mapToolChoiceToClaude(value: Object | string | number | boolean | null | JsonArray | undefined): JsonRecord | null {
  if (typeof value === 'string') {
    const choice = value.trim();
    if (choice.length === 0 || choice === 'none') {
      return null;
    }
    const mapped = emptyJsonRecord();
    mapped['type'] = choice === 'required' ? 'any' : choice === 'auto' ? 'auto' : 'auto';
    return mapped;
  }
  const object = asRecordValue(value);
  const fn = asRecordValue(object['function']);
  const functionName = asStringValue(fn['name']).trim();
  if (functionName.length > 0) {
    const mapped = emptyJsonRecord();
    mapped['type'] = 'tool';
    mapped['name'] = functionName;
    return mapped;
  }
  const raw = asStringValue(object['type']).trim();
  if (raw === 'tool' || raw === 'auto' || raw === 'any') {
    const mapped = emptyJsonRecord();
    mapped['type'] = raw;
    return mapped;
  }
  return null;
}

function defaultInputSchema(): JsonRecord {
  const schema = emptyJsonRecord();
  schema['type'] = 'object';
  schema['properties'] = emptyJsonRecord();
  return schema;
}
