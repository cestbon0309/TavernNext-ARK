export type ClaudeSamplingMode = 'full' | 'temperature_or_top_p' | 'none';
export type ClaudeThinkingMode = 'unsupported' | 'manual_only' | 'manual_or_adaptive' | 'adaptive_only';

export class ClaudeModelContract {
  sampling: ClaudeSamplingMode = 'none';
  thinking: ClaudeThinkingMode = 'unsupported';
  supportsOutputEffort: boolean = false;
  supportsAssistantPrefill: boolean = false;
}

const CLAUDE_FULL_SAMPLING_EXACT_MODELS: string[] = ['claude-opus-4', 'claude-sonnet-4'];
const CLAUDE_FULL_SAMPLING_MODEL_PREFIXES: string[] = [
  'claude-3-7',
  'claude-3-5',
  'claude-3-opus',
  'claude-3-sonnet',
  'claude-3-haiku',
  'claude-2',
  'claude-instant',
];
const CLAUDE_LIMITED_SAMPLING_MODEL_PREFIXES: string[] = [
  'claude-opus-4-6',
  'claude-sonnet-4-6',
  'claude-opus-4-5',
  'claude-sonnet-4-5',
  'claude-haiku-4-5',
];
const CLAUDE_MANUAL_ONLY_THINKING_EXACT_MODELS: string[] = ['claude-opus-4', 'claude-sonnet-4'];
const CLAUDE_MANUAL_ONLY_THINKING_MODEL_PREFIXES: string[] = [
  'claude-3-7',
  'claude-opus-4-5',
  'claude-sonnet-4-5',
  'claude-haiku-4-5',
];
const CLAUDE_MANUAL_OR_ADAPTIVE_THINKING_MODEL_PREFIXES: string[] = ['claude-opus-4-6', 'claude-sonnet-4-6'];
const CLAUDE_ADAPTIVE_ONLY_THINKING_MODEL_PREFIXES: string[] = ['claude-opus-4-7'];
const CLAUDE_OUTPUT_EFFORT_MODEL_PREFIXES: string[] = [
  'claude-opus-4-7',
  'claude-opus-4-6',
  'claude-sonnet-4-6',
  'claude-opus-4-5',
];
const CLAUDE_ASSISTANT_PREFILL_EXACT_MODELS: string[] = ['claude-opus-4', 'claude-sonnet-4'];
const CLAUDE_ASSISTANT_PREFILL_MODEL_PREFIXES: string[] = [
  'claude-3-7',
  'claude-opus-4-5',
  'claude-sonnet-4-5',
  'claude-haiku-4-5',
  'claude-3-5',
  'claude-3-opus',
  'claude-3-sonnet',
  'claude-3-haiku',
  'claude-2',
  'claude-instant',
];

export function resolveClaudeModelContract(model: string): ClaudeModelContract {
  const value = model.trim().toLowerCase();
  const contract = new ClaudeModelContract();
  contract.sampling = resolveClaudeSamplingMode(value);
  contract.thinking = resolveClaudeThinkingMode(value);
  contract.supportsOutputEffort = matchesClaudeModel(value, [], CLAUDE_OUTPUT_EFFORT_MODEL_PREFIXES);
  contract.supportsAssistantPrefill = matchesClaudeModel(value, CLAUDE_ASSISTANT_PREFILL_EXACT_MODELS,
    CLAUDE_ASSISTANT_PREFILL_MODEL_PREFIXES);
  return contract;
}

function resolveClaudeSamplingMode(model: string): ClaudeSamplingMode {
  if (matchesClaudeModel(model, [], CLAUDE_LIMITED_SAMPLING_MODEL_PREFIXES)) {
    return 'temperature_or_top_p';
  }
  if (matchesClaudeModel(model, CLAUDE_FULL_SAMPLING_EXACT_MODELS, CLAUDE_FULL_SAMPLING_MODEL_PREFIXES)) {
    return 'full';
  }
  return 'none';
}

function resolveClaudeThinkingMode(model: string): ClaudeThinkingMode {
  if (matchesClaudeModel(model, [], CLAUDE_ADAPTIVE_ONLY_THINKING_MODEL_PREFIXES)) {
    return 'adaptive_only';
  }
  if (matchesClaudeModel(model, [], CLAUDE_MANUAL_OR_ADAPTIVE_THINKING_MODEL_PREFIXES)) {
    return 'manual_or_adaptive';
  }
  if (matchesClaudeModel(model, CLAUDE_MANUAL_ONLY_THINKING_EXACT_MODELS, CLAUDE_MANUAL_ONLY_THINKING_MODEL_PREFIXES)) {
    return 'manual_only';
  }
  return 'unsupported';
}

function matchesClaudeModel(model: string, exactModels: string[], prefixes: string[]): boolean {
  if (exactModels.includes(model)) {
    return true;
  }
  for (const prefix of prefixes) {
    if (model.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}
