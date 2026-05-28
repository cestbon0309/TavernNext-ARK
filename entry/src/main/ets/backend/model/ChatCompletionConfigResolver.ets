import { SecretsService } from '../SecretsService';
import { JsonRecord } from '../HttpTypes';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { parseCustomApiFormat, modelListSourceForCustomFormat } from './CustomApiFormat';
import { CustomParameters } from './CustomParameters';
import { asBooleanValue, asStringValue } from './JsonHelpers';
import { sourceSecretKey, supportsReverseProxy } from './SourceRegistry';
import { VertexAiAuthService } from './VertexAiAuth';

type ConfigPurpose = 'status' | 'generate';

const OPENAI_API_BASE = 'https://api.openai.com/v1';
const OPENROUTER_API_BASE = 'https://openrouter.ai/api/v1';
const CLAUDE_API_BASE = 'https://api.anthropic.com/v1';
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com';
const VERTEXAI_GLOBAL_BASE = 'https://aiplatform.googleapis.com';
const DEEPSEEK_API_BASE = 'https://api.deepseek.com/beta';
const DEEPSEEK_STATUS_API_BASE = 'https://api.deepseek.com';
const COHERE_STATUS_API_BASE = 'https://api.cohere.ai/v1';
const COHERE_API_BASE = 'https://api.cohere.ai/v2';
const GROQ_API_BASE = 'https://api.groq.com/openai/v1';
const MOONSHOT_API_BASE = 'https://api.moonshot.ai/v1';
const NANOGPT_API_BASE = 'https://nano-gpt.com/api/v1';
const CHUTES_API_BASE = 'https://llm.chutes.ai/v1';
const SILICONFLOW_API_BASE = 'https://api.siliconflow.com/v1';
const ZAI_API_BASE_COMMON = 'https://api.z.ai/api/paas/v4';
const ZAI_API_BASE_CODING = 'https://api.z.ai/api/coding/paas/v4';

export class ChatCompletionConfigResolver {
  private secrets: SecretsService;
  private customParameters: CustomParameters = new CustomParameters();
  private vertexAiAuth: VertexAiAuthService = new VertexAiAuthService();

  constructor(secrets: SecretsService) {
    this.secrets = secrets;
  }

  async resolveStatusConfig(source: ChatCompletionSource, body: JsonRecord): Promise<ChatCompletionApiConfig> {
    return await this.resolveConfig(source, asStringValue(body['reverse_proxy']), asStringValue(body['proxy_password']),
      asStringValue(body['custom_url']), asStringValue(body['custom_include_headers']), '', 'status', body);
  }

  async resolveGenerateConfig(source: ChatCompletionSource, payload: JsonRecord): Promise<ChatCompletionApiConfig> {
    return await this.resolveConfig(source, asStringValue(payload['reverse_proxy']), asStringValue(payload['proxy_password']),
      asStringValue(payload['custom_url']), asStringValue(payload['custom_include_headers']),
      asStringValue(payload['zai_endpoint']), 'generate', payload);
  }

  statusModelListSource(source: ChatCompletionSource, body: JsonRecord): ChatCompletionSource {
    if (source !== 'custom') {
      return source;
    }
    return modelListSourceForCustomFormat(parseCustomApiFormat(asStringValue(body['custom_api_format'])));
  }

  private async resolveConfig(source: ChatCompletionSource, reverseProxy: string, proxyPassword: string, customUrl: string,
    customHeadersRaw: string, zaiEndpoint: string, purpose: ConfigPurpose, payload: JsonRecord): Promise<ChatCompletionApiConfig> {
    if (source === 'custom') {
      const config = this.resolveCustomConfig(reverseProxy, proxyPassword, customUrl, customHeadersRaw);
      config.forceHttp1_1 = this.shouldForceHttp1_1(payload);
      return config;
    }
    if (source === 'vertexai' && purpose === 'generate') {
      const config = await this.resolveVertexAiGenerateConfig(reverseProxy, proxyPassword, payload);
      config.forceHttp1_1 = this.shouldForceHttp1_1(payload);
      return config;
    }
    const config = new ChatCompletionApiConfig();
    config.forceHttp1_1 = this.shouldForceHttp1_1(payload);
    if (source === 'vertexai' && purpose === 'status') {
      config.baseUrl = VERTEXAI_GLOBAL_BASE;
      config.requiresKey = false;
      return config;
    }
    if (supportsReverseProxy(source) && reverseProxy.trim().length > 0) {
      config.baseUrl = reverseProxy.trim();
      config.apiKey = proxyPassword.trim();
      config.requiresKey = false;
    } else {
      config.baseUrl = this.defaultBaseUrl(source, purpose, zaiEndpoint);
      config.apiKey = this.secrets.activeSecretValue(sourceSecretKey(source));
    }
    config.extraHeaders = this.sourceExtraHeaders(source);
    config.anthropicBetaHeaderMode = source === 'claude' ? 'claude_defaults' : 'none';
    return config;
  }

  private shouldForceHttp1_1(payload: JsonRecord): boolean {
    return asBooleanValue(payload['force_http1_1'], true);
  }

