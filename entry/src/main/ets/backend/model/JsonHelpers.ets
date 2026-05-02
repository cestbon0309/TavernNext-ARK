import { JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { ChatJsonValue } from './ChatCompletionTypes';

export function cloneJsonRecord(value: JsonRecord): JsonRecord {
  return JSON.parse(JSON.stringify(value)) as JsonRecord;
}

export function cloneJsonValue(value: ChatJsonValue | JsonArray | undefined): ChatJsonValue {
  if (value === undefined) {
    return null;
  }
  return JSON.parse(JSON.stringify(value)) as ChatJsonValue;
}

export function asStringValue(value: ChatJsonValue | JsonArray | undefined): string {
  if (value === undefined || value === null || Array.isArray(value)) {
    return '';
  }
  return String(value);
}

export function asBooleanValue(value: ChatJsonValue | JsonArray | undefined, fallback: boolean = false): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'string') {
    return value === 'true';
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  return fallback;
}

export function asNumberValue(value: ChatJsonValue | JsonArray | undefined, fallback: number = 0): number {
  if (value === undefined || value === null || Array.isArray(value)) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function asRecordValue(value: ChatJsonValue | JsonArray | undefined): JsonRecord {
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return emptyJsonRecord();
  }
  return value as JsonRecord;
}

export function asArrayValue(value: ChatJsonValue | JsonArray | undefined): JsonArray {
  if (!Array.isArray(value)) {
    return [];
  }
  return value;
}

export function setIfPresent(target: JsonRecord, source: JsonRecord, key: string): void {
  const value = source[key];
  if (value !== undefined && value !== null) {
    target[key] = cloneJsonValue(value);
  }
}

export function setValueIfPresent(target: JsonRecord, key: string, value: ChatJsonValue | JsonArray | undefined): void {
  if (value !== undefined && value !== null) {
    target[key] = cloneJsonValue(value);
  }
}

export function withoutKeys(source: JsonRecord, keys: string[]): JsonRecord {
  const result = emptyJsonRecord();
  Object.keys(source).forEach((key: string) => {
    if (!keys.includes(key)) {
      result[key] = cloneJsonValue(source[key]);
    }
  });
  return result;
}

export function messageContentToText(content: ChatJsonValue | JsonArray | undefined): string {
  if (content === undefined || content === null) {
    return '';
  }
  if (typeof content === 'string') {
    return content;
  }
  if (Array.isArray(content)) {
    let text = '';
    const items: JsonArray = content;
    for (let index = 0; index < items.length; index += 1) {
      const item: Object | string | number | boolean | null = items[index];
      if (typeof item === 'string') {
        text += item;
        continue;
      }
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        const record = item as JsonRecord;
        const fragment = asStringValue(record['text']) || asStringValue(record['content']);
        text += fragment;
      }
    }
    return text;
  }
  return String(content);
}

export function parseDataUrl(value: string): JsonRecord | null {
  const trimmed = value.trim();
  if (!trimmed.startsWith('data:')) {
    return null;
  }
  const comma = trimmed.indexOf(',');
  if (comma < 0) {
    return null;
  }
  const meta = trimmed.slice(5, comma);
  const data = trimmed.slice(comma + 1).trim();
  const parts = meta.split(';');
  if (parts.length !== 2 || parts[1] !== 'base64' || parts[0].trim().length === 0 || data.length === 0) {
    return null;
  }
  const result = emptyJsonRecord();
  result['mimeType'] = parts[0].trim();
  result['data'] = data;
  return result;
}

export function currentUnixTimestamp(): number {
  return Math.floor(Date.now() / 1000);
}
