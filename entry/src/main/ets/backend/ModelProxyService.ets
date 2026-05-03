import { DataDirectories } from './DataDirectories';
import { SecretsService } from './SecretsService';
import { HttpRequest, HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from './HttpTypes';
import { RemoteHttpClient, proxyErrorResponse } from './RemoteHttpClient';
import { asString, bodyAsRecord, parseJsonRecord } from './JsonUtils';
import { ChatCompletionService } from './model/ChatCompletionService';
import { FileStore } from './FileStore';

class HordeStatusResponse {
  ok: boolean = false;
}

class HordeGenerateResponse {
  id: string = '';
}

export class ModelProxyService {
  private http: RemoteHttpClient = new RemoteHttpClient();
  private secrets: SecretsService;
  private dirs: DataDirectories;
  private chatCompletions: ChatCompletionService;

  constructor(dirs: DataDirectories, secrets: SecretsService) {
    this.dirs = dirs;
    this.secrets = secrets;
    this.chatCompletions = new ChatCompletionService(secrets, dirs, new FileStore());
  }

  async chatCompletionsGenerate(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletions.generate(request);
  }

  async openAiGenerate(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletionsGenerate(request);
  }

  async chatCompletionStatus(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletions.status(request);
  }

  async cancelChatCompletionStream(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletions.cancelStream(request);
  }

  async cancelChatCompletionGeneration(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletions.cancelGeneration(request);
  }

  async textCompletionStatus(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    let apiServer = asString(body['api_server']) || asString(body['server']) || asString(body['url']);
    if (apiServer.includes('localhost')) {
      apiServer = apiServer.replace('localhost', '127.0.0.1');
    }
    if (apiServer.length === 0) {
      return HttpResponse.empty(400);
    }
    const apiType = asString(body['api_type']);
    const baseUrl = this.trimV1(this.http.normalizeBaseUrl(apiServer));
    const path = this.textCompletionModelsPath(apiType);
    try {
      const result = await this.http.getText(this.http.joinUrl(baseUrl, path), this.additionalHeaders(request));
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return HttpResponse.empty(400);
      }
      const data = parseJsonRecord(result.text);
      const models = this.modelArrayForTextGen(apiType, data);
      const response = emptyJsonRecord();
      response['result'] = models.length > 0 ? asString((models[0] as JsonRecord)['id']) || 'Valid' : 'Valid';
      response['data'] = models;
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async textCompletionGenerate(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    let apiServer = asString(body['api_server']) || asString(body['server']) || asString(body['url']);
    if (apiServer.length === 0) {
      return HttpResponse.empty(400);
    }
    const apiType = asString(body['api_type']);
    const baseUrl = this.trimV1(this.http.normalizeBaseUrl(apiServer));
    const path = apiType === 'koboldcpp' ? '/api/v1/generate' : '/v1/completions';
    try {
      const result = await this.http.postJson(this.http.joinUrl(baseUrl, path), request.body ?? emptyJsonRecord(),
        this.additionalHeaders(request));
      return this.http.responseFromRemote(result);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  async novelStatus(): Promise<HttpResponse> {
    const key = this.secret('api_key_novel');
    if (key.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.http.getText('https://api.novelai.net/user/subscription', {
        'Authorization': `Bearer ${key}`,
      });
      return this.http.responseFromRemote(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async novelGenerate(request: HttpRequest): Promise<HttpResponse> {
    const key = this.secret('api_key_novel');
    if (key.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.http.postJson('https://api.novelai.net/ai/generate', request.body ?? emptyJsonRecord(), {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json',
      }, 300000);
      return this.http.responseFromRemote(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async hordeStatus(): Promise<HttpResponse> {
    try {
      const result = await this.http.getText('https://aihorde.net/api/v2/status/heartbeat', {
        'Client-Agent': 'TavernNext-OHOS:1.0.0:github.com/SillyTavern/SillyTavern',
      }, 15000);
      const response = new HordeStatusResponse();
      response.ok = result.statusCode >= 200 && result.statusCode < 300;
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.json(new HordeStatusResponse());
    }
  }

  async hordeTextModels(): Promise<HttpResponse> {
    return this.hordeGetArray('https://aihorde.net/api/v2/status/models?type=text');
  }

  async hordeTextWorkers(): Promise<HttpResponse> {
    return this.hordeGetArray('https://aihorde.net/api/v2/workers?type=text');
  }

  async hordeSdModels(): Promise<HttpResponse> {
    return this.hordeGetArray('https://aihorde.net/api/v2/status/models?type=image');
  }

  async hordeGenerateText(request: HttpRequest): Promise<HttpResponse> {
    const headers = this.hordeHeaders();
    try {
      const result = await this.http.postJson('https://aihorde.net/api/v2/generate/text/async',
        request.body ?? emptyJsonRecord(), headers);
      if (result.statusCode >= 200 && result.statusCode < 300) {
        return this.http.responseFromRemote(result);
      }
      return HttpResponse.json(this.errorFromText(result.text), 200);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  async hordeTaskStatus(request: HttpRequest): Promise<HttpResponse> {
    const taskId = asString(bodyAsRecord(request)['taskId']);
    if (taskId.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.http.getText(`https://aihorde.net/api/v2/generate/text/status/${encodeURIComponent(taskId)}`,
        this.hordeHeaders());
      return this.http.responseFromRemote(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async hordeCancelTask(request: HttpRequest): Promise<HttpResponse> {
    const taskId = asString(bodyAsRecord(request)['taskId']);
    if (taskId.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.http.postJson(`https://aihorde.net/api/v2/generate/text/status/${encodeURIComponent(taskId)}`,
        emptyJsonRecord(), this.hordeHeaders());
      return this.http.responseFromRemote(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async hordeUserInfo(): Promise<HttpResponse> {
    const key = this.secret('api_key_horde') || '0000000000';
    if (key === '0000000000') {
      const response = emptyJsonRecord();
      response['anonymous'] = true;
      return HttpResponse.json(response);
    }
    try {
      const result = await this.http.getText('https://aihorde.net/api/v2/find_user', this.hordeHeaders(), 15000);
      const response = emptyJsonRecord();
      response['anonymous'] = false;
      response['user'] = parseJsonRecord(result.text);
      response['sharedKey'] = emptyJsonRecord();
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async sdProxy(request: HttpRequest, path: string): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const apiUrl = asString(body['apiUrl']) || asString(body['url']) || asString(body['server']);
    if (apiUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.http.postJson(this.http.joinUrl(this.http.normalizeBaseUrl(apiUrl), path),
        request.body ?? emptyJsonRecord(), this.additionalHeaders(request), 300000);
      return this.http.responseFromRemote(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async openAiModelList(source: string): Promise<HttpResponse> {
    return this.chatCompletions.modelList(source);
  }

  llmApiLogsIndex(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logsIndex(request);
  }

  llmApiLogPreview(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logPreview(request);
  }

  llmApiLogRaw(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logRaw(request);
  }

  llmApiLogsSettings(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logsSettings(request);
  }

  llmApiLogsKeep(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logsKeep(request);
  }

  llmApiLogsStreamEnabled(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logsStreamEnabled(request);
  }

  llmApiLogsStream(request: HttpRequest): HttpResponse {
    return this.chatCompletions.logsStream(request);
  }

  private textCompletionModelsPath(apiType: string): string {
    switch (apiType) {
      case 'dreamgen':
        return '/api/openai/v1/models';
      case 'mancer':
        return '/oai/v1/models';
      case 'tabby':
        return '/v1/model/list';
      case 'togetherai':
        return '/api/models?&info';
      case 'ollama':
        return '/api/tags';
      case 'huggingface':
        return '/info';
      default:
        return '/v1/models';
    }
  }

  private modelArrayForTextGen(apiType: string, data: JsonRecord): Object[] {
    const items = data['data'];
    if (Array.isArray(items)) {
      const output: Object[] = [];
      for (const item of items as JsonArray) {
        if (item !== null && !Array.isArray(item) && typeof item === 'object') {
          output.push(item);
        }
      }
      return output;
    }
    const models = data['models'];
    if (apiType === 'ollama' && Array.isArray(models)) {
      const output: Object[] = [];
      for (const model of models as JsonArray) {
        if (model === null || Array.isArray(model) || typeof model !== 'object') {
          continue;
        }
        const record = model as JsonRecord;
        record['id'] = record['name'] ?? '';
        output.push(record);
      }
      return output;
    }
    return [];
  }

  private additionalHeaders(request: HttpRequest): Record<string, string> {
    const headers: Record<string, string> = {};
    const authorization = request.header('authorization');
    if (authorization.length > 0) {
      headers['Authorization'] = authorization;
    }
    const apiKey = request.header('x-api-key');
    if (apiKey.length > 0) {
      headers['X-API-Key'] = apiKey;
    }
    return headers;
  }

  private hordeHeaders(): Record<string, string> {
    return {
      'Content-Type': 'application/json',
      'apikey': this.secret('api_key_horde') || '0000000000',
      'Client-Agent': 'TavernNext-OHOS:1.0.0:github.com/SillyTavern/SillyTavern',
    };
  }

  private async hordeGetArray(url: string): Promise<HttpResponse> {
    try {
      const result = await this.http.getText(url, this.hordeHeaders(), 30000);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return HttpResponse.json([]);
      }
      try {
        const parsed = JSON.parse(result.text) as Object;
        if (Array.isArray(parsed)) {
          return HttpResponse.json(parsed);
        }
        const record = parsed as JsonRecord;
        if (Array.isArray(record['models'])) {
          return HttpResponse.json(record['models'] as Object);
        }
      } catch (_err) {
      }
      return HttpResponse.json([]);
    } catch (_err) {
      return HttpResponse.json([]);
    }
  }

  private trimV1(value: string): string {
    return value.endsWith('/v1') ? value.slice(0, value.length - 3) : value;
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

  private secret(key: string): string {
    return this.secrets.activeSecretValue(key);
  }
}
