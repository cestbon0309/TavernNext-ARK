import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { ChatStreamSend } from '../ChatCompletionTypes';
import { asArrayValue, asRecordValue, asStringValue, currentUnixTimestamp } from '../JsonHelpers';

export class OpenAiResponsesStreamNormalizer {
  private created: number = currentUnixTimestamp();
  private model: string = '';
  private responseId: string = '';
  private sentRole: boolean = false;
  private sawToolCall: boolean = false;
  private doneSent: boolean = false;
  private callIdByItemId: Record<string, string> = {};
  private nameByItemId: Record<string, string> = {};
  private callIdByOutputIndex: Record<string, string> = {};

  constructor(model: string) {
    this.model = model;
  }

  async handleEvent(rawPayload: string, send: ChatStreamSend): Promise<void> {
    if (this.doneSent) {
      return;
    }
    const event = this.parseEvent(rawPayload);
    if (event === null) {
      return;
    }
    const type = asStringValue(event['type']);
    if (type === 'response.output_text.delta' || type === 'response.text.delta') {
      const delta = asStringValue(event['delta']);
      if (delta.length > 0) {
        await this.sendDelta(send, this.deltaText('content', delta), '');
      }
      return;
    }
    if (type === 'response.reasoning_text.delta' || type === 'response.reasoning_summary_text.delta' ||
      type === 'response.reasoning.delta') {
      const delta = asStringValue(event['delta']);
      if (delta.length > 0) {
        await this.sendDelta(send, this.deltaText('reasoning_content', delta), '');
      }
      return;
    }
    if (type === 'response.output_item.added') {
      await this.handleOutputItemAdded(event, send);
      return;
    }
    if (type === 'response.function_call_arguments.delta') {
      await this.handleFunctionArgumentsDelta(event, send);
      return;
    }
    if (type === 'response.function_call_arguments.done') {
      await this.handleFunctionArgumentsDone(event, send);
      return;
    }
    if (type === 'response.completed' || type === 'response.done' || type === 'response.incomplete') {
      await this.finish(send, this.sawToolCall ? 'tool_calls' : 'stop');
      return;
    }
    if (type === 'response.failed' || type === 'error') {
      const message = this.errorMessage(event, 'OpenAI Responses stream failed');
      await send(JSON.stringify(this.errorPayload(message)));
      await send('data: [DONE]\n\n');
      this.doneSent = true;
    }
  }

  private async handleOutputItemAdded(event: JsonRecord, send: ChatStreamSend): Promise<void> {
    const item = asRecordValue(event['item']);
    if (asStringValue(item['type']) !== 'function_call') {
      return;
    }
    const responseId = asStringValue(event['response_id']).trim();
    const callId = asStringValue(item['call_id']).trim();
    const itemId = asStringValue(item['id']).trim();
    if (responseId.length === 0 || callId.length === 0 || itemId.length === 0) {
      return;
    }
    this.responseId = responseId;
    this.sawToolCall = true;
    const outputIndex = this.outputIndex(event);
    this.callIdByItemId[itemId] = callId;
    this.nameByItemId[itemId] = asStringValue(item['name']).trim() || 'tool';
    this.callIdByOutputIndex[`${outputIndex}`] = callId;
    await this.sendDelta(send, this.toolCallDelta(outputIndex, callId, this.nameByItemId[itemId], ''), '');
  }

  private async handleFunctionArgumentsDelta(event: JsonRecord, send: ChatStreamSend): Promise<void> {
    const delta = asStringValue(event['delta']);
    if (delta.length === 0) {
      return;
    }
    const outputIndex = this.outputIndex(event);
    const itemId = asStringValue(event['item_id']).trim();
    const callId = itemId.length > 0 && this.callIdByItemId[itemId] !== undefined ?
      this.callIdByItemId[itemId] : (this.callIdByOutputIndex[`${outputIndex}`] ?? '');
    if (callId.length === 0) {
      return;
    }
    await this.sendDelta(send, this.toolCallDelta(outputIndex, callId, '', delta), '');
  }

  private async handleFunctionArgumentsDone(event: JsonRecord, send: ChatStreamSend): Promise<void> {
    const outputIndex = this.outputIndex(event);
    const itemId = asStringValue(event['item_id']).trim();
    const callId = itemId.length > 0 && this.callIdByItemId[itemId] !== undefined ?
      this.callIdByItemId[itemId] : asStringValue(event['call_id']).trim();
    if (callId.length === 0) {
      return;
    }
    const name = itemId.length > 0 && this.nameByItemId[itemId] !== undefined ?
      this.nameByItemId[itemId] : (asStringValue(event['name']).trim() || 'tool');
    const args = asStringValue(event['arguments']);
    if (args.length > 0) {
      await this.sendDelta(send, this.toolCallDelta(outputIndex, callId, name, args), '');
    }
  }

  private async sendDelta(send: ChatStreamSend, delta: JsonRecord, finishReason: string): Promise<void> {
    if (!this.sentRole) {
      this.sentRole = true;
      await send(this.sse(this.chunk(this.deltaText('role', 'assistant'), '')));
    }
    await send(this.sse(this.chunk(delta, finishReason)));
  }

