import { ChatCompletionSource } from './ChatCompletionTypes';

export type CustomApiFormat = 'openai_compat' | 'openai_responses' | 'claude_messages' | 'gemini_interactions';

export function parseCustomApiFormat(raw: string): CustomApiFormat {
  switch (raw.trim()) {
    case '':
    case 'openai_compat':
      return 'openai_compat';
    case 'openai_responses':
      return 'openai_responses';
    case 'claude_messages':
      return 'claude_messages';
    case 'gemini_interactions':
      return 'gemini_interactions';
    default:
      throw new Error(`Unsupported custom_api_format: ${raw}`);
  }
}

export function modelListSourceForCustomFormat(format: CustomApiFormat): ChatCompletionSource {
  switch (format) {
    case 'claude_messages':
      return 'claude';
    case 'gemini_interactions':
      return 'makersuite';
    default:
      return 'custom';
  }
}

