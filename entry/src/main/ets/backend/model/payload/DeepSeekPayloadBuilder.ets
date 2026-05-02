import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asArrayValue, asBooleanValue, asRecordValue, asStringValue } from '../JsonHelpers';
import { OpenAiPayloadBuilder } from './OpenAiPayloadBuilder';
import { omitKeys } from './Shared';

export class DeepSeekPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const built = new OpenAiPayloadBuilder('deepseek').build(payload);
    if (built.endpointPath !== '/chat/completions') {
      return built;
    }
    let body = built.body;
    const mode = this.thinkingMode(payload);
    if (mode.length > 0) {
      const thinking = emptyJsonRecord();
      thinking['type'] = mode;
      const effort = this.deepSeekReasoningEffort(asStringValue(payload['reasoning_effort']));
      if (effort.length > 0 && mode === 'enabled') {
        thinking['effort'] = effort;
      }
      body['thinking'] = thinking;
      if (mode === 'enabled') {
        body = omitKeys(body, ['temperature', 'top_p', 'presence_penalty', 'frequency_penalty']);
        built.body = body;
      }
    }
    this.ensureReasoningContent(body);
    this.addAssistantPrefix(body);
    this.dropEmptyRequiredArrays(body);
    return built;
  }

  private thinkingMode(payload: JsonRecord): string {
    const model = asStringValue(payload['model']).trim().toLowerCase();
    if (model === 'deepseek-chat') {
      return 'disabled';
    }
    if (model === 'deepseek-reasoner' || model.startsWith('deepseek-r1')) {
      return 'enabled';
    }
    if (model.startsWith('deepseek-v4') && payload['include_reasoning'] !== undefined) {
      return asBooleanValue(payload['include_reasoning']) ? 'enabled' : 'disabled';
    }
    return '';
  }

  private deepSeekReasoningEffort(raw: string): string {
    switch (raw.trim().toLowerCase()) {
      case 'max':
      case 'xhigh':
        return 'max';
      case 'min':
      case 'low':
      case 'medium':
      case 'high':
        return 'high';
      default:
        return '';
    }
  }

  private ensureReasoningContent(body: JsonRecord): void {
    const messages = asArrayValue(body['messages']);
    for (const item of messages) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      if (asStringValue(message['role']) === 'assistant' && message['reasoning_content'] === undefined) {
        message['reasoning_content'] = '';
      }
    }
  }

  private addAssistantPrefix(body: JsonRecord): void {
    const messages = asArrayValue(body['messages']);
    if (messages.length === 0 || asArrayValue(body['tools']).length > 0) {
      return;
    }
    for (const item of messages) {
      if (item !== null && !Array.isArray(item) && typeof item === 'object' &&
        asStringValue((item as JsonRecord)['role']) === 'tool') {
        return;
      }
    }
    const last = messages[messages.length - 1];
    if (last !== null && !Array.isArray(last) && typeof last === 'object' &&
      asStringValue((last as JsonRecord)['role']) === 'assistant') {
      (last as JsonRecord)['prefix'] = true;
    }
  }

  private dropEmptyRequiredArrays(body: JsonRecord): void {
    const tools = asArrayValue(body['tools']);
    for (const item of tools) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const fn = asRecordValue((item as JsonRecord)['function']);
      const parameters = asRecordValue(fn['parameters']);
      const required = parameters['required'];
      if (Array.isArray(required) && (required as JsonArray).length === 0) {
        fn['parameters'] = omitKeys(parameters, ['required']);
      }
    }
  }
}
