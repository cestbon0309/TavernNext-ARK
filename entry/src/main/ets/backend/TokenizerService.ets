import {
  count as nativeCount,
  decode as nativeDecode,
  encode as nativeEncode,
  resolveModel as nativeResolveModel,
} from 'libtavern_tokenizer.so';
import { util } from '@kit.ArkTS';
import { HttpRequest, HttpResponse, emptyJsonRecord, JsonArray, JsonRecord } from './HttpTypes';
import { RemoteHttpClient } from './RemoteHttpClient';
import { asArray, asString, bodyAsRecord } from './JsonUtils';

type JsonPrimitive = Object | string | number | boolean | null;

const BYTES_PER_TOKEN = 3.35;
const NON_NATIVE_TOKENIZER_NAMES: string[] = [
  'gpt2',
  'llama',
  'nerdstash',
  'nerdstash_v2',
  'mistral',
  'yi',
  'claude',
  'llama3',
  'gemma',
  'jamba',
  'qwen2',
  'command-r',
  'command-a',
  'nemo',
  'deepseek',
];

class EncodeResponse {
  ids: number[] = [];
  count: number = 0;
  chunks: string[] = [];
}

class DecodeResponse {
  text: string = '';
  chunks: string[] = [];
}

export class TokenizerService {
  private http: RemoteHttpClient = new RemoteHttpClient();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  encode(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const text = asString(body['text']);
    const model = this.modelFromRequest(request);
    if (this.canUseNativeTokenizer(model)) {
      try {
        const encoded = nativeEncode(model, text);
        const response = new EncodeResponse();
        response.ids = this.numberArray(encoded.ids);
        response.count = response.ids.length;
        response.chunks = this.tokenChunks(model, response.ids);
        return HttpResponse.json(response);
      } catch (_err) {
      }
    }

    const ids = this.byteTokenIds(text);
    const response = new EncodeResponse();
    response.ids = ids;
    response.count = ids.length;
    response.chunks = this.chunkText(text);
    return HttpResponse.json(response);
  }

  decode(request: HttpRequest): HttpResponse {
    const ids = asArray(bodyAsRecord(request)['ids']);
    const model = this.modelFromRequest(request);
    const nativeIds = this.numberArray(ids);
    if (this.canUseNativeTokenizer(model)) {
      try {
        const response = new DecodeResponse();
        response.text = nativeDecode(model, nativeIds);
        response.chunks = this.tokenChunks(model, nativeIds);
        return HttpResponse.json(response);
      } catch (_err) {
      }
    }

    const bytes: number[] = [];
    for (const value of ids) {
      const code = Number(value);
      if (!Number.isFinite(code)) {
        continue;
      }
      if (code >= 0 && code <= 255) {
        bytes.push(code);
      }
    }
    const response = new DecodeResponse();
    response.text = this.decoder.decodeToString(new Uint8Array(bytes));
    response.chunks = this.chunkText(response.text);
    return HttpResponse.json(response);
  }

  countOpenAi(request: HttpRequest): HttpResponse {
    const body = this.bodyAsArray(request);
    const model = this.modelFromRequest(request);
    const response = emptyJsonRecord();
    if (this.canUseNativeTokenizer(model)) {
      try {
        response['token_count'] = this.countOpenAiMessages(model, body);
        return HttpResponse.json(response);
      } catch (_err) {
      }
    }
    response['token_count'] = this.estimateJsonTokens(request.body);
    return HttpResponse.json(response);
  }

