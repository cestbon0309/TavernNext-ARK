import { HttpRequest, HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { bodyAsRecord, parseJsonRecord } from '../JsonUtils';
import { proxyErrorResponse } from '../RemoteHttpClient';
import { SecretsService } from '../SecretsService';
import { CancellationToken } from '../CancellationToken';
import { ChatCompletionConfigResolver } from './ChatCompletionConfigResolver';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { ChatCompletionRepository } from './http/ChatCompletionRepository';
import { PayloadBuilderRegistry } from './payload/PayloadBuilderRegistry';
import { parseChatCompletionSource } from './SourceRegistry';
import { asBooleanValue } from './JsonHelpers';
import { PromptCachingService } from './PromptCaching';

export class ChatCompletionService {
  private configResolver: ChatCompletionConfigResolver;
  private payloadBuilders: PayloadBuilderRegistry = new PayloadBuilderRegistry();
  private repository: ChatCompletionRepository = new ChatCompletionRepository();
  private promptCaching: PromptCachingService = new PromptCachingService();
  private activeStreams: Record<string, CancellationToken | null> = {};
  private activeGenerations: Record<string, CancellationToken | null> = {};

  constructor(secrets: SecretsService) {
    this.configResolver = new ChatCompletionConfigResolver(secrets);
  }

  async generate(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = parseChatCompletionSource(`${body['chat_completion_source'] ?? 'openai'}`);
    if (source === null) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    let config: ChatCompletionApiConfig;
    try {
      config = this.configResolver.resolveGenerateConfig(source, body);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 400);
    }
    if (this.hasMissingRequiredKey(config)) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    try {
      const built = this.payloadBuilders.build(source, body);
      config = this.promptCaching.apply(source, config, built.endpointPath, built.body, body);
      this.logRequest(source, config, built.endpointPath, built.body);
      if (asBooleanValue(body['stream'])) {
        const streamId = this.requestId(body, 'stream_id');
        const cancelToken = this.register(this.activeStreams, streamId);
        const response = HttpResponse.stream('text/event-stream; charset=utf-8', async (send) => {
          try {
            await this.repository.generateStream(source, config, built.endpointPath, built.body, send, cancelToken);
          } catch (err) {
            if (!cancelToken.isCancelled()) {
              const message = err instanceof Error ? err.message : JSON.stringify(err);
              await send(`event: error\ndata: ${JSON.stringify(this.errorFromText(message))}\n\n`);
            }
          } finally {
            this.complete(this.activeStreams, streamId);
          }
        });
        response.headers['x-accel-buffering'] = 'no';
        return response;
      }
      const requestId = this.requestId(body, 'request_id');
      const cancelToken = this.register(this.activeGenerations, requestId);
      try {
        if (cancelToken.isCancelled()) {
          return HttpResponse.json(this.errorFromText('Generation cancelled by user'), 200);
        }
        return await this.repository.generate(source, config, built.endpointPath, built.body);
      } finally {
        this.complete(this.activeGenerations, requestId);
      }
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  cancelStream(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const id = this.requestId(body, 'stream_id');
    const cancelled = this.cancel(this.activeStreams, id);
    return this.cancelResponse(cancelled);
  }

  cancelGeneration(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const id = this.requestId(body, 'request_id');
    const cancelled = this.cancel(this.activeGenerations, id);
    return this.cancelResponse(cancelled);
  }

  async status(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = parseChatCompletionSource(`${body['chat_completion_source'] ?? 'openai'}`);
    if (source === null) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    if (asBooleanValue(body['bypass_status_check'])) {
      const response = emptyJsonRecord();
      response['bypass'] = true;
      return HttpResponse.json(response);
    }
    try {
      const config = this.configResolver.resolveStatusConfig(source, body);
      if (this.hasMissingRequiredKey(config)) {
        return HttpResponse.json(this.errorTrue(), 400);
      }
      return await this.repository.listModels(this.configResolver.statusModelListSource(source, body), config);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  async modelList(rawSource: string): Promise<HttpResponse> {
    const source = parseChatCompletionSource(rawSource);
    if (source === null) {
      return HttpResponse.json([]);
    }
    try {
      const config = this.configResolver.resolveStatusConfig(source, emptyJsonRecord());
      if (this.hasMissingRequiredKey(config)) {
        return HttpResponse.json([]);
      }
      const response = await this.repository.listModels(source, config);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return HttpResponse.json([]);
      }
      const parsed = parseJsonRecord(response.body);
      const data = parsed['data'];
      if (Array.isArray(data)) {
        return HttpResponse.json(data as JsonArray);
      }
      return HttpResponse.json([]);
    } catch (_err) {
      return HttpResponse.json([]);
    }
  }

  private hasMissingRequiredKey(config: ChatCompletionApiConfig): boolean {
    return config.requiresKey && config.apiKey.length === 0 && config.authorizationHeader.length === 0;
  }

  private errorTrue(): JsonRecord {
    const value = emptyJsonRecord();
    value['error'] = true;
    return value;
  }

  private errorFromText(text: string): JsonRecord {
    const value = emptyJsonRecord();
    const error = emptyJsonRecord();
    error['message'] = text.length > 0 ? text : 'Unknown error';
    value['error'] = error;
    return value;
  }

  private requestId(body: JsonRecord, key: string): string {
    const value = `${body[key] ?? ''}`.trim();
    if (value.length === 0 || value.length > 128) {
      return '';
    }
    for (let index = 0; index < value.length; index += 1) {
      const code = value.charCodeAt(index);
      const ok = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
        value.charAt(index) === '-' || value.charAt(index) === '_';
      if (!ok) {
        return '';
      }
    }
    return value;
  }

  private register(registry: Record<string, CancellationToken | null>, id: string): CancellationToken {
    const token = new CancellationToken();
    if (id.length > 0) {
      registry[id] = token;
    }
    return token;
  }

  private cancel(registry: Record<string, CancellationToken | null>, id: string): boolean {
    if (id.length === 0 || registry[id] === undefined || registry[id] === null) {
      return false;
    }
    const token = registry[id];
    if (token !== null) {
      token.cancel();
    }
    return true;
  }

  private complete(registry: Record<string, CancellationToken | null>, id: string): void {
    if (id.length > 0) {
      registry[id] = null;
    }
  }

  private cancelResponse(cancelled: boolean): HttpResponse {
    const response = emptyJsonRecord();
    response['cancelled'] = cancelled;
    return HttpResponse.json(response);
  }

  private logRequest(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord): void {
    const model = `${payload['model'] ?? ''}`;
    const stream = asBooleanValue(payload['stream']);
    console.info(`[LLM] source=${source} endpoint=${endpointPath} model=${model} stream=${stream} base=${config.baseUrl}`);
  }
}
