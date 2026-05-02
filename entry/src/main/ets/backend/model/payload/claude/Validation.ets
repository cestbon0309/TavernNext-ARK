import { JsonRecord } from '../../../HttpTypes';
import { asRecordValue, asStringValue } from '../../JsonHelpers';
import { ClaudeModelContract, ClaudeSamplingMode, ClaudeThinkingMode, resolveClaudeModelContract } from './Contract';
import { collectNonDefaultSamplingParams, hasNonDefaultTemperature, hasNonDefaultTopP, valueToInteger } from './Params';

type ClaudeRequestThinkingMode = 'enabled' | 'adaptive';

export function validateClaudeRequest(request: JsonRecord): void {
  const model = asStringValue(request['model']).trim();
  if (model.length === 0) {
    throw new Error('Claude request is missing model');
  }
  const contract = resolveClaudeModelContract(model);
  const thinkingMode = validateClaudeThinkingRequest(request, contract, model);
  validateClaudeOutputConfig(request, contract, model);
  validateClaudeSamplingRequest(request, contract.sampling, thinkingMode, model);
}

function validateClaudeThinkingRequest(request: JsonRecord, contract: ClaudeModelContract, model: string): ClaudeRequestThinkingMode | null {
  if (request['thinking'] === undefined || request['thinking'] === null) {
    return null;
  }
  const thinking = asRecordValue(request['thinking']);
  const thinkingType = asStringValue(thinking['type']).trim();
  if (thinkingType.length === 0) {
    throw new Error(`Claude model \`${model}\` requires thinking.type`);
  }
  let mode: ClaudeRequestThinkingMode;
  if (thinkingType === 'enabled') {
    if (valueToInteger(thinking['budget_tokens']) === null) {
      throw new Error(`Claude model \`${model}\` requires thinking.budget_tokens for legacy thinking`);
    }
    mode = 'enabled';
  } else if (thinkingType === 'adaptive') {
    if (thinking['budget_tokens'] !== undefined) {
      throw new Error(`Claude model \`${model}\` does not allow thinking.budget_tokens with adaptive thinking`);
    }
    const display = asStringValue(thinking['display']).trim();
    if (display.length > 0 && display !== 'summarized' && display !== 'omitted') {
      throw new Error(`Unsupported Claude adaptive thinking display: ${display}`);
    }
    mode = 'adaptive';
  } else {
    throw new Error(`Unsupported Claude thinking.type: ${thinkingType}`);
  }
  validateThinkingAgainstContract(contract.thinking, mode, model);
  return mode;
}

function validateThinkingAgainstContract(contractMode: ClaudeThinkingMode, requestMode: ClaudeRequestThinkingMode,
  model: string): void {
  if (contractMode === 'unsupported') {
    throw new Error(`Claude model \`${model}\` does not support thinking`);
  }
  if (contractMode === 'manual_only' && requestMode === 'adaptive') {
    throw new Error(`Claude model \`${model}\` requires legacy thinking with budget_tokens`);
  }
  if (contractMode === 'adaptive_only' && requestMode === 'enabled') {
    throw new Error(`Claude model \`${model}\` requires adaptive thinking`);
  }
}

function validateClaudeOutputConfig(request: JsonRecord, contract: ClaudeModelContract, model: string): void {
  if (request['output_config'] === undefined || request['output_config'] === null) {
    return;
  }
  const outputConfig = asRecordValue(request['output_config']);
  const effort = asStringValue(outputConfig['effort']).trim();
  if (effort.length === 0) {
    return;
  }
  if (!contract.supportsOutputEffort) {
    throw new Error(`Claude model \`${model}\` does not support output_config.effort`);
  }
  if (effort !== 'low' && effort !== 'medium' && effort !== 'high' && effort !== 'max' && effort !== 'xhigh') {
    throw new Error(`Unsupported Claude adaptive effort: ${effort}`);
  }
}

function validateClaudeSamplingRequest(request: JsonRecord, sampling: ClaudeSamplingMode,
  thinkingMode: ClaudeRequestThinkingMode | null, model: string): void {
  const disallowed = collectNonDefaultSamplingParams(request);
  if (thinkingMode === 'enabled' && disallowed.length > 0) {
    throw new Error(`Claude model \`${model}\` does not allow non-default sampling parameters with legacy thinking: ${disallowed.join(', ')}`);
  }
  if (sampling === 'full') {
    return;
  }
  if (sampling === 'temperature_or_top_p') {
    if (hasNonDefaultTemperature(request) && hasNonDefaultTopP(request)) {
      throw new Error(`Claude model \`${model}\` accepts either temperature or top_p, not both`);
    }
    return;
  }
  if (disallowed.length > 0) {
    throw new Error(`Claude model \`${model}\` does not support non-default sampling parameters: ${disallowed.join(', ')}`);
  }
}