  private async finish(send: ChatStreamSend, finishReason: string): Promise<void> {
    await this.sendDelta(send, emptyJsonRecord(), finishReason);
    await send('data: [DONE]\n\n');
    this.doneSent = true;
  }

  private chunk(delta: JsonRecord, finishReason: string): JsonRecord {
    const choice = emptyJsonRecord();
    choice['index'] = 0;
    choice['delta'] = delta;
    choice['finish_reason'] = finishReason.length > 0 ? finishReason : null;
    const chunk = emptyJsonRecord();
    chunk['id'] = this.responseId.length > 0 ? this.responseId : 'openai-responses-stream';
    chunk['object'] = 'chat.completion.chunk';
    chunk['created'] = this.created;
    chunk['model'] = this.model;
    chunk['choices'] = [choice];
    return chunk;
  }

  private toolCallDelta(index: number, id: string, name: string, args: string): JsonRecord {
    const fn = emptyJsonRecord();
    if (name.length > 0) {
      fn['name'] = name;
    }
    fn['arguments'] = args;
    const toolCall = emptyJsonRecord();
    toolCall['index'] = index;
    toolCall['id'] = id;
    toolCall['type'] = 'function';
    toolCall['function'] = fn;
    const delta = emptyJsonRecord();
    delta['tool_calls'] = [toolCall];
    return delta;
  }

  private deltaText(key: string, value: string): JsonRecord {
    const delta = emptyJsonRecord();
    delta[key] = value;
    return delta;
  }

  private outputIndex(event: JsonRecord): number {
    const value = Number(event['output_index']);
    return Number.isFinite(value) ? Math.trunc(value) : 0;
  }

  private sse(payload: JsonRecord): string {
    return `data: ${JSON.stringify(payload)}\n\n`;
  }

  private errorMessage(event: JsonRecord, fallback: string): string {
    const response = asRecordValue(event['response']);
    const responseError = asRecordValue(response['error']);
    const directError = asRecordValue(event['error']);
    return asStringValue(responseError['message']) || asStringValue(directError['message']) || fallback;
  }

  private errorPayload(message: string): JsonRecord {
    const value = emptyJsonRecord();
    const error = emptyJsonRecord();
    error['message'] = message;
    value['error'] = error;
    return value;
  }

  private parseEvent(rawPayload: string): JsonRecord | null {
    try {
      const parsed = JSON.parse(rawPayload) as Object;
      if (parsed !== null && !Array.isArray(parsed) && typeof parsed === 'object') {
        return parsed as JsonRecord;
      }
    } catch (_err) {
    }
    return null;
  }
}

export class GeminiInteractionsStreamNormalizer {
  private created: number = currentUnixTimestamp();
  private model: string = '';
  private interactionId: string = '';
  private sentRole: boolean = false;
  private sawToolCall: boolean = false;
  private doneSent: boolean = false;
  private outputsByIndex: Record<string, JsonRecord> = {};

  constructor(model: string) {
    this.model = model;
  }

  async handleEvent(rawPayload: string, send: ChatStreamSend): Promise<void> {
    if (this.doneSent) {
      return;
    }
    const event = this.parseEvent(rawPayload);
    if (event === null) {
      return;
    }
    const eventType = asStringValue(event['event_type']);
    if (eventType === 'interaction.start') {
      const interaction = asRecordValue(event['interaction']);
      const id = asStringValue(interaction['id']).trim();
      if (id.length > 0) {
        this.interactionId = id;
      }
      return;
    }
    if (eventType === 'content.start') {
      this.applyContentStart(event);
      return;
    }
    if (eventType === 'content.delta') {
      await this.applyContentDelta(event, send);
      return;
    }
    if (eventType === 'interaction.complete') {
      await this.applyInteractionComplete(event, send);
      return;
    }
    if (eventType === 'error') {
      const message = asStringValue(asRecordValue(event['error'])['message']) || 'Gemini Interactions stream failed';
      await send(JSON.stringify(this.errorPayload(message)));
      await send('data: [DONE]\n\n');
      this.doneSent = true;
    }
  }

  private applyContentStart(event: JsonRecord): void {
    const index = this.indexValue(event);
    const content = asRecordValue(event['content']);
    if (Object.keys(content).length === 0) {
      return;
    }
    if (asStringValue(content['type']) === 'function_call') {
      this.sawToolCall = true;
    }
    this.outputsByIndex[`${index}`] = content;
  }