  private resolveCustomConfig(reverseProxy: string, proxyPassword: string, customUrl: string,
    customHeadersRaw: string): ChatCompletionApiConfig {
    const baseUrl = customUrl.trim().length > 0 ? customUrl.trim() : reverseProxy.trim();
    if (baseUrl.length === 0) {
      throw new Error('Custom endpoint is missing. Please configure custom_url.');
    }
    const config = new ChatCompletionApiConfig();
    config.baseUrl = baseUrl;
    config.requiresKey = false;
    config.extraHeaders = this.customParameters.parseStringMap(customHeadersRaw);
    config.authorizationHeader = this.takeHeaderValue(config.extraHeaders, 'Authorization');
    const usesReverseProxy = customUrl.trim().length === 0 && reverseProxy.trim().length > 0;
    if (config.authorizationHeader.length > 0) {
      config.apiKey = '';
    } else if (usesReverseProxy) {
      config.apiKey = proxyPassword.trim();
    } else {
      config.apiKey = this.secrets.activeSecretValue('api_key_custom');
    }
    return config;
  }

  private async resolveVertexAiGenerateConfig(reverseProxy: string, proxyPassword: string, payload: JsonRecord): Promise<ChatCompletionApiConfig> {
    const config = new ChatCompletionApiConfig();
    if (reverseProxy.trim().length > 0) {
      config.baseUrl = `${reverseProxy.trim().replace(/\/+$/, '')}/v1`;
      config.authorizationHeader = proxyPassword.trim().length > 0 ? `Bearer ${proxyPassword.trim()}` : '';
      config.requiresKey = false;
      return config;
    }
    const mode = (asStringValue(payload['vertexai_auth_mode']) || 'express').trim().toLowerCase();
    const region = (asStringValue(payload['vertexai_region']) || 'us-central1').trim();
    const projectOverride = asStringValue(payload['vertexai_express_project_id']).trim();
    if (mode === 'express') {
      config.apiKey = this.secrets.activeSecretValue('api_key_vertexai');
      config.baseUrl = projectOverride.length > 0 ?
        `${VERTEXAI_GLOBAL_BASE}/v1/projects/${projectOverride}/locations/${region}` :
        `${this.vertexAiHost(region)}/v1`;
      return config;
    }
    if (mode !== 'full') {
      throw new Error(`Unsupported Vertex AI authentication mode: ${mode}`);
    }
    const serviceAccountJson = this.secrets.activeSecretValue('vertexai_service_account_json');
    const token = await this.vertexAiAuth.getServiceAccountAccessToken(serviceAccountJson);
    config.authorizationHeader = `Bearer ${token.accessToken}`;
    config.requiresKey = false;
    config.baseUrl = `${this.vertexAiHost(region)}/v1/projects/${token.projectId}/locations/${region}`;
    return config;
  }

  private defaultBaseUrl(source: ChatCompletionSource, purpose: ConfigPurpose, zaiEndpoint: string): string {
    switch (source) {
      case 'openai':
        return OPENAI_API_BASE;
      case 'openrouter':
        return OPENROUTER_API_BASE;
      case 'claude':
        return CLAUDE_API_BASE;
      case 'makersuite':
        return GEMINI_API_BASE;
      case 'vertexai':
        return VERTEXAI_GLOBAL_BASE;
      case 'deepseek':
        return purpose === 'status' ? DEEPSEEK_STATUS_API_BASE : DEEPSEEK_API_BASE;
      case 'cohere':
        return purpose === 'status' ? COHERE_STATUS_API_BASE : COHERE_API_BASE;
      case 'groq':
        return GROQ_API_BASE;
      case 'moonshot':
        return MOONSHOT_API_BASE;
      case 'nanogpt':
        return NANOGPT_API_BASE;
      case 'chutes':
        return CHUTES_API_BASE;
      case 'siliconflow':
        return SILICONFLOW_API_BASE;
      case 'zai':
        return zaiEndpoint.trim().toLowerCase() === 'coding' ? ZAI_API_BASE_CODING : ZAI_API_BASE_COMMON;
      case 'custom':
        return OPENAI_API_BASE;
    }
  }

  private sourceExtraHeaders(source: ChatCompletionSource): Record<string, string> {
    const headers: Record<string, string> = {};
    if (source === 'openrouter') {
      headers['HTTP-Referer'] = 'https://tauritavern.client';
      headers['X-Title'] = 'TauriTavern';
    }
    if (source === 'zai') {
      headers['Accept-Language'] = 'en-US,en';
    }
    return headers;
  }

  private takeHeaderValue(headers: Record<string, string>, headerName: string): string {
    const keys = Object.keys(headers).filter((key: string): boolean => key.toLowerCase() === headerName.toLowerCase());
    if (keys.length === 0) {
      return '';
    }
    keys.sort();
    const preferred = keys.includes(headerName) ? headerName : keys[0];
    const value = headers[preferred] ?? '';
    const next: Record<string, string> = {};
    Object.keys(headers).forEach((key: string) => {
      if (!keys.includes(key)) {
        next[key] = headers[key];
      }
    });
    for (const key of keys) {
      headers[key] = '';
    }
    Object.keys(next).forEach((key: string) => headers[key] = next[key]);
    return value;
  }

  private vertexAiHost(region: string): string {
    return region.trim().toLowerCase() === 'global' ? VERTEXAI_GLOBAL_BASE :
      `https://${region.trim()}-aiplatform.googleapis.com`;
  }
}
