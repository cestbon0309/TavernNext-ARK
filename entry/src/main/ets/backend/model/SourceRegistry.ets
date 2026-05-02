import { ChatCompletionSource } from './ChatCompletionTypes';

export function parseChatCompletionSource(raw: string): ChatCompletionSource | null {
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'openai':
      return 'openai';
    case 'openrouter':
    case 'open-router':
      return 'openrouter';
    case 'custom':
      return 'custom';
    case 'claude':
      return 'claude';
    case 'makersuite':
    case 'gemini':
    case 'google':
      return 'makersuite';
    case 'vertexai':
    case 'vertex-ai':
    case 'vertex ai':
      return 'vertexai';
    case 'deepseek':
      return 'deepseek';
    case 'cohere':
      return 'cohere';
    case 'groq':
      return 'groq';
    case 'moonshot':
    case 'moonshot ai':
      return 'moonshot';
    case 'nanogpt':
    case 'nano-gpt':
    case 'nano gpt':
      return 'nanogpt';
    case 'chutes':
      return 'chutes';
    case 'siliconflow':
    case 'silicon flow':
      return 'siliconflow';
    case 'zai':
    case 'z.ai':
    case 'glm':
      return 'zai';
    default:
      return null;
  }
}

export function sourceDisplayName(source: ChatCompletionSource): string {
  switch (source) {
    case 'openai':
      return 'OpenAI';
    case 'openrouter':
      return 'OpenRouter';
    case 'custom':
      return 'Custom OpenAI';
    case 'claude':
      return 'Claude';
    case 'makersuite':
      return 'Google Gemini';
    case 'vertexai':
      return 'Google Vertex AI';
    case 'deepseek':
      return 'DeepSeek';
    case 'cohere':
      return 'Cohere';
    case 'groq':
      return 'Groq';
    case 'moonshot':
      return 'Moonshot AI';
    case 'nanogpt':
      return 'NanoGPT';
    case 'chutes':
      return 'Chutes';
    case 'siliconflow':
      return 'SiliconFlow';
    case 'zai':
      return 'Z.AI (GLM)';
  }
}

export function sourceSecretKey(source: ChatCompletionSource): string {
  switch (source) {
    case 'openai':
      return 'api_key_openai';
    case 'openrouter':
      return 'api_key_openrouter';
    case 'custom':
      return 'api_key_custom';
    case 'claude':
      return 'api_key_claude';
    case 'makersuite':
      return 'api_key_makersuite';
    case 'vertexai':
      return 'api_key_vertexai';
    case 'deepseek':
      return 'api_key_deepseek';
    case 'cohere':
      return 'api_key_cohere';
    case 'groq':
      return 'api_key_groq';
    case 'moonshot':
      return 'api_key_moonshot';
    case 'nanogpt':
      return 'api_key_nanogpt';
    case 'chutes':
      return 'api_key_chutes';
    case 'siliconflow':
      return 'api_key_siliconflow';
    case 'zai':
      return 'api_key_zai';
  }
}

export function supportsReverseProxy(source: ChatCompletionSource): boolean {
  return source === 'openai' || source === 'claude' || source === 'makersuite' ||
    source === 'vertexai' || source === 'deepseek' || source === 'moonshot' ||
    source === 'zai';
}

