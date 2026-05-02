import { JsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { parseCustomApiFormat } from '../CustomApiFormat';
import { asStringValue } from '../JsonHelpers';
import { ClaudePayloadBuilder } from './ClaudePayloadBuilder';
import { GeminiInteractionsPayloadBuilder } from './GeminiInteractionsPayloadBuilder';
import { OpenAiPayloadBuilder } from './OpenAiPayloadBuilder';
import { OpenAiResponsesPayloadBuilder } from './OpenAiResponsesPayloadBuilder';
import { applyCustomBodyOverrides } from './Shared';

export class CustomPayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    const format = parseCustomApiFormat(asStringValue(payload['custom_api_format']));
    switch (format) {
      case 'openai_responses':
        return new OpenAiResponsesPayloadBuilder().build(payload);
      case 'claude_messages':
        return new ClaudePayloadBuilder().buildPassthrough(payload);
      case 'gemini_interactions':
        return new GeminiInteractionsPayloadBuilder().build(payload);
      case 'openai_compat':
      default: {
        const built = new OpenAiPayloadBuilder('custom').build(payload);
        built.body = applyCustomBodyOverrides(built.body, asStringValue(payload['custom_include_body']),
          asStringValue(payload['custom_exclude_body']));
        return built;
      }
    }
  }
}
