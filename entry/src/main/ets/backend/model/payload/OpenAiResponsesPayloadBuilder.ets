import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asArrayValue, asRecordValue, asStringValue, messageContentToText, setIfPresent } from '../JsonHelpers';
import { applyCustomBodyOverrides, buildResponseFormatFromJsonSchema, openAiToolsToFunctionTools } from './Shared';

export class OpenAiResponsesPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    let body = this.buildBody(payload);
    body = applyCustomBodyOverrides(body, asStringValue(payload['custom_include_body']),
      asStringValue(payload['custom_exclude_body']));
    return new BuiltChatPayload('/responses', body);
  }

  private buildBody(payload: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    request['model'] = asStringValue(payload['model']);
    request['input'] = this.inputItems(payload);
    request['store'] = false;
    if (payload['max_tokens'] !== undefined || payload['max_completion_tokens'] !== undefined) {
      request['max_output_tokens'] = payload['max_completion_tokens'] ?? payload['max_tokens'];
    }
    setIfPresent(request, payload, 'temperature');
    setIfPresent(request, payload, 'top_p');
    setIfPresent(request, payload, 'stream');
    const tools = openAiToolsToFunctionTools(payload['tools']);
    if (tools.length > 0) {
      request['tools'] = tools;
    }
    setIfPresent(request, payload, 'tool_choice');
    const responseFormat = buildResponseFormatFromJsonSchema(payload);
    if (responseFormat !== null) {
      request['text'] = responseFormat;
    }
    const effort = asStringValue(payload['reasoning_effort']).trim();
    if (effort.length > 0 && effort !== 'auto') {
      const reasoning = emptyJsonRecord();
      reasoning['effort'] = effort === 'min' ? 'minimal' : effort;
      request['reasoning'] = reasoning;
    }
    return request;
  }

  private inputItems(payload: JsonRecord): JsonArray {
    const result: JsonArray = [];
    for (const item of asArrayValue(payload['messages'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']);
      if (role === 'tool') {
        const output = emptyJsonRecord();
        output['type'] = 'function_call_output';
        output['call_id'] = asStringValue(message['tool_call_id']);
        output['output'] = messageContentToText(message['content']);
        result.push(output);
        continue;
      }
      const next = emptyJsonRecord();
      next['role'] = role === 'system' ? 'developer' : role;
      next['content'] = this.content(message);
      result.push(next);
    }
    return result;
  }

  private content(message: JsonRecord): JsonArray {
    const result: JsonArray = [];
    const text = messageContentToText(message['content']);
    const item = emptyJsonRecord();
    item['type'] = 'input_text';
    item['text'] = text;
    result.push(item);
    for (const call of asArrayValue(message['tool_calls'])) {
      if (call === null || Array.isArray(call) || typeof call !== 'object') {
        continue;
      }
      const callRecord = call as JsonRecord;
      const fn = asRecordValue(callRecord['function']);
      const next = emptyJsonRecord();
      next['type'] = 'function_call';
      next['call_id'] = asStringValue(callRecord['id']);
      next['name'] = asStringValue(fn['name']);
      next['arguments'] = asStringValue(fn['arguments']);
      result.push(next);
    }
    return result;
  }
}
