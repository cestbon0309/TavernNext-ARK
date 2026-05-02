import { JsonArray, JsonRecord, emptyJsonRecord } from '../../../HttpTypes';
import {
  asArrayValue,
  asRecordValue,
  asStringValue,
  cloneJsonValue,
  messageContentToText,
  parseDataUrl,
} from '../../JsonHelpers';
import {
  OpenAiToolCall,
  extractOpenAiToolCalls,
  messageToolCallId,
  messageToolResultText,
} from './ToolCalls';
import { convertOpenAiToolCallsToClaudeBlocks } from './Tools';

const CLAUDE_EMPTY_TEXT_PLACEHOLDER = '\u200b';

export class ClaudeMessageConversion {
  messages: JsonArray = [];
  system: JsonArray = [];
}

export function convertMessages(messagesValue: Object | string | number | boolean | null | JsonArray | undefined,
  useSystemPrompt: boolean, useTools: boolean): ClaudeMessageConversion {
  const conversion = new ClaudeMessageConversion();
  if (typeof messagesValue === 'string') {
    conversion.messages.push(claudeMessage('user', [normalizeClaudeTextBlock(messagesValue)]));
    return conversion;
  }
  const entries = asArrayValue(messagesValue);
  let startIndex = 0;
  if (useSystemPrompt) {
    while (startIndex < entries.length) {
      const item = entries[startIndex];
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        startIndex += 1;
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']).trim().toLowerCase() || 'user';
      if (role !== 'system') {
        break;
      }
      const contentText = messageContentToText(message['content']);
      if (contentText.length > 0) {
        conversion.system.push(normalizeClaudeTextBlock(contentText));
      }
      startIndex += 1;
    }
  }

  for (let index = startIndex; index < entries.length; index += 1) {
    const item = entries[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      continue;
    }
    const message = item as JsonRecord;
    const role = asStringValue(message['role']).trim().toLowerCase() || 'user';
    const name = asStringValue(message['name']).trim();
    if (role === 'assistant') {
      const toolCalls = extractOpenAiToolCalls(message['tool_calls']);
      const contentBlocks = toolCalls.length > 0 ?
        (useTools ? convertOpenAiToolCallsToClaudeBlocks(toolCalls) : toolCallsToTextBlocks(toolCalls)) :
        convertMessageContentToClaudeBlocks(message['content'], name);
      if (contentBlocks.length > 0) {
        conversion.messages.push(claudeMessage('assistant', contentBlocks));
      }
      continue;
    }
    if (role === 'tool') {
      if (!useTools) {
        conversion.messages.push(claudeMessage('user', [normalizeClaudeTextBlock(messageToolResultText(message))]));
      } else {
        const toolUseId = messageToolCallId(message);
        if (toolUseId.length > 0) {
          const block = emptyJsonRecord();
          block['type'] = 'tool_result';
          block['tool_use_id'] = toolUseId;
          block['content'] = messageToolResultText(message);
          conversion.messages.push(claudeMessage('user', [block]));
        } else {
          const blocks = convertMessageContentToClaudeBlocks(message['content'], name);
          conversion.messages.push(claudeMessage('user', blocks.length > 0 ? blocks : [normalizeClaudeTextBlock('')]));
        }
      }
      continue;
    }
    const blocks = convertMessageContentToClaudeBlocks(message['content'], name);
    conversion.messages.push(claudeMessage('user', blocks.length > 0 ? blocks : [normalizeClaudeTextBlock('')]));
  }
  return conversion;
}

export function moveAssistantImagesToNextUserMessage(messages: JsonArray): void {
  let index = 0;
  while (index < messages.length) {
    const item = messages[index];
    if (item === null || Array.isArray(item) || typeof item !== 'object') {
      index += 1;
      continue;
    }
    const message = item as JsonRecord;
    if (asStringValue(message['role']) !== 'assistant') {
      index += 1;
      continue;
    }
    const content = asArrayValue(message['content']);
    const images: JsonArray = [];
    const remaining: JsonArray = [];
    for (const block of content) {
      if (isClaudeImageBlock(block)) {
        images.push(block);
      } else {
        remaining.push(block);
      }
    }
    if (images.length === 0) {
      index += 1;
      continue;
    }
    message['content'] = remaining;
    const removeAssistant = remaining.length === 0;
    let targetIndex = index + 1;
    while (targetIndex < messages.length) {
      const target = messages[targetIndex];
      if (target !== null && !Array.isArray(target) && typeof target === 'object' &&
        asStringValue((target as JsonRecord)['role']) === 'user') {
        break;
      }
      targetIndex += 1;
    }
    if (targetIndex >= messages.length) {
      messages.splice(index + 1, 0, claudeMessage('user', []));
      targetIndex = index + 1;
    }
    const target = messages[targetIndex] as JsonRecord;
    const targetBlocks = asArrayValue(target['content']);
    for (const image of images) {
      targetBlocks.push(image);
    }
    target['content'] = targetBlocks;
    if (removeAssistant) {
      messages.splice(index, 1);
      continue;
    }
    index += 1;
  }
}

