import { JsonRecord } from '../../../HttpTypes';
import { asNumberValue } from '../../JsonHelpers';

const CLAUDE_DEFAULT_TEMPERATURE = 1.0;
const CLAUDE_DEFAULT_TOP_P = 1.0;
const CLAUDE_DEFAULT_TOP_K = 0.0;

export function valueToInteger(value: Object | string | number | boolean | null | undefined): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : null;
  }
  return null;
}

export function hasNonDefaultTemperature(payload: JsonRecord): boolean {
  return numericFieldDiffersFromDefault(payload, 'temperature', CLAUDE_DEFAULT_TEMPERATURE);
}

export function hasNonDefaultTopP(payload: JsonRecord): boolean {
  return numericFieldDiffersFromDefault(payload, 'top_p', CLAUDE_DEFAULT_TOP_P);
}

export function hasNonDefaultTopK(payload: JsonRecord): boolean {
  return numericFieldDiffersFromDefault(payload, 'top_k', CLAUDE_DEFAULT_TOP_K);
}

export function collectNonDefaultSamplingParams(payload: JsonRecord): string[] {
  const params: string[] = [];
  if (hasNonDefaultTemperature(payload)) {
    params.push('temperature');
  }
  if (hasNonDefaultTopP(payload)) {
    params.push('top_p');
  }
  if (hasNonDefaultTopK(payload)) {
    params.push('top_k');
  }
  return params;
}

function numericFieldDiffersFromDefault(payload: JsonRecord, key: string, defaultValue: number): boolean {
  if (payload[key] === undefined || payload[key] === null) {
    return false;
  }
  return Math.abs(asNumberValue(payload[key], defaultValue) - defaultValue) > Number.EPSILON;
}
