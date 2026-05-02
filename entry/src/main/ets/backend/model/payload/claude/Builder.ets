import { JsonArray, JsonRecord, emptyJsonRecord } from '../../../HttpTypes';
import { asArrayValue, asBooleanValue, asRecordValue, asStringValue, setIfPresent } from '../../JsonHelpers';
import { buildResponseFormatFromJsonSchema, omitKeys } from '../Shared';
import { resolveClaudeModelContract } from './Contract';
import {
  convertMessages,
  mergeConsecutiveMessages,
  moveAssistantImagesToNextUserMessage,
} from './Messages';
import { hasNonDefaultTemperature, hasNonDefaultTopK, hasNonDefaultTopP, valueToInteger } from './Params';
import { mapOpenAiToolsToClaude, mapToolChoiceToClaude } from './Tools';
import { validateClaudeRequest } from './Validation';

const CLAUDE_THINKING_MIN_TOKENS = 1024;
const CLAUDE_THINKING_NON_STREAM_CAP = 21333;

type ClaudeReasoningEffort = 'min' | 'low' | 'medium' | 'high' | 'max';

export function buildClaudePayload(payload: JsonRecord, enforceContract: boolean = true): JsonRecord {
  const request = buildClaudePayloadInner(payload, enforceContract);
  if (enforceContract) {
    validateClaudeRequest(request);
  }
  return request;
}

export function buildClaudePayloadPassthrough(payload: JsonRecord): JsonRecord {
  return buildClaudePayloadInner(payload, false);
}

function buildClaudePayloadInner(payload: JsonRecord, enforceContract: boolean): JsonRecord {
  const model = asStringValue(payload['model']).trim();
  if (model.length === 0) {
    throw new Error('Claude request is missing model');
  }
  const contract = enforceContract ? resolveClaudeModelContract(model) : null;
  const reasoningEffort = contract !== null ? parseClaudeReasoningEffort(asStringValue(payload['reasoning_effort'])) : null;
  const useSystemPrompt = asBooleanValue(payload['use_sysprompt']);
  const useTools = asArrayValue(payload['tools']).length > 0 || jsonSchemaValue(payload) !== null;
  const converted = convertMessages(payload['messages'], useSystemPrompt, useTools);
  let messages = converted.messages;

  const assistantPrefill = asStringValue(payload['assistant_prefill']).trim();
  if (assistantPrefill.length > 0 && reasoningEffort !== null) {
    throw new Error(`Claude model \`${model}\` does not support assistant_prefill with reasoning_effort`);
  }
  if (assistantPrefill.length > 0 && contract !== null && !contract.supportsAssistantPrefill) {
    throw new Error(`Claude model \`${model}\` does not support assistant_prefill`);
  }
  if (assistantPrefill.length > 0) {
    const prefill = emptyJsonRecord();
    prefill['role'] = 'assistant';
    const block = emptyJsonRecord();
    block['type'] = 'text';
    block['text'] = assistantPrefill;
    prefill['content'] = [block];
    messages.push(prefill);
  }

  moveAssistantImagesToNextUserMessage(messages);
  messages = mergeConsecutiveMessages(messages);
  if (messages.length === 0) {
    const fallback = emptyJsonRecord();
    fallback['role'] = 'user';
    const block = emptyJsonRecord();
    block['type'] = 'text';
    block['text'] = '';
    fallback['content'] = [block];
    messages.push(fallback);
  }

  let maxTokens = valueToInteger(payload['max_tokens'] ?? payload['max_completion_tokens']) ?? CLAUDE_THINKING_MIN_TOKENS;
  maxTokens = Math.max(1, maxTokens);
  const stream = asBooleanValue(payload['stream']);
  let request = emptyJsonRecord();
  request['model'] = model;
  setIfPresent(request, payload, 'stream');
  insertClaudeSamplingParams(request, payload);
  if (Array.isArray(payload['stop'])) {
    request['stop_sequences'] = payload['stop'];
  }
  if (useSystemPrompt && converted.system.length > 0) {
    request['system'] = converted.system;
  }

  const tools = mapOpenAiToolsToClaude(payload['tools']);
  const schemaToolChoice = appendJsonSchemaTool(tools, payload);
  if (tools.length > 0) {
    request['tools'] = tools;
    const toolChoice = schemaToolChoice ?? mapToolChoiceToClaude(payload['tool_choice']);
    if (toolChoice !== null) {
      request['tool_choice'] = toolChoice;
    }
  }

  if (contract !== null && reasoningEffort !== null) {
    if (contract.thinking === 'unsupported') {
      throw new Error(`Claude model \`${model}\` does not support reasoning_effort`);
    }
    if (contract.thinking === 'manual_only') {
      const budgetTokens = calculateBudgetTokens(reasoningEffort, maxTokens, stream);
      if (maxTokens <= CLAUDE_THINKING_MIN_TOKENS) {
        maxTokens += CLAUDE_THINKING_MIN_TOKENS;
      }
      const thinking = emptyJsonRecord();
      thinking['type'] = 'enabled';
      thinking['budget_tokens'] = budgetTokens;
      request['thinking'] = thinking;
      request = omitKeys(request, ['temperature', 'top_p', 'top_k']);
    } else {
      request['thinking'] = buildClaudeAdaptiveThinking(payload);
      if (contract.supportsOutputEffort) {
        const outputConfig = emptyJsonRecord();
        outputConfig['effort'] = adaptiveEffort(reasoningEffort);
        request['output_config'] = outputConfig;
      }
    }
  }

  request['messages'] = messages;
  request['max_tokens'] = maxTokens;
  return request;
}