export function mergeConsecutiveMessages(messages: JsonArray): JsonArray {
  const merged: JsonArray = [];
  for (const message of messages) {
    if (message === null || Array.isArray(message) || typeof message !== 'object') {
      continue;
    }
    const role = asStringValue((message as JsonRecord)['role']);
    const last = merged.length > 0 ? merged[merged.length - 1] : null;
    if (last !== null && !Array.isArray(last) && typeof last === 'object' &&
      asStringValue((last as JsonRecord)['role']) === role) {
      const lastBlocks = asArrayValue((last as JsonRecord)['content']);
      for (const block of asArrayValue((message as JsonRecord)['content'])) {
        lastBlocks.push(block);
      }
      (last as JsonRecord)['content'] = lastBlocks;
      continue;
    }
    merged.push(message);
  }
  return merged;
}

function convertMessageContentToClaudeBlocks(content: Object | string | number | boolean | null | JsonArray | undefined,
  name: string): JsonArray {
  const blocks: JsonArray = [];
  if (content === undefined || content === null) {
    return blocks;
  }
  if (typeof content === 'string') {
    blocks.push(normalizeClaudeTextBlock(prefixName(content, name)));
    return blocks;
  }
  if (!Array.isArray(content)) {
    blocks.push(normalizeClaudeTextBlock(String(content)));
    return blocks;
  }
  const parts: JsonArray = content;
  for (let index = 0; index < parts.length; index += 1) {
    const part: Object | string | number | boolean | null = parts[index];
    if (typeof part === 'string') {
      blocks.push(normalizeClaudeTextBlock(prefixName(part, name)));
      continue;
    }
    if (part === null || Array.isArray(part) || typeof part !== 'object') {
      continue;
    }
    const record = part as JsonRecord;
    const type = asStringValue(record['type']);
    if (type === 'text') {
      blocks.push(normalizeClaudeTextBlock(prefixName(asStringValue(record['text']), name)));
    } else if (type === 'image_url') {
      const dataUrl = parseDataUrl(asStringValue(asRecordValue(record['image_url'])['url']));
      if (dataUrl === null) {
        throw new Error('Claude expects image_url as a data URL');
      }
      const source = emptyJsonRecord();
      source['type'] = 'base64';
      source['media_type'] = asStringValue(dataUrl['mimeType']);
      source['data'] = asStringValue(dataUrl['data']);
      const block = emptyJsonRecord();
      block['type'] = 'image';
      block['source'] = source;
      blocks.push(block);
    } else {
      blocks.push(cloneJsonValue(part) as Object);
    }
  }
  if (blocks.length === 0) {
    blocks.push(normalizeClaudeTextBlock(''));
  }
  return blocks;
}

function toolCallsToTextBlocks(toolCalls: OpenAiToolCall[]): JsonArray {
  const blocks: JsonArray = [];
  for (const call of toolCalls) {
    blocks.push(normalizeClaudeTextBlock(JSON.stringify(call.arguments)));
  }
  return blocks;
}

function normalizeClaudeTextBlock(text: string): JsonRecord {
  const block = emptyJsonRecord();
  block['type'] = 'text';
  block['text'] = text.length === 0 ? CLAUDE_EMPTY_TEXT_PLACEHOLDER : text;
  return block;
}

function claudeMessage(role: string, content: JsonArray): JsonRecord {
  const message = emptyJsonRecord();
  message['role'] = role;
  message['content'] = content;
  return message;
}

function prefixName(text: string, name: string): string {
  const trimmed = name.trim();
  if (trimmed.length === 0) {
    return text;
  }
  const prefix = `${trimmed}: `;
  return text.startsWith(prefix) ? text : `${prefix}${text}`;
}

function isClaudeImageBlock(value: Object | string | number | boolean | null): boolean {
  return value !== null && !Array.isArray(value) && typeof value === 'object' &&
    asStringValue((value as JsonRecord)['type']) === 'image';
}
