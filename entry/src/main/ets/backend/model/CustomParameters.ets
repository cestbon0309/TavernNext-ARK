import { JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { asStringValue } from './JsonHelpers';

export class CustomParameters {
  parseStringMap(raw: string): Record<string, string> {
    const object = this.parseObject(raw);
    const result: Record<string, string> = {};
    Object.keys(object).forEach((key: string) => {
      const trimmedKey = key.trim();
      if (trimmedKey.length === 0 || object[key] === null || object[key] === undefined) {
        return;
      }
      const value = asStringValue(object[key]).trim();
      if (value.length > 0) {
        result[trimmedKey] = value;
      }
    });
    return result;
  }

  parseObject(raw: string): JsonRecord {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return emptyJsonRecord();
    }
    try {
      const parsed = JSON.parse(trimmed) as Object;
      return this.objectFromParsed(parsed);
    } catch (_err) {
    }
    return this.parseSimpleYamlObject(trimmed);
  }

  parseKeyList(raw: string): string[] {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(trimmed) as Object | string | number | boolean | null | JsonArray;
      if (Array.isArray(parsed)) {
        return (parsed as JsonArray).map((value: Object | string | number | boolean | null): string => String(value).trim())
          .filter((value: string): boolean => value.length > 0);
      }
      if (parsed !== null && typeof parsed === 'object') {
        return Object.keys(parsed as JsonRecord).map((key: string): string => key.trim())
          .filter((key: string): boolean => key.length > 0);
      }
      if (typeof parsed === 'string') {
        return parsed.trim().length > 0 ? [parsed.trim()] : [];
      }
    } catch (_err) {
    }
    const keys: string[] = [];
    for (const line of this.yamlLines(trimmed)) {
      const normalized = line.startsWith('-') ? line.slice(1).trim() : line;
      const colon = normalized.indexOf(':');
      keys.push((colon > 0 ? normalized.slice(0, colon) : normalized).trim());
    }
    return keys.filter((key: string): boolean => key.length > 0);
  }

  private objectFromParsed(parsed: Object | string | number | boolean | null | JsonArray): JsonRecord {
    if (parsed === null || parsed === undefined) {
      return emptyJsonRecord();
    }
    if (Array.isArray(parsed)) {
      const merged = emptyJsonRecord();
      for (const item of parsed as Object[]) {
        if (item !== null && !Array.isArray(item) && typeof item === 'object') {
          const record = item as JsonRecord;
          Object.keys(record).forEach((key: string) => merged[key] = record[key]);
        }
      }
      return merged;
    }
    if (typeof parsed === 'object') {
      return parsed as JsonRecord;
    }
    return emptyJsonRecord();
  }

  private parseSimpleYamlObject(text: string): JsonRecord {
    const result = emptyJsonRecord();
    for (const line of this.yamlLines(text)) {
      const index = line.indexOf(':');
      if (index <= 0) {
        continue;
      }
      const key = line.slice(0, index).trim();
      if (key.length === 0) {
        continue;
      }
      result[key] = this.parseScalar(line.slice(index + 1).trim());
    }
    return result;
  }

  private yamlLines(text: string): string[] {
    return text.split('\n')
      .map((line: string): string => line.trim())
      .filter((line: string): boolean => line.length > 0 && !line.startsWith('#'));
  }

  private parseScalar(value: string): Object | string | number | boolean | null {
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        return value.slice(1, value.length - 1);
      }
    }
    if (value === 'true') {
      return true;
    }
    if (value === 'false') {
      return false;
    }
    if (value === 'null') {
      return null;
    }
    if (value.startsWith('{') || value.startsWith('[')) {
      try {
        return JSON.parse(value) as Object;
      } catch (_err) {
      }
    }
    const parsed = Number(value);
    if (value.length > 0 && Number.isFinite(parsed)) {
      return parsed;
    }
    return value;
  }
}
