import { emptyJsonRecord, HttpRequest, JsonArray, JsonRecord } from './HttpTypes';

export type JsonValue = Object | string | number | boolean | null | JsonArray;

export function bodyAsRecord(request: HttpRequest): JsonRecord {
  if (request.body === null || Array.isArray(request.body)) {
    return emptyJsonRecord();
  }
  return request.body as JsonRecord;
}

export function asString(value: JsonValue | JsonArray | undefined): string {
  if (value === undefined || value === null || Array.isArray(value)) {
    return '';
  }
  return `${value}`;
}

export function asNumber(value: JsonValue | JsonArray | undefined, fallback: number = 0): number {
  if (value === undefined || value === null || Array.isArray(value)) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function asBoolean(value: JsonValue | JsonArray | undefined, fallback: boolean = false): boolean {
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

export function asArray(value: JsonValue | JsonArray | undefined): JsonArray {
  if (!Array.isArray(value)) {
    return [];
  }
  return value;
}

export function asRecord(value: JsonValue | JsonArray | undefined): JsonRecord {
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return emptyJsonRecord();
  }
  return value as JsonRecord;
}

export function parseJsonRecord(text: string): JsonRecord {
  if (text.length === 0) {
    return emptyJsonRecord();
  }
  try {
    const value = JSON.parse(text) as Object;
    if (value === null || Array.isArray(value) || typeof value !== 'object') {
      return emptyJsonRecord();
    }
    return value as JsonRecord;
  } catch (_err) {
    return emptyJsonRecord();
  }
}