  private async applyContentDelta(event: JsonRecord, send: ChatStreamSend): Promise<void> {
    const index = this.indexValue(event);
    const delta = asRecordValue(event['delta']);
    const deltaType = asStringValue(delta['type']);
    const output = this.outputAt(index);
    if (deltaType === 'text') {
      const text = asStringValue(delta['text']);
      if (text.length > 0) {
        output['text'] = asStringValue(output['text']) + text;
        await this.sendDelta(send, this.deltaText('content', text), '');
      }
      return;
    }
    if (deltaType === 'thought_summary') {
      const content = asRecordValue(delta['content']);
      const summary = asStringValue(content['text']);
      if (summary.length > 0) {
        output['type'] = 'thought';
        output['summary'] = asStringValue(output['summary']) + summary;
        await this.sendDelta(send, this.deltaText('reasoning_content', summary), '');
      }
      return;
    }
    if (deltaType === 'thought_signature') {
      const signature = asStringValue(delta['signature']).trim();
      if (signature.length > 0) {
        output['type'] = 'thought';
        output['signature'] = signature;
      }
      return;
    }
    if (deltaType === 'function_call') {
      await this.applyFunctionCallDelta(index, delta, output, send);
      return;
    }
    Object.keys(delta).forEach((key: string) => {
      if (key !== 'type') {
        output[key] = delta[key];
      }
    });
  }

  private async applyFunctionCallDelta(index: number, delta: JsonRecord, output: JsonRecord,
    send: ChatStreamSend): Promise<void> {
    this.sawToolCall = true;
    output['type'] = 'function_call';
    const id = asStringValue(delta['id']).trim() || 'tool_call';
    const name = asStringValue(delta['name']).trim() || 'tool';
    const args = delta['arguments'] === undefined ? emptyJsonRecord() : delta['arguments'];
    output['id'] = id;
    output['name'] = name;
    output['arguments'] = args;
    const signature = asStringValue(delta['signature']).trim();
    if (signature.length > 0) {
      output['signature'] = signature;
    }
    const fn = emptyJsonRecord();
    fn['name'] = name;
    fn['arguments'] = JSON.stringify(args);
    const toolCall = emptyJsonRecord();
    toolCall['index'] = index;
    toolCall['id'] = id;
    toolCall['type'] = 'function';
    toolCall['function'] = fn;
    if (signature.length > 0) {
      toolCall['signature'] = signature;
    }
    const outDelta = emptyJsonRecord();
    outDelta['tool_calls'] = [toolCall];
    await this.sendDelta(send, outDelta, '');
  }

  private async applyInteractionComplete(event: JsonRecord, send: ChatStreamSend): Promise<void> {
    const interaction = asRecordValue(event['interaction']);
    const id = asStringValue(interaction['id']).trim();
    if (id.length > 0) {
      this.interactionId = id;
    }
    const native = emptyJsonRecord();
    const wrapper = emptyJsonRecord();
    wrapper['outputs'] = this.finalizeOutputs();
    native['gemini_interactions'] = wrapper;
    const delta = emptyJsonRecord();
    delta['native'] = native;
    await this.sendDelta(send, delta, this.sawToolCall ? 'tool_calls' : 'stop');
    await send('data: [DONE]\n\n');
    this.doneSent = true;
  }

  private finalizeOutputs(): JsonArray {
    const keys = Object.keys(this.outputsByIndex).sort((left: string, right: string): number => Number(left) - Number(right));
    const output: JsonArray = [];
    for (let index = 0; index < keys.length; index += 1) {
      output.push(this.outputsByIndex[keys[index]]);
    }
    return output;
  }

  private async sendDelta(send: ChatStreamSend, delta: JsonRecord, finishReason: string): Promise<void> {
    if (!this.sentRole) {
      this.sentRole = true;
      await send(this.sse(this.chunk(this.deltaText('role', 'assistant'), '')));
    }
    await send(this.sse(this.chunk(delta, finishReason)));
  }

  private chunk(delta: JsonRecord, finishReason: string): JsonRecord {
    const choice = emptyJsonRecord();
    choice['index'] = 0;
    choice['delta'] = delta;
    choice['finish_reason'] = finishReason.length > 0 ? finishReason : null;
    const chunk = emptyJsonRecord();
    chunk['id'] = this.interactionId.length > 0 ? this.interactionId : 'gemini-interactions-stream';
    chunk['object'] = 'chat.completion.chunk';
    chunk['created'] = this.created;
    chunk['model'] = this.model;
    chunk['choices'] = [choice];
    return chunk;
  }

  private outputAt(index: number): JsonRecord {
    const key = `${index}`;
    if (this.outputsByIndex[key] === undefined) {
      this.outputsByIndex[key] = emptyJsonRecord();
    }
    return this.outputsByIndex[key];
  }

  private deltaText(key: string, value: string): JsonRecord {
    const delta = emptyJsonRecord();
    delta[key] = value;
    return delta;
  }

  private indexValue(event: JsonRecord): number {
    const value = Number(event['index']);
    return Number.isFinite(value) ? Math.trunc(value) : 0;
  }

  private sse(payload: JsonRecord): string {
    return `data: ${JSON.stringify(payload)}\n\n`;
  }

  private errorPayload(message: string): JsonRecord {
    const value = emptyJsonRecord();
    const error = emptyJsonRecord();
    error['message'] = message;
    value['error'] = error;
    return value;
  }

  private parseEvent(rawPayload: string): JsonRecord | null {
    try {
      const parsed = JSON.parse(rawPayload) as Object;
      if (parsed !== null && !Array.isArray(parsed) && typeof parsed === 'object') {
        return parsed as JsonRecord;
      }
    } catch (_err) {
    }
    return null;
  }
}
