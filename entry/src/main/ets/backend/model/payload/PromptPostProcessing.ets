import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { asArrayValue, asStringValue, cloneJsonValue, messageContentToText } from '../JsonHelpers';

type PromptProcessingType = 'none' | 'merge' | 'merge_tools' | 'semi' | 'semi_tools' | 'strict' | 'strict_tools' | 'single';

class PromptNames {
  charName: string = '';
  userName: string = '';
  groupNames: string[] = [];

  startsWithGroupName(content: string): boolean {
    for (const name of this.groupNames) {
      if (name.length > 0 && content.startsWith(`${name}: `)) {
        return true;
      }
    }
    return false;
  }
}

class MergeOptions {
  strict: boolean = false;
  placeholders: boolean = false;
  single: boolean = false;
  tools: boolean = false;
}

class ContentToken {
  token: string;
  media: Object | string | number | boolean | null;

  constructor(token: string, media: Object | string | number | boolean | null) {
    this.token = token;
    this.media = media;
  }
}

const PROMPT_PLACEHOLDER = "Let's get started.";

export function applyCustomPromptPostProcessing(payload: JsonRecord): JsonRecord {
  const processing = parsePromptProcessing(asStringValue(payload['custom_prompt_post_processing']));
  if (processing === 'none') {
    return payload;
  }
  const messages = asArrayValue(payload['messages']);
  if (messages.length === 0) {
    return payload;
  }
  const next = emptyJsonRecord();
  Object.keys(payload).forEach((key: string) => next[key] = cloneJsonValue(payload[key]));
  next['messages'] = postProcessPrompt(messages, processing, promptNamesFromPayload(payload));
  return next;
}

export function postProcessPrompt(messages: JsonArray, processing: PromptProcessingType, names: PromptNames): JsonArray {
  switch (processing) {
    case 'merge':
      return mergeMessages(messages, names, mergeOptions(false, false, false, false));
    case 'merge_tools':
      return mergeMessages(messages, names, mergeOptions(false, false, false, true));
    case 'semi':
      return mergeMessages(messages, names, mergeOptions(true, false, false, false));
    case 'semi_tools':
      return mergeMessages(messages, names, mergeOptions(true, false, false, true));
    case 'strict':
      return mergeMessages(messages, names, mergeOptions(true, true, false, false));
    case 'strict_tools':
      return mergeMessages(messages, names, mergeOptions(true, true, false, true));
    case 'single':
      return mergeMessages(messages, names, mergeOptions(true, false, true, false));
    case 'none':
    default:
      return messages;
  }
}

function parsePromptProcessing(value: string): PromptProcessingType {
  switch (value.trim().toLowerCase()) {
    case 'claude':
    case 'merge':
      return 'merge';
    case 'merge_tools':
      return 'merge_tools';
    case 'semi':
      return 'semi';
    case 'semi_tools':
      return 'semi_tools';
    case 'strict':
      return 'strict';
    case 'strict_tools':
      return 'strict_tools';
    case 'single':
      return 'single';
    default:
      return 'none';
  }
}

function promptNamesFromPayload(payload: JsonRecord): PromptNames {
  const names = new PromptNames();
  names.charName = asStringValue(payload['char_name']).trim();
  names.userName = asStringValue(payload['user_name']).trim();
  for (const item of asArrayValue(payload['group_names'])) {
    if (typeof item === 'string' && item.trim().length > 0) {
      names.groupNames.push(item.trim());
    }
  }
  return names;
}

function mergeOptions(strict: boolean, placeholders: boolean, single: boolean, tools: boolean): MergeOptions {
  const options = new MergeOptions();
  options.strict = strict;
  options.placeholders = placeholders;
  options.single = single;
  options.tools = tools;
  return options;
}