function insertClaudeSamplingParams(request: JsonRecord, payload: JsonRecord): void {
  if (hasNonDefaultTemperature(payload)) {
    setIfPresent(request, payload, 'temperature');
  }
  if (hasNonDefaultTopP(payload)) {
    setIfPresent(request, payload, 'top_p');
  }
  if (hasNonDefaultTopK(payload)) {
    setIfPresent(request, payload, 'top_k');
  }
}

function appendJsonSchemaTool(tools: JsonArray, payload: JsonRecord): JsonRecord | null {
  const schema = jsonSchemaValue(payload);
  if (schema === null) {
    return null;
  }
  const responseFormat = buildResponseFormatFromJsonSchema(payload);
  if (responseFormat === null) {
    return null;
  }
  const jsonSchema = asRecordValue(responseFormat['json_schema']);
  const schemaName = asStringValue(jsonSchema['name']) || 'response';
  const schemaTool = emptyJsonRecord();
  schemaTool['name'] = schemaName;
  schemaTool['description'] = 'Well-formed JSON object';
  schemaTool['input_schema'] = schema;
  tools.push(schemaTool);
  const choice = emptyJsonRecord();
  choice['type'] = 'tool';
  choice['name'] = schemaName;
  return choice;
}

function jsonSchemaValue(payload: JsonRecord): Object | string | number | boolean | null | JsonArray {
  const schema = asRecordValue(payload['json_schema']);
  const value = schema['value'];
  if (value === undefined || value === null) {
    return null;
  }
  return value;
}

function parseClaudeReasoningEffort(raw: string): ClaudeReasoningEffort | null {
  const value = raw.trim().toLowerCase();
  if (value.length === 0 || value === 'auto') {
    return null;
  }
  if (value === 'min' || value === 'low' || value === 'medium' || value === 'high' || value === 'max') {
    return value;
  }
  if (value === 'xhigh') {
    return 'max';
  }
  throw new Error(`Unsupported Claude reasoning_effort: ${raw}`);
}

function calculateBudgetTokens(effort: ClaudeReasoningEffort, maxTokens: number, stream: boolean): number {
  const safeMax = Math.max(0, maxTokens);
  let budget = CLAUDE_THINKING_MIN_TOKENS;
  if (effort === 'low') {
    budget = Math.floor(safeMax * 10 / 100);
  } else if (effort === 'medium') {
    budget = Math.floor(safeMax * 25 / 100);
  } else if (effort === 'high') {
    budget = Math.floor(safeMax * 50 / 100);
  } else if (effort === 'max') {
    budget = Math.floor(safeMax * 95 / 100);
  }
  budget = Math.max(CLAUDE_THINKING_MIN_TOKENS, budget);
  return stream ? budget : Math.min(budget, CLAUDE_THINKING_NON_STREAM_CAP);
}

function adaptiveEffort(effort: ClaudeReasoningEffort): string {
  switch (effort) {
    case 'min':
    case 'low':
      return 'low';
    case 'medium':
      return 'medium';
    case 'high':
      return 'high';
    case 'max':
      return 'max';
  }
}

function buildClaudeAdaptiveThinking(payload: JsonRecord): JsonRecord {
  const thinking = emptyJsonRecord();
  thinking['type'] = 'adaptive';
  thinking['display'] = asBooleanValue(payload['include_reasoning']) ? 'summarized' : 'omitted';
  return thinking;
}
