import { JsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import { asStringValue } from '../JsonHelpers';
import { buildClaudePayload, buildClaudePayloadPassthrough } from './claude/Builder';
import { applyCustomBodyOverrides } from './Shared';

export class ClaudePayloadBuilder {
  build(payload: JsonRecord): BuiltChatPayload {
    return new BuiltChatPayload('/messages', buildClaudePayload(payload));
  }

  buildPassthrough(payload: JsonRecord): BuiltChatPayload {
    const built = new BuiltChatPayload('/messages', buildClaudePayloadPassthrough(payload));
    built.body = applyCustomBodyOverrides(built.body, asStringValue(payload['custom_include_body']),
      asStringValue(payload['custom_exclude_body']));
    return built;
  }
}
