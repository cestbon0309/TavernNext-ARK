import { HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { CancellationToken } from '../../CancellationToken';
import { parseJsonRecord } from '../../JsonUtils';
import { RemoteHttpClient, RemoteHttpResult } from '../../RemoteHttpClient';
import { ChatCompletionApiConfig, ChatCompletionSource, ChatStreamSend } from '../ChatCompletionTypes';
import { asArrayValue, asRecordValue, asStringValue } from '../JsonHelpers';
import { LlmApiLogContext, LlmApiLogger } from '../LlmApiLogger';
import {
  normalizeClaudeResponse,
  normalizeCohereResponse,
  normalizeGeminiInteractionsResponse,
  normalizeGeminiResponse,
  normalizeOpenAiResponsesResponse,
} from './ResponseNormalizers';
import { GeminiInteractionsStreamNormalizer, OpenAiResponsesStreamNormalizer } from './StreamNormalizers';

export class ChatCompletionRepository {
  private http: RemoteHttpClient = new RemoteHttpClient();
  private logger: LlmApiLogger | null = null;

  setLogger(logger: LlmApiLogger): void {
    this.logger = logger;
  }

  async listModels(source: ChatCompletionSource, config: ChatCompletionApiConfig): Promise<HttpResponse> {
    if (source === 'vertexai') {
      const response = emptyJsonRecord();
      response['bypass'] = true;
      response['data'] = [];
      return HttpResponse.json(response);
    }
    if (source === 'makersuite') {
      return this.listGeminiModels(config);
    }
    if (source === 'cohere') {
      return this.listCohereModels(config);
    }
    const url = this.http.joinUrl(config.baseUrl, '/models');
    const result = await this.http.getText(url, this.headers(source, config, '/models', 'application/json'), 30000);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    return this.http.responseFromRemote(result);
  }

  async generate(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord): Promise<HttpResponse> {
    const logContext = this.logger?.begin(source, config, endpointPath, payload, false) ?? null;
    const url = this.urlForGenerate(source, config, endpointPath, false);
    const headers = this.headers(source, config, endpointPath, 'application/json');
    let result: RemoteHttpResult;
    try {
      result = await this.http.postJson(url, payload, headers);
    } catch (err) {
      this.finishJsonLog(logContext, false, null, '', err instanceof Error ? err.message : JSON.stringify(err));
      throw new Error(err instanceof Error ? err.message : JSON.stringify(err));
    }
    if (result.statusCode < 200 || result.statusCode >= 300) {
      this.finishJsonLog(logContext, false, null, result.text, this.providerErrorMessage(source, result.statusCode,
        result.text));
      return HttpResponse.json(this.providerError(source, result.statusCode, result.text), 200);
    }
    const parsed = parseJsonRecord(result.text);
    if (this.containsCacheControl(payload)) {
      this.logPromptCacheUsage(source, asStringValue(payload['model']), parsed);
    }
    if (source === 'claude' || endpointPath === '/messages') {
      const normalized = normalizeClaudeResponse(parsed);
      this.finishJsonLog(logContext, true, normalized, result.text, '');
      return HttpResponse.json(normalized);
    }
    if (source === 'makersuite' || source === 'vertexai') {
      const normalized = normalizeGeminiResponse(parsed);
      this.finishJsonLog(logContext, true, normalized, result.text, '');
      return HttpResponse.json(normalized);
    }
    if (source === 'cohere') {
      const normalized = normalizeCohereResponse(parsed);
      this.finishJsonLog(logContext, true, normalized, result.text, '');
      return HttpResponse.json(normalized);
    }
    if (endpointPath === '/responses') {
      const normalized = normalizeOpenAiResponsesResponse(parsed);
      this.finishJsonLog(logContext, true, normalized, result.text, '');
      return HttpResponse.json(normalized);
    }
    if (endpointPath === '/interactions') {
      const normalized = normalizeGeminiInteractionsResponse(parsed);
      this.finishJsonLog(logContext, true, normalized, result.text, '');
      return HttpResponse.json(normalized);
    }
    this.finishJsonLog(logContext, true, parsed, result.text, '');
    return this.http.responseFromRemote(result);
  }

  async generateStream(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord, send: ChatStreamSend, cancelToken?: CancellationToken): Promise<void> {
    const logContext = this.logger?.begin(source, config, endpointPath, payload, true) ?? null;
    const streamLog = logContext === null ? null : this.logger?.createStreamSink(logContext);
    const loggingSend = streamLog === null || streamLog === undefined ? send : streamLog.wrapSend(send);
    const url = this.urlForGenerate(source, config, endpointPath, true);
    const headers = this.headers(source, config, endpointPath, 'text/event-stream');
    try {
      if (endpointPath === '/responses') {
        const normalizer = new OpenAiResponsesStreamNormalizer(asStringValue(payload['model']));
        const readableSend = streamLog === null || streamLog === undefined ? loggingSend :
          streamLog.wrapReadableSend(send);
        let loggedCacheUsage = false;
        await this.http.streamPostJsonEvents(url, payload, headers, async (event: string): Promise<void> => {
          streamLog?.recordEvent(event);
          loggedCacheUsage = this.logPromptCacheUsageFromEvent(source, asStringValue(payload['model']), payload, event,
            loggedCacheUsage);
          await normalizer.handleEvent(event, readableSend);
        }, 300000, cancelToken);
        streamLog?.finishOk();
        return;
      }
      if (endpointPath === '/interactions') {
        const normalizer = new GeminiInteractionsStreamNormalizer(asStringValue(payload['model']));
        const readableSend = streamLog === null || streamLog === undefined ? loggingSend :
          streamLog.wrapReadableSend(send);
        let loggedCacheUsage = false;
        await this.http.streamPostJsonEvents(url, payload, headers, async (event: string): Promise<void> => {
          streamLog?.recordEvent(event);
          loggedCacheUsage = this.logPromptCacheUsageFromEvent(source, asStringValue(payload['model']), payload, event,
            loggedCacheUsage);
          await normalizer.handleEvent(event, readableSend);
        }, 300000, cancelToken);
        streamLog?.finishOk();
        return;
      }
      if (this.containsCacheControl(payload)) {
        let loggedCacheUsage = false;
        await this.http.streamPostJsonWithEventHook(url, payload, headers, loggingSend, async (event: string): Promise<void> => {
          loggedCacheUsage = this.logPromptCacheUsageFromEvent(source, asStringValue(payload['model']), payload, event,
            loggedCacheUsage);
        }, 300000, cancelToken);
        streamLog?.finishOk();
        return;
      }
      await this.http.streamPostJson(url, payload, headers, loggingSend, 300000, cancelToken);
      streamLog?.finishOk();
    } catch (err) {
      streamLog?.finishError(err instanceof Error ? err.message : JSON.stringify(err));
      throw new Error(err instanceof Error ? err.message : JSON.stringify(err));
    }
  }

  private async listGeminiModels(config: ChatCompletionApiConfig): Promise<HttpResponse> {
    const url = this.withApiKey(this.http.joinUrl(config.baseUrl, '/v1beta/models'), config);
    const result = await this.http.getText(url, this.headers('makersuite', config, '/v1beta/models', 'application/json'), 30000);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    const parsed = parseJsonRecord(result.text);
    const models: JsonArray = [];
    for (const item of asArrayValue(parsed['models'])) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const model = item as JsonRecord;
      const methods = asArrayValue(model['supportedGenerationMethods']);
      if (methods.length > 0 && !methods.includes('generateContent')) {
        continue;
      }
      const next = emptyJsonRecord();
      const name = asStringValue(model['name']);
      next['id'] = name.startsWith('models/') ? name.slice(7) : name;
      next['name'] = next['id'];
      models.push(next);
    }
    const response = emptyJsonRecord();
    response['data'] = models;
    return HttpResponse.json(response);
  }

  private async listCohereModels(config: ChatCompletionApiConfig): Promise<HttpResponse> {
    const result = await this.http.getText(this.http.joinUrl(config.baseUrl, '/models'),
      this.headers('cohere', config, '/models', 'application/json'), 30000);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    const parsed = parseJsonRecord(result.text);
    const source = asArrayValue(parsed['models']).length > 0 ? asArrayValue(parsed['models']) : asArrayValue(parsed['data']);
    const data: JsonArray = [];
    for (const item of source) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      if (record['id'] === undefined && record['name'] !== undefined) {
        record['id'] = record['name'];
      }
      data.push(record);
    }
    const response = emptyJsonRecord();
    response['data'] = data;
    return HttpResponse.json(response);
  }

  private urlForGenerate(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    stream: boolean = false): string {
    if (endpointPath === '/interactions') {
      let url = this.geminiInteractionsUrl(config.baseUrl, endpointPath);
      if (stream) {
        url = this.withQueryParam(url, 'alt', 'sse');
      }
      if (config.authorizationHeader.length === 0 && config.apiKey.length > 0) {
        url = this.withQueryParam(url, 'key', config.apiKey);
      }
      return url;
    }
    const url = this.http.joinUrl(config.baseUrl, endpointPath);
    if (source === 'makersuite' || source === 'vertexai') {
      return this.withApiKey(url, config);
    }
    return url;
  }

  private headers(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    accept: string): Record<string, string> {
    const headers: Record<string, string> = {
      'Accept': accept,
    };
    Object.keys(config.extraHeaders).forEach((key: string) => {
      if (key.trim().length > 0 && config.extraHeaders[key].trim().length > 0) {
        headers[key] = config.extraHeaders[key];
      }
    });
    if (config.authorizationHeader.length > 0) {
      headers['Authorization'] = config.authorizationHeader;
    } else if (this.usesClaudeHeaders(source, endpointPath)) {
      if (config.apiKey.length > 0) {
        headers['x-api-key'] = config.apiKey;
      }
    } else if (source === 'makersuite' || endpointPath === '/interactions') {
      if (config.apiKey.length > 0) {
        headers['x-goog-api-key'] = config.apiKey;
      }
    } else if (config.apiKey.length > 0) {
      headers['Authorization'] = `Bearer ${config.apiKey}`;
    }
    if (this.usesClaudeHeaders(source, endpointPath)) {
      if (headers['anthropic-version'] === undefined) {
        headers['anthropic-version'] = '2023-06-01';
      }
      if (config.anthropicBetaHeaderMode !== 'none' && headers['anthropic-beta'] === undefined) {
        headers['anthropic-beta'] = 'prompt-caching-2024-07-31';
      }
    }
    return headers;
  }

  private usesClaudeHeaders(source: ChatCompletionSource, endpointPath: string): boolean {
    return source === 'claude' || endpointPath === '/messages';
  }

  private withApiKey(url: string, config: ChatCompletionApiConfig): string {
    if (config.authorizationHeader.length > 0 || config.apiKey.length === 0) {
      return url;
    }
    return this.withQueryParam(url, 'key', config.apiKey);
  }

  private withQueryParam(url: string, key: string, value: string): string {
    const separator = url.includes('?') ? '&' : '?';
    return `${url}${separator}${encodeURIComponent(key)}=${encodeURIComponent(value)}`;
  }

  private geminiInteractionsUrl(baseUrl: string, endpointPath: string): string {
    const trimmed = baseUrl.trim().replace(/\/+$/, '');
    const suffix = endpointPath.trim().replace(/^\/+/, '');
    if (trimmed.endsWith('/v1') || trimmed.endsWith('/v1beta')) {
      return `${trimmed}/${suffix}`;
    }
    return `${trimmed}/v1beta/${suffix}`;
  }

  private errorTrue(): JsonRecord {
    const value = emptyJsonRecord();
    value['error'] = true;
    return value;
  }

  private finishJsonLog(context: LlmApiLogContext | null, ok: boolean, response: JsonRecord | null, rawText: string,
    errorMessage: string): void {
    if (context === null || this.logger === null) {
      return;
    }
    this.logger.finishJson(context, ok, response, rawText, errorMessage);
  }

  private providerError(source: ChatCompletionSource, statusCode: number, rawText: string): JsonRecord {
    const value = emptyJsonRecord();
    const error = emptyJsonRecord();
    error['message'] = this.providerErrorMessage(source, statusCode, rawText);
    error['status'] = statusCode;
    value['error'] = error;
    return value;
  }

  private providerErrorMessage(source: ChatCompletionSource, statusCode: number, rawText: string): string {
    const extracted = this.extractErrorMessage(rawText);
    if (statusCode === 401 || statusCode === 403) {
      return extracted.length > 0 ? extracted : `${source} authentication failed`;
    }
    if (statusCode === 400) {
      return extracted.length > 0 ? extracted : `${source} rejected the request`;
    }
    if (statusCode === 429) {
      return extracted.length > 0 ? extracted : `${source} rate limit exceeded`;
    }
    if (statusCode >= 500) {
      return extracted.length > 0 ? extracted : `${source} endpoint failed with HTTP ${statusCode}`;
    }
    return extracted.length > 0 ? extracted : `HTTP ${statusCode}`;
  }

  private extractErrorMessage(rawText: string): string {
    if (rawText.length === 0) {
      return '';
    }
    try {
      const parsed = JSON.parse(rawText) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        return rawText;
      }
      const record = parsed as JsonRecord;
      if (typeof record['error'] === 'string') {
        return record['error'] as string;
      }
      const error = asRecordValue(record['error']);
      const message = asStringValue(error['message']) || asStringValue(record['message']);
      return message.length > 0 ? message : rawText;
    } catch (_err) {
      return rawText;
    }
  }

  private logPromptCacheUsageFromEvent(source: ChatCompletionSource, model: string, payload: JsonRecord, event: string,
    alreadyLogged: boolean): boolean {
    if (alreadyLogged || !this.containsCacheControl(payload) || event === '[DONE]') {
      return alreadyLogged;
    }
    try {
      const parsed = JSON.parse(event) as Object;
      if (parsed !== null && !Array.isArray(parsed) && typeof parsed === 'object') {
        return this.logPromptCacheUsage(source, model, parsed as JsonRecord);
      }
    } catch (_err) {
    }
    return false;
  }

  private logPromptCacheUsage(source: ChatCompletionSource, model: string, value: JsonRecord): boolean {
    const usage = this.findPromptCacheUsage(value);
    if (usage === null) {
      return false;
    }
    const total = usage.cacheCreationInputTokens + usage.cacheReadInputTokens + usage.inputTokens;
    const modelText = model.trim().length > 0 ? ` model=${model.trim()}` : '';
    console.info(`[LLM] ${source} prompt cache usage:${modelText} cache_read_input_tokens=${usage.cacheReadInputTokens} ` +
      `cache_creation_input_tokens=${usage.cacheCreationInputTokens} input_tokens=${usage.inputTokens} total_input_tokens=${total}`);
    return true;
  }

  private findPromptCacheUsage(value: JsonRecord): PromptCacheUsage | null {
    const usage = asRecordValue(value['usage']);
    const parsed = this.parsePromptCacheUsage(usage);
    if (parsed !== null) {
      return parsed;
    }
    const message = asRecordValue(value['message']);
    return this.parsePromptCacheUsage(asRecordValue(message['usage']));
  }

  private parsePromptCacheUsage(usage: JsonRecord): PromptCacheUsage | null {
    const cacheCreation = this.nonNegativeNumber(usage['cache_creation_input_tokens']);
    const cacheRead = this.nonNegativeNumber(usage['cache_read_input_tokens']);
    const input = this.nonNegativeNumber(usage['input_tokens']);
    if (cacheCreation < 0 || cacheRead < 0 || input < 0) {
      return null;
    }
    const result = new PromptCacheUsage();
    result.cacheCreationInputTokens = cacheCreation;
    result.cacheReadInputTokens = cacheRead;
    result.inputTokens = input;
    return result;
  }

  private nonNegativeNumber(value: Object | string | number | boolean | null | JsonArray | undefined): number {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
      return -1;
    }
    return Math.floor(value);
  }

  private containsCacheControl(value: Object | string | number | boolean | null | JsonArray | undefined): boolean {
    if (value === undefined || value === null) {
      return false;
    }
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        const item: Object | string | number | boolean | null = value[index];
        if (this.containsCacheControl(item)) {
          return true;
        }
      }
      return false;
    }
    if (typeof value !== 'object') {
      return false;
    }
    const record = value as JsonRecord;
    if (record['cache_control'] !== undefined) {
      return true;
    }
    const keys = Object.keys(record);
    for (const key of keys) {
      if (this.containsCacheControl(record[key])) {
        return true;
      }
    }
    return false;
  }
}

class PromptCacheUsage {
  cacheCreationInputTokens: number = 0;
  cacheReadInputTokens: number = 0;
  inputTokens: number = 0;
}
