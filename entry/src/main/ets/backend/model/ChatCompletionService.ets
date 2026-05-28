import { util } from '@kit.ArkTS';
import { HttpRequest, HttpResponse, HttpStreamSend, JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { bodyAsRecord, parseJsonRecord } from '../JsonUtils';
import { proxyErrorResponse } from '../RemoteHttpClient';
import { SecretsService } from '../SecretsService';
import { CancellationToken } from '../CancellationToken';
import { DataDirectories } from '../DataDirectories';
import { FileStore } from '../FileStore';
import { ChatCompletionConfigResolver } from './ChatCompletionConfigResolver';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { ChatCompletionRepository } from './http/ChatCompletionRepository';
import { PayloadBuilderRegistry } from './payload/PayloadBuilderRegistry';
import { parseChatCompletionSource } from './SourceRegistry';
import { asArrayValue, asBooleanValue, asNumberValue, asRecordValue } from './JsonHelpers';
import { PromptCachingService } from './PromptCaching';
import { LlmApiLogger } from './LlmApiLogger';
import { LlmBackgroundTaskService } from '../LlmBackgroundTaskService';

export class ChatCompletionService {
  private configResolver: ChatCompletionConfigResolver;
  private payloadBuilders: PayloadBuilderRegistry = new PayloadBuilderRegistry();
  private repository: ChatCompletionRepository = new ChatCompletionRepository();
  private promptCaching: PromptCachingService;
  private llmLogger: LlmApiLogger;
  private backgroundTasks: LlmBackgroundTaskService;
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();
  private activeStreams: Record<string, CancellationToken | null> = {};
  private activeGenerations: Record<string, CancellationToken | null> = {};

  constructor(secrets: SecretsService, dirs: DataDirectories, store: FileStore,
    backgroundTasks: LlmBackgroundTaskService) {
    this.configResolver = new ChatCompletionConfigResolver(secrets);
    this.promptCaching = new PromptCachingService(dirs, store);
    this.llmLogger = new LlmApiLogger(store, dirs);
    this.backgroundTasks = backgroundTasks;
    this.repository.setLogger(this.llmLogger);
  }

  async generate(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = parseChatCompletionSource(`${body['chat_completion_source'] ?? 'openai'}`);
    if (source === null) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    let config: ChatCompletionApiConfig;
    try {
      config = await this.configResolver.resolveGenerateConfig(source, body);
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
          const backgroundHandle = await this.backgroundTasks.beginResponse();
          let completed = false;
          try {
            await this.repository.generateStream(source, config, built.endpointPath, built.body, send, cancelToken);
            completed = !cancelToken.isCancelled();
          } catch (err) {
            if (!cancelToken.isCancelled()) {
              const message = err instanceof Error ? err.message : JSON.stringify(err);
              await send(`event: error\ndata: ${JSON.stringify(this.errorFromText(message))}\n\n`);
            }
          } finally {
            this.complete(this.activeStreams, streamId);
            await this.backgroundTasks.finishResponse(backgroundHandle, completed);
          }
        });
        response.headers['x-accel-buffering'] = 'no';
        return response;
      }
      const requestId = this.requestId(body, 'request_id');
      const cancelToken = this.register(this.activeGenerations, requestId);
      const backgroundHandle = await this.backgroundTasks.beginResponse();
      let completed = false;
      try {
        if (cancelToken.isCancelled()) {
          return HttpResponse.json(this.errorFromText('Generation cancelled by user'), 200);
        }
        const response = await this.repository.generate(source, config, built.endpointPath, built.body);
        completed = this.isGenerationSuccess(response);
        return response;
      } finally {
        this.complete(this.activeGenerations, requestId);
        await this.backgroundTasks.finishResponse(backgroundHandle, completed);
      }
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  async generateBatchStream(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = parseChatCompletionSource(`${body['chat_completion_source'] ?? 'openai'}`);
    if (source === null) {
      return HttpResponse.json(this.errorTrue(), 400);
    }

    const candidates = asArrayValue(body['candidates']).slice(0, 16);
    if (candidates.length === 0) {
      return HttpResponse.json(this.errorFromText('No candidates provided'), 400);
    }

    const prepared: ParallelStreamCandidate[] = [];
    for (let index = 0; index < candidates.length; index += 1) {
      const candidate = asRecordValue(candidates[index]);
      if (Object.keys(candidate).length === 0) {
        continue;
      }
      const candidateBody = this.mergeBatchCandidateBody(body, candidate);
      let config: ChatCompletionApiConfig;
      try {
        config = await this.configResolver.resolveGenerateConfig(source, candidateBody);
      } catch (err) {
        return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 400);
      }
      if (this.hasMissingRequiredKey(config)) {
        return HttpResponse.json(this.errorTrue(), 400);
      }
      const built = this.payloadBuilders.build(source, candidateBody);
      if (!asBooleanValue(candidateBody['stream'])) {
        return HttpResponse.json(this.errorFromText('Batch stream requires streaming candidates'), 400);
      }
      const configured = this.promptCaching.apply(source, config, built.endpointPath, built.body, candidateBody);
      prepared.push({
        index: asNumberValue(candidate['index'], index),
        streamId: this.requestId(candidateBody, 'stream_id'),
        config: configured,
        endpointPath: built.endpointPath,
        body: built.body,
      });
    }

    if (prepared.length === 0) {
      return HttpResponse.json(this.errorFromText('No valid candidates provided'), 400);
    }

    const response = HttpResponse.stream('text/event-stream; charset=utf-8', async (send) => {
      const backgroundHandle = await this.backgroundTasks.beginResponse();
      let completed = false;
      try {
        await this.runBatchStreams(source, prepared, send);
        completed = true;
      } finally {
        await this.backgroundTasks.finishResponse(backgroundHandle, completed);
      }
    });
    response.headers['x-accel-buffering'] = 'no';
    return response;
  }

  cancelStream(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const id = this.requestId(body, 'stream_id');
    const cancelled = this.cancel(this.activeStreams, id);
    return this.cancelResponse(cancelled);
  }

  private mergeBatchCandidateBody(base: JsonRecord, candidate: JsonRecord): JsonRecord {
    const merged = emptyJsonRecord();
    Object.keys(base).forEach((key: string) => {
      if (key !== 'candidates') {
        merged[key] = base[key];
      }
    });
    Object.keys(candidate).forEach((key: string) => {
      if (key !== 'index') {
        merged[key] = candidate[key];
      }
    });
    return merged;
  }

  private async runBatchStreams(source: ChatCompletionSource, candidates: ParallelStreamCandidate[],
    send: HttpStreamSend): Promise<void> {
    let sendQueue: Promise<void> = Promise.resolve();
    const sendEvent = async (event: string, value: Object): Promise<void> => {
      const data = JSON.stringify(value);
      sendQueue = sendQueue.then(async () => {
        await send(`event: ${event}\ndata: ${data}\n\n`);
      });
      await sendQueue;
    };

    await Promise.all(candidates.map(async (candidate: ParallelStreamCandidate): Promise<void> => {
      const cancelToken = this.register(this.activeStreams, candidate.streamId);
      let completed = false;
      try {
        await sendEvent('candidate-start', this.batchEvent(candidate.index));
        this.logRequest(source, candidate.config, candidate.endpointPath, candidate.body);
        await this.repository.generateStream(source, candidate.config, candidate.endpointPath, candidate.body,
          async (chunk: string | Uint8Array): Promise<void> => {
            await sendEvent('candidate-chunk', this.batchChunkEvent(candidate.index, chunk));
          }, cancelToken);
        completed = !cancelToken.isCancelled();
        await sendEvent('candidate-done', this.batchDoneEvent(candidate.index, cancelToken.isCancelled()));
      } catch (err) {
        if (!cancelToken.isCancelled()) {
          const message = err instanceof Error ? err.message : JSON.stringify(err);
          await sendEvent('candidate-error', this.batchErrorEvent(candidate.index, message));
        } else {
          await sendEvent('candidate-done', this.batchDoneEvent(candidate.index, true));
        }
      } finally {
        this.complete(this.activeStreams, candidate.streamId);
      }
    }));
    await sendEvent('done', emptyJsonRecord());
  }

  private batchEvent(index: number): JsonRecord {
    const value = emptyJsonRecord();
    value['index'] = index;
    return value;
  }

  private batchChunkEvent(index: number, chunk: string | Uint8Array): JsonRecord {
    const value = this.batchEvent(index);
    value['chunkBase64'] = this.base64Chunk(chunk);
    return value;
  }

  private batchDoneEvent(index: number, cancelled: boolean): JsonRecord {
    const value = this.batchEvent(index);
    value['cancelled'] = cancelled;
    return value;
  }

  private batchErrorEvent(index: number, message: string): JsonRecord {
    const value = this.batchEvent(index);
    value['error'] = this.errorFromText(message);
    return value;
  }

  private base64Chunk(chunk: string | Uint8Array): string {
    const bytes = typeof chunk === 'string' ? this.encoder.encodeInto(chunk) : chunk;
    return this.base64.encodeToStringSync(bytes, util.Type.BASIC);
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
      const config = await this.configResolver.resolveStatusConfig(source, body);
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
      const config = await this.configResolver.resolveStatusConfig(source, emptyJsonRecord());
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

  logsIndex(request: HttpRequest): HttpResponse {
    return this.llmLogger.index(request);
  }

  logPreview(request: HttpRequest): HttpResponse {
    return this.llmLogger.preview(request);
  }

  logRaw(request: HttpRequest): HttpResponse {
    return this.llmLogger.raw(request);
  }

  logsSettings(request: HttpRequest): HttpResponse {
    return this.llmLogger.settings(request);
  }

  logsKeep(request: HttpRequest): HttpResponse {
    return this.llmLogger.keepSettings(request);
  }

  logsStreamEnabled(request: HttpRequest): HttpResponse {
    return this.llmLogger.streamEnabledSettings(request);
  }

  logsStream(request: HttpRequest): HttpResponse {
    return this.llmLogger.stream(request);
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

  private isGenerationSuccess(response: HttpResponse): boolean {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return false;
    }
    if (response.body.length === 0) {
      return true;
    }
    try {
      const parsed = JSON.parse(response.body) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        return true;
      }
      const error = (parsed as JsonRecord)['error'];
      return error === undefined || error === null || error === false;
    } catch (_err) {
      return true;
    }
  }

  private logRequest(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord): void {
    const model = `${payload['model'] ?? ''}`;
    const stream = asBooleanValue(payload['stream']);
    console.info(`[LLM] source=${source} endpoint=${endpointPath} model=${model} stream=${stream} base=${config.baseUrl}`);
  }
}

class ParallelStreamCandidate {
  index: number = 0;
  streamId: string = '';
  config: ChatCompletionApiConfig = new ChatCompletionApiConfig();
  endpointPath: string = '';
  body: JsonRecord = emptyJsonRecord();
}
