import { JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { asStringValue } from './JsonHelpers';

type CustomJsonValue = Object | string | number | boolean | null | JsonArray;

class YamlLine {
  indent: number = 0;
  text: string = '';
}

class YamlState {
  index: number = 0;
}

class KeyValueSplit {
  key: string = '';
  value: string = '';
}

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
      const parsed = JSON.parse(trimmed) as Object | string | number | boolean | null | JsonArray;
      return this.objectFromParsed(parsed);
    } catch (_err) {
    }
    const parsedYaml = this.parseYaml(trimmed);
    return this.objectFromParsed(parsedYaml);
  }

  parseKeyList(raw: string): string[] {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(trimmed) as Object | string | number | boolean | null | JsonArray;
      return this.keysFromValue(parsed);
    } catch (_err) {
    }
    return this.keysFromValue(this.parseYaml(trimmed));
  }

  private keysFromValue(value: CustomJsonValue | undefined): string[] {
    if (value === undefined || value === null) {
      return [];
    }
    if (Array.isArray(value)) {
      const keys: string[] = [];
      const items: JsonArray = value;
      for (let index = 0; index < items.length; index += 1) {
        const item: Object | string | number | boolean | null = items[index];
        if (item === null) {
          continue;
        }
        if (Array.isArray(item)) {
          for (const nested of this.keysFromValue(item)) {
            keys.push(nested);
          }
          continue;
        }
        if (typeof item === 'object') {
          const record = item as JsonRecord;
          Object.keys(record).forEach((key: string) => keys.push(key.trim()));
          continue;
        }
        const text = `${item}`.trim();
        if (text.length > 0) {
          const colon = text.indexOf(':');
          keys.push((colon > 0 ? text.slice(0, colon) : text).trim());
        }
      }
      return keys.filter((key: string): boolean => key.length > 0);
    }
    if (typeof value === 'object') {
      return Object.keys(value as JsonRecord).map((key: string): string => key.trim())
        .filter((key: string): boolean => key.length > 0);
    }
    const text = `${value}`.trim();
    return text.length > 0 ? [text] : [];
  }

  private objectFromParsed(parsed: CustomJsonValue | undefined): JsonRecord {
    if (parsed === null || parsed === undefined) {
      return emptyJsonRecord();
    }
    if (Array.isArray(parsed)) {
      const merged = emptyJsonRecord();
      const items: JsonArray = parsed;
      for (let index = 0; index < items.length; index += 1) {
        const item: Object | string | number | boolean | null = items[index];
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

  private parseYaml(text: string): CustomJsonValue {
    const lines = this.yamlLines(text);
    if (lines.length === 0) {
      return emptyJsonRecord();
    }
    const state = new YamlState();
    return this.parseBlock(lines, state, lines[0].indent);
  }

  private parseBlock(lines: YamlLine[], state: YamlState, indent: number): CustomJsonValue {
    if (state.index >= lines.length) {
      return emptyJsonRecord();
    }
    if (lines[state.index].text.startsWith('-')) {
      return this.parseSequence(lines, state, indent);
    }
    return this.parseMapping(lines, state, indent);
  }

  private parseMapping(lines: YamlLine[], state: YamlState, indent: number): JsonRecord {
    const result = emptyJsonRecord();
    while (state.index < lines.length) {
      const line = lines[state.index];
      if (line.indent < indent) {
        break;
      }
      if (line.indent > indent) {
        state.index += 1;
        continue;
      }
      if (line.text.startsWith('-')) {
        break;
      }
      const split = this.splitKeyValue(line.text);
      if (split.key.length === 0) {
        state.index += 1;
        continue;
      }
      state.index += 1;
      if (split.value.length > 0) {
        result[split.key] = this.parseScalar(split.value);
        continue;
      }
      if (state.index < lines.length && lines[state.index].indent > line.indent) {
        result[split.key] = this.parseBlock(lines, state, lines[state.index].indent);
      } else {
        result[split.key] = null;
      }
    }
    return result;
  }

  private parseSequence(lines: YamlLine[], state: YamlState, indent: number): JsonArray {
    const result: JsonArray = [];
    while (state.index < lines.length) {
      const line = lines[state.index];
      if (line.indent < indent || line.indent > indent || !line.text.startsWith('-')) {
        break;
      }
      const valueText = line.text.slice(1).trim();
      state.index += 1;
      if (valueText.length === 0) {
        if (state.index < lines.length && lines[state.index].indent > line.indent) {
          result.push(this.parseBlock(lines, state, lines[state.index].indent));
        } else {
          result.push(null);
        }
        continue;
      }
      const split = this.splitKeyValue(valueText);
      if (split.key.length > 0 && valueText.indexOf(':') > 0 && !this.scalarLikeUrl(valueText)) {
        const record = emptyJsonRecord();
        record[split.key] = split.value.length > 0 ? this.parseScalar(split.value) :
          (state.index < lines.length && lines[state.index].indent > line.indent ?
            this.parseBlock(lines, state, lines[state.index].indent) : null);
        while (state.index < lines.length && lines[state.index].indent > line.indent) {
          const nested = lines[state.index];
          if (nested.text.startsWith('-')) {
            break;
          }
          const nestedSplit = this.splitKeyValue(nested.text);
          state.index += 1;
          if (nestedSplit.key.length === 0) {
            continue;
          }
          if (nestedSplit.value.length > 0) {
            record[nestedSplit.key] = this.parseScalar(nestedSplit.value);
          } else if (state.index < lines.length && lines[state.index].indent > nested.indent) {
            record[nestedSplit.key] = this.parseBlock(lines, state, lines[state.index].indent);
          } else {
            record[nestedSplit.key] = null;
          }
        }
        result.push(record);
      } else {
        result.push(this.parseScalar(valueText));
      }
    }
    return result;
  }

  private yamlLines(text: string): YamlLine[] {
    const rawLines = text.replace(/\r\n/g, '\n').split('\n');
    const result: YamlLine[] = [];
    for (const raw of rawLines) {
      const noComment = this.stripComment(raw);
      if (noComment.trim().length === 0) {
        continue;
      }
      const line = new YamlLine();
      line.indent = this.indentWidth(noComment);
      line.text = noComment.trim();
      result.push(line);
    }
    return result;
  }

  private indentWidth(value: string): number {
    let width = 0;
    for (let index = 0; index < value.length; index += 1) {
      const char = value.charAt(index);
      if (char === ' ') {
        width += 1;
      } else if (char === '\t') {
        width += 2;
      } else {
        break;
      }
    }
    return width;
  }

  private stripComment(line: string): string {
    let quote = '';
    let escaped = false;
    for (let index = 0; index < line.length; index += 1) {
      const char = line.charAt(index);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === '\\') {
        escaped = true;
        continue;
      }
      if (quote.length > 0) {
        if (char === quote) {
          quote = '';
        }
        continue;
      }
      if (char === '"' || char === '\'') {
        quote = char;
        continue;
      }
      if (char === '#') {
        if (index === 0 || /\s/.test(line.charAt(index - 1))) {
          return line.slice(0, index);
        }
      }
    }
    return line;
  }

  private splitKeyValue(text: string): KeyValueSplit {
    let quote = '';
    let depth = 0;
    for (let index = 0; index < text.length; index += 1) {
      const char = text.charAt(index);
      if (quote.length > 0) {
        if (char === quote && text.charAt(index - 1) !== '\\') {
          quote = '';
        }
        continue;
      }
      if (char === '"' || char === '\'') {
        quote = char;
        continue;
      }
      if (char === '{' || char === '[') {
        depth += 1;
        continue;
      }
      if (char === '}' || char === ']') {
        depth = Math.max(0, depth - 1);
        continue;
      }
      if (char === ':' && depth === 0) {
        const result = new KeyValueSplit();
        result.key = this.unquote(text.slice(0, index).trim());
        result.value = text.slice(index + 1).trim();
        return result;
      }
    }
    const result = new KeyValueSplit();
    result.value = text.trim();
    return result;
  }

  private parseScalar(value: string): CustomJsonValue {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed === 'true' || trimmed === 'True' || trimmed === 'TRUE') {
      return true;
    }
    if (trimmed === 'false' || trimmed === 'False' || trimmed === 'FALSE') {
      return false;
    }
    if (trimmed === 'null' || trimmed === 'Null' || trimmed === 'NULL' || trimmed === '~') {
      return null;
    }
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return this.parseInlineMap(trimmed.slice(1, trimmed.length - 1));
    }
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      return this.parseInlineList(trimmed.slice(1, trimmed.length - 1));
    }
    if (trimmed.length >= 2) {
      const first = trimmed.charAt(0);
      const last = trimmed.charAt(trimmed.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        return this.unescapeQuoted(trimmed.slice(1, trimmed.length - 1), first);
      }
    }
    const parsed = Number(trimmed);
    if (this.isNumberLiteral(trimmed) && Number.isFinite(parsed)) {
      return parsed;
    }
    return trimmed;
  }

  private parseInlineMap(value: string): JsonRecord {
    const record = emptyJsonRecord();
    const parts = this.splitInline(value);
    for (const part of parts) {
      const split = this.splitKeyValue(part);
      if (split.key.length > 0) {
        record[split.key] = this.parseScalar(split.value);
      }
    }
    return record;
  }

  private parseInlineList(value: string): JsonArray {
    const result: JsonArray = [];
    const parts = this.splitInline(value);
    for (const part of parts) {
      if (part.trim().length > 0) {
        result.push(this.parseScalar(part));
      }
    }
    return result;
  }

  private splitInline(value: string): string[] {
    const result: string[] = [];
    let quote = '';
    let depth = 0;
    let start = 0;
    for (let index = 0; index < value.length; index += 1) {
      const char = value.charAt(index);
      if (quote.length > 0) {
        if (char === quote && value.charAt(index - 1) !== '\\') {
          quote = '';
        }
        continue;
      }
      if (char === '"' || char === '\'') {
        quote = char;
        continue;
      }
      if (char === '{' || char === '[') {
        depth += 1;
        continue;
      }
      if (char === '}' || char === ']') {
        depth = Math.max(0, depth - 1);
        continue;
      }
      if (char === ',' && depth === 0) {
        result.push(value.slice(start, index).trim());
        start = index + 1;
      }
    }
    result.push(value.slice(start).trim());
    return result;
  }

  private unquote(value: string): string {
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        return this.unescapeQuoted(value.slice(1, value.length - 1), first);
      }
    }
    return value;
  }

  private unescapeQuoted(value: string, quote: string): string {
    if (quote === '\'') {
      return value.replace(/''/g, '\'');
    }
    return value.replace(/\\"/g, '"').replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\\\/g, '\\');
  }

  private isNumberLiteral(value: string): boolean {
    return /^[-+]?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/.test(value);
  }

  private scalarLikeUrl(value: string): boolean {
    return /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value);
  }
}