function mergeMessages(messages: JsonArray, names: PromptNames, options: MergeOptions): JsonArray {
  const contentTokens: ContentToken[] = [];
  const normalized: JsonArray = [];
  for (let index = 0; index < messages.length; index += 1) {
    const item = messages[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const message = cloneJsonValue(item) as JsonRecord;
    if (message['content'] === undefined || message['content'] === null) {
      message['content'] = '';
    }
    message['content'] = normalizeMessageContent(message['content'], contentTokens);

    let role = asStringValue(message['role']).trim().toLowerCase();
    if (role.length === 0) {
      role = 'user';
    }
    const name = asStringValue(message['name']).trim();
    let contentText = asStringValue(message['content']);

    if (role === 'system' && name === 'example_assistant') {
      contentText = prefixIfMissing(contentText, names.charName, (content: string): boolean => names.startsWithGroupName(content));
    } else if (role === 'system' && name === 'example_user') {
      contentText = prefixIfMissing(contentText, names.userName, (_content: string): boolean => false);
    } else if (name.length > 0 && role !== 'system') {
      contentText = prefixIfMissing(contentText, name, (_content: string): boolean => false);
    }

    if (role === 'tool' && !options.tools) {
      role = 'user';
    }
    if (options.single) {
      if (role === 'assistant') {
        contentText = prefixIfMissing(contentText, names.charName, (content: string): boolean => names.startsWithGroupName(content));
      } else if (role === 'user') {
        contentText = prefixIfMissing(contentText, names.userName, (_content: string): boolean => false);
      }
      role = 'user';
    }

    message['role'] = role;
    message['content'] = contentText;
    message['name'] = null;
    if (!options.tools) {
      message['tool_calls'] = null;
      message['tool_call_id'] = null;
    }
    normalized.push(omitNullKeys(message));
  }

  const merged: JsonArray = [];
  for (let index = 0; index < normalized.length; index += 1) {
    const message = normalized[index];
    if (canMergeWithLast(merged, message)) {
      const current = message as JsonRecord;
      const last = merged[merged.length - 1] as JsonRecord;
      last['content'] = `${asStringValue(last['content'])}\n\n${asStringValue(current['content'])}`;
      continue;
    }
    merged.push(message);
  }

  if (merged.length === 0) {
    merged.push(messageRecord('user', PROMPT_PLACEHOLDER));
  }

  restoreMediaContent(merged, contentTokens);

  if (options.strict) {
    for (let index = 0; index < merged.length; index += 1) {
      if (index === 0) {
        continue;
      }
      const item = merged[index];
      if (item !== null && !Array.isArray(item) && typeof item === 'object') {
        const message = item as JsonRecord;
        if (asStringValue(message['role']) === 'system') {
          message['role'] = 'user';
        }
      }
    }
    if (options.placeholders && merged.length > 0) {
      const first = merged[0] as JsonRecord;
      const firstRole = asStringValue(first['role']);
      const secondRole = merged.length > 1 && merged[1] !== null && !Array.isArray(merged[1]) &&
        typeof merged[1] === 'object' ? asStringValue((merged[1] as JsonRecord)['role']) : '';
      if (firstRole === 'system' && secondRole !== 'user') {
        merged.splice(1, 0, messageRecord('user', PROMPT_PLACEHOLDER));
      } else if (firstRole !== 'system' && firstRole !== 'user') {
        merged.splice(0, 0, messageRecord('user', PROMPT_PLACEHOLDER));
      }
    }
    return mergeMessages(merged, names, mergeOptions(false, options.placeholders, false, options.tools));
  }

  return merged;
}

function normalizeMessageContent(value: Object | string | number | boolean | null | JsonArray | undefined,
  contentTokens: ContentToken[]): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (!Array.isArray(value)) {
    return typeof value === 'string' ? value : String(value);
  }
  const segments: string[] = [];
  const parts: JsonArray = value;
  for (let index = 0; index < parts.length; index += 1) {
    const part: Object | string | number | boolean | null = parts[index];
    if (typeof part === 'string') {
      segments.push(part);
      continue;
    }
    if (part === null || Array.isArray(part) || typeof part !== 'object') {
      segments.push('');
      continue;
    }
    const record = part as JsonRecord;
    const type = asStringValue(record['type']);
    if (type === 'text') {
      segments.push(asStringValue(record['text']));
    } else if (type === 'image_url' || type === 'video_url' || type === 'audio_url') {
      const token = `__TAURITAVERN_MEDIA_TOKEN_${Date.now()}_${contentTokens.length}__`;
      contentTokens.push(new ContentToken(token, cloneJsonValue(part)));
      segments.push(token);
    } else {
      segments.push('');
    }
  }
  return segments.join('\n\n');
}

function restoreMediaContent(messages: JsonArray, contentTokens: ContentToken[]): void {
  if (contentTokens.length === 0) {
    return;
  }
  for (let index = 0; index < messages.length; index += 1) {
    const item = messages[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const message = item as JsonRecord;
    const content = asStringValue(message['content']);
    if (!containsMediaToken(content, contentTokens)) {
      continue;
    }
    const parts: JsonArray = [];
    const segments = content.split('\n\n');
    for (const segment of segments) {
      const token = findToken(segment, contentTokens);
      if (token !== null) {
        parts.push(cloneJsonValue(token.media) as Object);
        continue;
      }
      const last = parts.length > 0 ? parts[parts.length - 1] : null;
      if (last !== null && !Array.isArray(last) && typeof last === 'object' &&
        asStringValue((last as JsonRecord)['type']) === 'text') {
        const lastRecord = last as JsonRecord;
        lastRecord['text'] = `${asStringValue(lastRecord['text'])}\n\n${segment}`;
      } else {
        const text = emptyJsonRecord();
        text['type'] = 'text';
        text['text'] = segment;
        parts.push(text);
      }
    }
    message['content'] = parts;
  }
}

function containsMediaToken(content: string, tokens: ContentToken[]): boolean {
  for (const token of tokens) {
    if (content.includes(token.token)) {
      return true;
    }
  }
  return false;
}

function findToken(segment: string, tokens: ContentToken[]): ContentToken | null {
  for (const token of tokens) {
    if (token.token === segment) {
      return token;
    }
  }
  return null;
}

function canMergeWithLast(merged: JsonArray, message: Object | string | number | boolean | null): boolean {
  if (message === null || Array.isArray(message) || typeof message !== 'object' || merged.length === 0) {
    return false;
  }
  const current = message as JsonRecord;
  const currentRole = asStringValue(current['role']);
  if (currentRole === 'tool' || asStringValue(current['content']).length === 0) {
    return false;
  }
  const last = merged[merged.length - 1];
  return last !== null && !Array.isArray(last) && typeof last === 'object' &&
    asStringValue((last as JsonRecord)['role']) === currentRole;
}

function prefixIfMissing(content: string, prefix: string, shouldSkip: (content: string) => boolean): string {
  const trimmed = prefix.trim();
  if (trimmed.length === 0) {
    return content;
  }
  const decorated = `${trimmed}: `;
  if (content.startsWith(decorated) || shouldSkip(content)) {
    return content;
  }
  return `${decorated}${content}`;
}

function messageRecord(role: string, content: string): JsonRecord {
  const message = emptyJsonRecord();
  message['role'] = role;
  message['content'] = content;
  return message;
}

function omitNullKeys(source: JsonRecord): JsonRecord {
  const next = emptyJsonRecord();
  Object.keys(source).forEach((key: string) => {
    if (source[key] !== null && source[key] !== undefined) {
      next[key] = source[key];
    }
  });
  return next;
}
