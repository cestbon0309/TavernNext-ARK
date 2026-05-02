import { DataDirectories } from './DataDirectories';
import { SecretsService } from './SecretsService';
import { HttpRequest, HttpResponse, JsonArray, JsonRecord, JsonScalar, emptyJsonRecord } from './HttpTypes';
import { RemoteHttpClient, proxyErrorResponse } from './RemoteHttpClient';
import { asBoolean, asNumber, asRecord, asString, bodyAsRecord, parseJsonRecord } from './JsonUtils';

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

  constructor(dirs: DataDirectories, secrets: SecretsService) {
    this.dirs = dirs;
    this.secrets = secrets;
  }

  async chatCompletionsGenerate(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = asString(body['chat_completion_source']) || 'openai';
    if (source !== 'openai' && source !== 'custom') {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    const endpoint = this.chatCompletionEndpoint(source, body);
    if (endpoint.url.length === 0) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    if (endpoint.apiKey.length === 0 && endpoint.requiresKey) {
      return HttpResponse.json(this.errorTrue(), 400);
    }

    let requestBody = this.openAiChatCompletionBody(body);
    if (source === 'custom') {
      this.mergeCustomYamlObject(requestBody, asString(body['custom_include_body']));
      requestBody = this.withoutCustomYamlKeys(requestBody, asString(body['custom_exclude_body']));
    }
    const headers = this.jsonAuthHeaders(endpoint.apiKey);
    Object.keys(endpoint.headers).forEach((name: string) => headers[name] = endpoint.headers[name]);
    if (source === 'custom') {
      this.mergeCustomYamlHeaders(headers, asString(body['custom_include_headers']));
    }
    if (asBoolean(body['stream'])) {
      const response = HttpResponse.stream('text/event-stream; charset=utf-8', async (send) => {
        try {
          await this.http.streamPostJson(endpoint.url, requestBody, headers, send, 300000);
        } catch (err) {
          const message = err instanceof Error ? err.message : JSON.stringify(err);
          await send(`event: error\ndata: ${JSON.stringify(this.errorFromText(message))}\n\n`);
        }
      });
      response.headers['x-accel-buffering'] = 'no';
      return response;
    }

    try {
      const result = await this.http.postJson(endpoint.url, requestBody, headers);
      if (result.statusCode >= 200 && result.statusCode < 300) {
        return this.http.responseFromRemote(result);
      }
      const error = emptyJsonRecord();
      const message = emptyJsonRecord();
      message['message'] = result.text.length > 0 ? result.text : `HTTP ${result.statusCode}`;
      error['error'] = message;
      return HttpResponse.json(error, 200);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
  }

  async openAiGenerate(request: HttpRequest): Promise<HttpResponse> {
    return this.chatCompletionsGenerate(request);
  }

  async chatCompletionStatus(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const source = asString(body['chat_completion_source']) || 'openai';
    if (source !== 'openai' && source !== 'custom') {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    if (asBoolean(body['bypass_status_check'])) {
      const response = emptyJsonRecord();
      response['bypass'] = true;
      return HttpResponse.json(response);
    }
    const endpoint = this.modelListEndpoint(source, body);
    if (endpoint.url.length === 0) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    if (endpoint.apiKey.length === 0 && endpoint.requiresKey) {
      return HttpResponse.json(this.errorTrue(), 400);
    }
    try {
      const headers = this.jsonAuthHeaders(endpoint.apiKey);
      Object.keys(endpoint.headers).forEach((name: string) => headers[name] = endpoint.headers[name]);
      if (source === 'custom') {
        this.mergeCustomYamlHeaders(headers, asString(body['custom_include_headers']));
      }
      const result = await this.http.getText(endpoint.url, headers, 30000);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return HttpResponse.json(this.errorTrue(), 400);
      }
      return this.http.responseFromRemote(result);
    } catch (err) {
      return proxyErrorResponse(err instanceof Error ? err.message : JSON.stringify(err), 502);
    }
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
    const endpoint = this.modelListEndpoint(source, emptyJsonRecord());
    if (endpoint.url.length === 0 || endpoint.apiKey.length === 0) {
      return HttpResponse.json([]);
    }
    try {
      const result = await this.http.getText(endpoint.url, this.jsonAuthHeaders(endpoint.apiKey), 30000);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return HttpResponse.json([]);
      }
      const data = parseJsonRecord(result.text);
      if (Array.isArray(data['data'])) {
        return HttpResponse.json(data['data'] as Object);
      }
      return HttpResponse.json([]);
    } catch (_err) {
      return HttpResponse.json([]);
    }
  }

  private chatCompletionEndpoint(source: string, body: JsonRecord): EndpointSettings {
    const endpoint = new EndpointSettings();
    if (source === 'openai' || source.length === 0) {
      const reverseProxy = asString(body['reverse_proxy']);
      endpoint.url = this.http.joinUrl(reverseProxy || 'https://api.openai.com/v1', '/chat/completions');
      endpoint.apiKey = reverseProxy.length > 0 ? asString(body['proxy_password']) : this.secret('api_key_openai');
      endpoint.requiresKey = reverseProxy.length === 0;
      return endpoint;
    }
    if (source === 'claude') {
      endpoint.url = this.http.joinUrl(asString(body['reverse_proxy']) || 'https://api.anthropic.com/v1', '/messages');
      endpoint.apiKey = asString(body['proxy_password']) || this.secret('api_key_claude');
      endpoint.headers['anthropic-version'] = '2023-06-01';
      endpoint.headers['anthropic-beta'] = 'prompt-caching-2024-07-31';
      return endpoint;
    }
    if (source === 'makersuite') {
      const key = asString(body['proxy_password']) || this.secret('api_key_makersuite');
      const model = encodeURIComponent(asString(body['model']));
      endpoint.url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(key)}`;
      endpoint.apiKey = '';
      endpoint.requiresKey = key.length === 0;
      return endpoint;
    }
    if (source === 'openrouter') {
      endpoint.url = this.http.joinUrl(asString(body['reverse_proxy']) || 'https://openrouter.ai/api/v1', '/chat/completions');
      endpoint.apiKey = asString(body['proxy_password']) || this.secret('api_key_openrouter');
      endpoint.headers['HTTP-Referer'] = 'https://sillytavern.app';
      endpoint.headers['X-Title'] = 'SillyTavern';
      return endpoint;
    }
    if (source === 'novel') {
      endpoint.url = 'https://api.novelai.net/ai/generate';
      endpoint.apiKey = this.secret('api_key_novel');
      return endpoint;
    }
    if (source === 'custom') {
      const baseUrl = asString(body['custom_url']) || asString(body['reverse_proxy']);
      endpoint.url = baseUrl.length > 0 ? this.http.joinUrl(baseUrl, '/chat/completions') : '';
      endpoint.apiKey = asString(body['proxy_password']) || this.secret('api_key_custom');
      endpoint.requiresKey = false;
      return endpoint;
    }
    const base = this.defaultOpenAiCompatibleBase(source, body);
    endpoint.url = this.http.joinUrl(base.url, '/chat/completions');
    endpoint.apiKey = base.apiKey;
    endpoint.requiresKey = base.requiresKey;
    return endpoint;
  }

  private chatCompletionBody(body: JsonRecord): Object {
    const source = asString(body['chat_completion_source']);
    if (source === 'claude') {
      const request = emptyJsonRecord();
      request['model'] = body['model'] ?? '';
      request['messages'] = body['messages'] ?? [];
      request['max_tokens'] = body['max_tokens'] ?? body['max_completion_tokens'] ?? 300;
      this.setIfPresent(request, 'temperature', body['temperature']);
      this.setIfPresent(request, 'top_p', body['top_p']);
      this.setIfPresent(request, 'top_k', body['top_k']);
      request['stop_sequences'] = body['stop'] ?? [];
      request['stream'] = asBoolean(body['stream']);
      return this.stripUndefined(request);
    }
    if (source === 'makersuite') {
      return this.geminiBody(body);
    }
    return this.stripUndefined(body);
  }

  private geminiBody(body: JsonRecord): Object {
    const contents: Object[] = [];
    const messages = body['messages'];
    if (Array.isArray(messages)) {
      const values = messages as JsonArray;
      for (const item of values) {
        if (item === null || Array.isArray(item) || typeof item !== 'object') {
          continue;
        }
        const message = item as JsonRecord;
        const content = asString(message['content']);
        const part = emptyJsonRecord();
        part['text'] = content;
        const geminiMessage = emptyJsonRecord();
        geminiMessage['role'] = asString(message['role']) === 'assistant' ? 'model' : 'user';
        geminiMessage['parts'] = [part];
        contents.push(geminiMessage);
      }
    }
    const generationConfig = emptyJsonRecord();
    this.setIfPresent(generationConfig, 'maxOutputTokens', body['max_tokens'] ?? body['max_completion_tokens']);
    this.setIfPresent(generationConfig, 'temperature', body['temperature']);
    this.setIfPresent(generationConfig, 'topP', body['top_p']);
    this.setIfPresent(generationConfig, 'topK', body['top_k']);
    const request = emptyJsonRecord();
    request['contents'] = contents;
    request['generationConfig'] = this.stripUndefined(generationConfig);
    return request;
  }

  private defaultOpenAiCompatibleBase(source: string, body: JsonRecord): EndpointSettings {
    const endpoint = new EndpointSettings();
    endpoint.url = asString(body['reverse_proxy']);
    endpoint.apiKey = asString(body['proxy_password']);
    switch (source) {
      case 'openai':
      case '':
        endpoint.requiresKey = endpoint.url.length === 0;
        endpoint.url = endpoint.url || 'https://api.openai.com/v1';
        endpoint.apiKey = endpoint.apiKey || (endpoint.requiresKey ? this.secret('api_key_openai') : '');
        break;
      case 'deepseek':
        endpoint.url = endpoint.url || 'https://api.deepseek.com/beta';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_deepseek');
        break;
      case 'groq':
        endpoint.url = endpoint.url || 'https://api.groq.com/openai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_groq');
        break;
      case 'mistralai':
        endpoint.url = endpoint.url || 'https://api.mistral.ai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_mistralai');
        break;
      case 'xai':
        endpoint.url = endpoint.url || 'https://api.x.ai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_xai');
        break;
      case 'chutes':
        endpoint.url = endpoint.url || 'https://llm.chutes.ai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_chutes');
        break;
      case 'electronhub':
        endpoint.url = endpoint.url || 'https://api.electronhub.ai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_electronhub');
        break;
      case 'nanogpt':
        endpoint.url = endpoint.url || 'https://nano-gpt.com/api/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_nanogpt');
        break;
      case 'aimlapi':
        endpoint.url = endpoint.url || 'https://api.aimlapi.com/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_aimlapi');
        break;
      case 'moonshot':
        endpoint.url = endpoint.url || 'https://api.moonshot.ai/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_moonshot');
        break;
      case 'fireworks':
        endpoint.url = endpoint.url || 'https://api.fireworks.ai/inference/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_fireworks');
        break;
      case 'zai':
        endpoint.url = endpoint.url || 'https://api.z.ai/api/paas/v4';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_zai');
        break;
      case 'siliconflow':
        endpoint.url = endpoint.url || 'https://api.siliconflow.com/v1';
        endpoint.apiKey = endpoint.apiKey || this.secret('api_key_siliconflow');
        break;
      default:
        endpoint.url = endpoint.url || '';
        endpoint.requiresKey = false;
        break;
    }
    return endpoint;
  }

  private openAiChatCompletionBody(body: JsonRecord): JsonRecord {
    const request = emptyJsonRecord();
    const keys = ['messages', 'model', 'temperature', 'max_tokens', 'max_completion_tokens', 'stream',
      'presence_penalty', 'frequency_penalty', 'top_p', 'stop', 'logit_bias', 'seed', 'n', 'user'];
    for (const key of keys) {
      this.setIfPresent(request, key, body[key]);
    }
    if (Array.isArray(body['tools'])) {
      request['tools'] = body['tools'];
      this.setIfPresent(request, 'tool_choice', body['tool_choice']);
    }
    this.mapOpenAiLogprobs(request, body);
    const responseFormat = this.openAiResponseFormat(body);
    if (responseFormat !== null) {
      request['response_format'] = responseFormat;
    }
    this.setOpenAiReasoningFields(request, body);
    return this.stripUndefined(request);
  }

  private modelListEndpoint(source: string, body: JsonRecord): EndpointSettings {
    if (source === 'custom') {
      const endpoint = new EndpointSettings();
      const baseUrl = asString(body['custom_url']) || asString(body['reverse_proxy']);
      endpoint.url = baseUrl.length > 0 ? this.http.joinUrl(baseUrl, '/models') : '';
      endpoint.apiKey = asString(body['proxy_password']) || this.secret('api_key_custom');
      endpoint.requiresKey = false;
      return endpoint;
    }
    const endpoint = this.defaultOpenAiCompatibleBase(source, body);
    if (endpoint.url.length > 0) {
      endpoint.url = this.http.joinUrl(endpoint.url, '/models');
    }
    return endpoint;
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

  private jsonAuthHeaders(apiKey: string): Record<string, string> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };
    if (apiKey.length > 0) {
      headers['Authorization'] = `Bearer ${apiKey}`;
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

  private stripUndefined(value: JsonRecord): JsonRecord {
    const result = emptyJsonRecord();
    Object.keys(value).forEach((key: string) => {
      if (value[key] !== undefined) {
        result[key] = value[key];
      }
    });
    return result;
  }

  private setIfPresent(record: JsonRecord, key: string, value: JsonScalar | JsonArray | undefined): void {
    if (value !== undefined) {
      record[key] = value;
    }
  }

  private mapOpenAiLogprobs(request: JsonRecord, body: JsonRecord): void {
    if (body['logprobs'] === undefined || body['logprobs'] === null) {
      return;
    }
    if (typeof body['logprobs'] === 'boolean') {
      request['logprobs'] = body['logprobs'];
      if (body['logprobs'] === true) {
        this.setIfPresent(request, 'top_logprobs', body['top_logprobs']);
      }
      return;
    }
    const value = asNumber(body['logprobs'], 0);
    if (value > 0) {
      request['logprobs'] = true;
      request['top_logprobs'] = value;
    }
  }

  private openAiResponseFormat(body: JsonRecord): JsonRecord | null {
    if (body['response_format'] !== undefined && body['response_format'] !== null && !Array.isArray(body['response_format']) &&
      typeof body['response_format'] === 'object') {
      return body['response_format'] as JsonRecord;
    }
    const schema = asRecord(body['json_schema']);
    if (Object.keys(schema).length === 0) {
      return null;
    }
    const value = schema['value'];
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      return null;
    }
    const jsonSchema = emptyJsonRecord();
    jsonSchema['name'] = asString(schema['name']) || 'response';
    jsonSchema['strict'] = schema['strict'] === undefined ? true : schema['strict'];
    jsonSchema['schema'] = value as Object;
    const responseFormat = emptyJsonRecord();
    responseFormat['type'] = 'json_schema';
    responseFormat['json_schema'] = jsonSchema;
    return responseFormat;
  }

  private setOpenAiReasoningFields(request: JsonRecord, body: JsonRecord): void {
    const model = asString(body['model']).trim().toLowerCase();
    const effort = asString(body['reasoning_effort']).trim();
    if (effort.length > 0 && effort !== 'auto' && this.isOpenAiReasoningModel(model)) {
      request['reasoning_effort'] = effort === 'min' ? 'minimal' : effort;
    }
    const verbosity = asString(body['verbosity']).trim();
    if (verbosity.length > 0 && model.startsWith('gpt-5')) {
      request['verbosity'] = verbosity;
    }
  }

  private isOpenAiReasoningModel(model: string): boolean {
    return model.startsWith('o1') || model.startsWith('o3') || model.startsWith('o4') || model.startsWith('gpt-5');
  }

  private mergeCustomYamlHeaders(headers: Record<string, string>, text: string): void {
    const custom = this.parseCustomYamlObject(text);
    Object.keys(custom).forEach((key: string) => {
      headers[key] = asString(custom[key]);
    });
  }

  private mergeCustomYamlObject(target: JsonRecord, text: string): void {
    const custom = this.parseCustomYamlObject(text);
    Object.keys(custom).forEach((key: string) => {
      target[key] = custom[key];
    });
  }

  private withoutCustomYamlKeys(target: JsonRecord, text: string): JsonRecord {
    const keys = this.parseCustomYamlKeys(text);
    if (keys.length === 0) {
      return target;
    }
    const result = emptyJsonRecord();
    Object.keys(target).forEach((key: string) => {
      if (!keys.includes(key)) {
        result[key] = target[key];
      }
    });
    return result;
  }

  private parseCustomYamlObject(text: string): JsonRecord {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return emptyJsonRecord();
    }
    try {
      const parsed = JSON.parse(trimmed) as Object;
      if (parsed !== null && !Array.isArray(parsed) && typeof parsed === 'object') {
        return parsed as JsonRecord;
      }
      if (Array.isArray(parsed)) {
        const record = emptyJsonRecord();
        const parsedItems = parsed as Object[];
        for (const item of parsedItems) {
          if (item !== null && !Array.isArray(item) && typeof item === 'object') {
            Object.keys(item as JsonRecord).forEach((key: string) => record[key] = (item as JsonRecord)[key]);
          }
        }
        return record;
      }
    } catch (_err) {
    }

    const record = emptyJsonRecord();
    for (const line of this.customYamlLines(trimmed)) {
      const index = line.indexOf(':');
      if (index <= 0) {
        continue;
      }
      const key = line.slice(0, index).trim();
      if (key.length === 0) {
        continue;
      }
      record[key] = this.parseCustomYamlScalar(line.slice(index + 1).trim());
    }
    return record;
  }

  private parseCustomYamlKeys(text: string): string[] {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(trimmed) as Object;
      if (Array.isArray(parsed)) {
        return parsed.map((value: Object | string | number | boolean | null): string => `${value}`);
      }
      if (parsed !== null && typeof parsed === 'object') {
        return Object.keys(parsed);
      }
      if (typeof parsed === 'string') {
        return [parsed];
      }
    } catch (_err) {
    }

    const keys: string[] = [];
    for (const line of this.customYamlLines(trimmed)) {
      const value = line.startsWith('-') ? line.slice(1).trim() : line.trim();
      const index = value.indexOf(':');
      keys.push(index > 0 ? value.slice(0, index).trim() : value);
    }
    return keys.filter((key: string): boolean => key.length > 0);
  }

  private customYamlLines(text: string): string[] {
    return text.split('\n')
      .map((line: string): string => line.trim())
      .filter((line: string): boolean => line.length > 0 && !line.startsWith('#'));
  }

  private parseCustomYamlScalar(value: string): JsonScalar {
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        return value.slice(1, value.length - 1);
      }
    }
    if (value === 'true') {
      return true;
    }
    if (value === 'false') {
      return false;
    }
    if (value === 'null') {
      return null;
    }
    const numberValue = Number(value);
    if (value.length > 0 && Number.isFinite(numberValue)) {
      return numberValue;
    }
    return value;
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

class EndpointSettings {
  url: string = '';
  apiKey: string = '';
  requiresKey: boolean = true;
  headers: Record<string, string> = {};
}
