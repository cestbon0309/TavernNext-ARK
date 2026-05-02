import { HttpRequest, HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { bodyAsRecord, parseJsonRecord } from '../JsonUtils';
import { proxyErrorResponse } from '../RemoteHttpClient';
import { SecretsService } from '../SecretsService';
import { ChatCompletionConfigResolver } from './ChatCompletionConfigResolver';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { ChatCompletionRepository } from './http/ChatCompletionRepository';
import { PayloadBuilderRegistry } from './payload/PayloadBuilderRegistry';
import { parseChatCompletionSource } from './SourceRegistry';
import { asBooleanValue } from './JsonHelpers';

export class ChatCompletionService {
  private configResolver: ChatCompletionConfigResolver;
  private payloadBuilders: PayloadBuilderRegistry = new PayloadBuilderRegistry();
  private repository: ChatCompletionRepository = new ChatCompletionRepository();

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
      if (asBooleanValue(body['stream'])) {
        const response = HttpResponse.stream('text/event-stream; charset=utf-8', async (send) => {
          try {
            await this.repository.generateStream(source, config, built.endpointPath, built.body, send);
          } catch (err) {
            const message = err instanceof Error ? err.message : JSON.stringify(err);
            await send(`event: error\ndata: ${JSON.stringify(this.errorFromText(message))}\n\n`);
          }
        });
        response.headers['x-accel-buffering'] = 'no';
        return response;
      }
      return await this.repository.generate(source, config, built.endpointPath, built.body);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
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
}