  bias(request: HttpRequest): HttpResponse {
    const result = emptyJsonRecord();
    const body = request.body;
    if (!Array.isArray(body)) {
      return HttpResponse.empty(400);
    }

    const model = this.modelFromRequest(request);
    if (this.resolveTokenizerModel(model) === 'claude') {
      return HttpResponse.json(result);
    }

    const entries: JsonPrimitive[] = body as JsonPrimitive[];
    for (const item of entries) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const entry = item as JsonRecord;
      const text = asString(entry['text']);
      if (text.length === 0) {
        continue;
      }

      let ids = this.idsFromRawTokenArray(text);
      if (ids.length === 0) {
        ids = this.canUseNativeTokenizer(model) ? this.safeNativeEncode(model, text) : this.byteTokenIds(text);
      }
      const value = entry['value'];
      for (const id of ids) {
        result[`${id}`] = typeof value === 'number' ? value : Number(value ?? 0);
      }
    }
    return HttpResponse.json(result);
  }

  async remoteKoboldCount(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const text = asString(body['text']);
    const baseUrl = this.http.normalizeBaseUrl(asString(body['url']));
    if (baseUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    const payload = emptyJsonRecord();
    payload['prompt'] = text;
    try {
      const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/extra/tokencount'), payload);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        const error = emptyJsonRecord();
        error['error'] = true;
        return HttpResponse.json(error);
      }
      return HttpResponse.text(result.text, 200, 'application/json; charset=utf-8');
    } catch (_err) {
      const error = emptyJsonRecord();
      error['error'] = true;
      return HttpResponse.json(error);
    }
  }

  async remoteTextGenEncode(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const text = asString(body['text']);
    const model = asString(body['model']);
    const apiType = asString(body['api_type']);
    let baseUrl = this.http.normalizeBaseUrl(asString(body['url']));
    if (baseUrl.endsWith('/v1')) {
      baseUrl = baseUrl.slice(0, baseUrl.length - 3);
    }
    if (baseUrl.length === 0) {
      return HttpResponse.empty(400);
    }

    let path = '/v1/internal/encode';
    const payload = emptyJsonRecord();
    if (apiType === 'tabby') {
      path = '/v1/token/encode';
      payload['text'] = text;
      payload['add_bos_token'] = false;
    } else if (apiType === 'koboldcpp') {
      path = '/api/extra/tokencount';
      payload['prompt'] = text;
      payload['special'] = false;
    } else if (apiType === 'llamacpp') {
      path = '/tokenize';
      payload['model'] = model;
      payload['content'] = text;
    } else if (apiType === 'vllm') {
      path = '/tokenize';
      payload['model'] = model;
      payload['prompt'] = text;
    } else if (apiType === 'aphrodite') {
      path = '/v1/tokenize';
      payload['model'] = model;
      payload['prompt'] = text;
    } else {
      payload['text'] = text;
    }

    try {
      const result = await this.http.postJson(this.http.joinUrl(baseUrl, path), payload,
        this.additionalHeadersFromRequest(request));
      if (result.statusCode < 200 || result.statusCode >= 300) {
        const error = emptyJsonRecord();
        error['error'] = true;
        return HttpResponse.json(error);
      }
      const data = this.parseJson(result.text);
      const response = emptyJsonRecord();
      response['count'] = this.firstNumber(data, ['length', 'count', 'value']) ?? this.asTokenArray(data).length;
      response['ids'] = this.asTokenArray(data);
      return HttpResponse.json(response);
    } catch (_err) {
      const error = emptyJsonRecord();
      error['error'] = true;
      return HttpResponse.json(error);
    }
  }

  private byteTokenIds(text: string): number[] {
    const bytes = this.encoder.encodeInto(text);
    const ids: number[] = [];
    for (let index = 0; index < bytes.byteLength; index += 1) {
      ids.push(bytes[index]);
    }
    return ids;
  }

  private modelFromRequest(request: HttpRequest): string {
    const queryModel = request.query['model'] ?? '';
    if (queryModel.length > 0) {
      return queryModel;
    }

    const prefix = '/api/tokenizers/';
    if (!request.path.startsWith(prefix)) {
      return '';
    }
    const rest = request.path.slice(prefix.length);
    const slash = rest.indexOf('/');
    const routeModel = slash >= 0 ? rest.slice(0, slash) : rest;
    return routeModel === 'openai' ? '' : routeModel;
  }

  private resolveTokenizerModel(model: string): string {
    try {
      return nativeResolveModel(model);
    } catch (_err) {
      return model.trim().length === 0 ? 'gpt-3.5-turbo' : model.trim().toLowerCase();
    }
  }

  private canUseNativeTokenizer(model: string): boolean {
    if (NON_NATIVE_TOKENIZER_NAMES.includes(model)) {
      return false;
    }
    const resolved = this.resolveTokenizerModel(model);
    return resolved === 'o1' || resolved === 'gpt-4o' || resolved === 'gpt-4' || resolved === 'gpt-4-32k' ||
      resolved === 'gpt-3.5-turbo' || resolved === 'gpt-3.5-turbo-0301';
  }

  private safeNativeEncode(model: string, text: string): number[] {
    try {
      return this.numberArray(nativeEncode(model, text).ids);
    } catch (_err) {
      return [];
    }
  }

  private tokenChunks(model: string, ids: number[]): string[] {
    const chunks: string[] = [];
    for (const id of ids) {
      try {
        chunks.push(nativeDecode(model, [id]));
      } catch (_err) {
        chunks.push('');
      }
    }
    return chunks;
  }

  private bodyAsArray(request: HttpRequest): JsonArray {
    const body = request.body;
    if (Array.isArray(body)) {
      return body;
    }
    if (body === null) {
      return [];
    }
    return [body];
  }

  private countOpenAiMessages(model: string, messages: JsonArray): number {
    const resolved = this.resolveTokenizerModel(model);
    const legacy = resolved === 'gpt-3.5-turbo-0301';
    const tokensPerMessage = legacy ? 4 : 3;
    const tokensPerName = legacy ? -1 : 1;
    let total = 0;

    for (const message of messages) {
      total += tokensPerMessage;
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        total += nativeCount(model, this.valueToText(message));
        continue;
      }

      const record = message as JsonRecord;
      Object.keys(record).forEach((key: string) => {
        total += nativeCount(model, this.valueToText(record[key]));
        if (key === 'name') {
          total += tokensPerName;
        }
      });
    }

    total += 3;
    if (legacy) {
      total += 9;
    }
    return Math.max(0, total);
  }

  private valueToText(value: Object | string | number | boolean | null | JsonArray | undefined): string {
    if (typeof value === 'string') {
      return value;
    }
    return JSON.stringify(value ?? '');
  }

  private idsFromRawTokenArray(text: string): number[] {
    const trimmed = text.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      return [];
    }
    try {
      const value = JSON.parse(trimmed) as Object;
      if (!Array.isArray(value)) {
        return [];
      }
      return this.numberArray(value);
    } catch (_err) {
      return [];
    }
  }

  private numberArray(values: Object | JsonArray | number[] | undefined): number[] {
    if (!Array.isArray(values)) {
      return [];
    }
    const result: number[] = [];
    const entries: JsonPrimitive[] | number[] = values as JsonPrimitive[] | number[];
    for (const value of entries) {
      const id = Number(value);
      if (Number.isFinite(id) && id >= 0) {
        result.push(Math.floor(id));
      }
    }
    return result;
  }

  private chunkText(text: string): string[] {
    const chunks: string[] = [];
    for (const char of text) {
      chunks.push(char);
    }
    return chunks;
  }

  private estimateJsonTokens(value: Object | string | number | boolean | null): number {
    const text = typeof value === 'string' ? value : JSON.stringify(value ?? '');
    return Math.ceil(this.encoder.encodeInto(text).byteLength / BYTES_PER_TOKEN);
  }

  private additionalHeadersFromRequest(request: HttpRequest): Record<string, string> {
    const headers: Record<string, string> = {};
    const body = bodyAsRecord(request);
    const names = ['authorization', 'x-api-key', 'x-st-api-key'];
    for (const name of names) {
      const value = asString(body[name]);
      if (value.length > 0) {
        headers[name] = value;
      }
    }
    return headers;
  }

  private parseJson(text: string): JsonRecord {
    try {
      const value = JSON.parse(text) as Object;
      if (value === null || Array.isArray(value) || typeof value !== 'object') {
        return emptyJsonRecord();
      }
      return value as JsonRecord;
    } catch (_err) {
      return emptyJsonRecord();
    }
  }

  private firstNumber(data: JsonRecord, keys: string[]): number | null {
    for (const key of keys) {
      const value = data[key];
      if (typeof value === 'number') {
        return value;
      }
    }
    return null;
  }

  private asTokenArray(data: JsonRecord): JsonArray {
    const tokens = data['tokens'];
    if (Array.isArray(tokens)) {
      return tokens;
    }
    const ids = data['ids'];
    if (Array.isArray(ids)) {
      return ids;
    }
    return [];
  }
}
