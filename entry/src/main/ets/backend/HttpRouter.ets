import { util } from '@kit.ArkTS';
import { DiagnosticLogService as hilog } from './DiagnosticLogService';
import { HeaderMap, HttpRequest, HttpResponse, JsonArray, JsonRecord, jsonMessage, RouteHandler } from './HttpTypes';
import { MultipartParser } from './MultipartParser';

const DOMAIN = 0x5441;
const TAG = 'TavernHttpRouter';

// Origin the WebView loads the frontend from. Nothing listens on it: WebSchemeTransport answers these requests
// in-process, and native code reaches the same routes through LocalBackend.
export const LOCAL_BACKEND_ORIGIN = 'http://127.0.0.1:8000';

export class HttpRouter {
  private routes: Map<string, RouteHandler> = new Map<string, RouteHandler>();
  private fallbackHandler: RouteHandler | null = null;
  private decoder: util.TextDecoder = new util.TextDecoder();
  private multipartParser: MultipartParser = new MultipartParser();
  private requestTimingEntries: JsonRecord[] = [];

  route(method: string, path: string, handler: RouteHandler): void {
    this.routes.set(`${method.toUpperCase()} ${path}`, handler);
  }

  fallback(handler: RouteHandler): void {
    this.fallbackHandler = handler;
  }

  requestTimingsJson(): JsonArray {
    const result: JsonArray = [];
    for (const entry of this.requestTimingEntries) {
      result.push(entry);
    }
    return result;
  }

  // rawUrl is the path plus optional query string, still percent-encoded. Header names must be lower-case.
  async dispatch(method: string, rawUrl: string, headers: HeaderMap, bodyBytes: Uint8Array): Promise<HttpResponse> {
    const startedAt = Date.now();
    const upperMethod = method.toUpperCase();
    const questionIndex = rawUrl.indexOf('?');
    let path = questionIndex >= 0 ? rawUrl.slice(0, questionIndex) : rawUrl;
    let response: HttpResponse;
    try {
      const request = this.createRequest(upperMethod, rawUrl, headers, bodyBytes);
      path = request.path;
      if (request.method === 'OPTIONS') {
        response = HttpResponse.empty(204);
      } else {
        const handler = this.routes.get(`${request.method} ${request.path}`);
        if (handler) {
          response = await handler(request);
        } else if (this.fallbackHandler !== null) {
          response = await this.fallbackHandler(request);
        } else {
          const notImplemented = jsonMessage('not_implemented');
          notImplemented['path'] = request.path;
          response = HttpResponse.json(notImplemented, 501);
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Dispatch failed: %{public}s', JSON.stringify(err));
      if (err instanceof Error && err.name === 'BadRequest') {
        response = HttpResponse.json(jsonMessage('bad_request', err.message), 400);
      } else {
        response = HttpResponse.json(jsonMessage('internal_error'), 500);
      }
    }
    this.recordRequestTiming(upperMethod, path, response.statusCode, Date.now() - startedAt);
    return response;
  }

  private createRequest(method: string, rawUrl: string, headers: HeaderMap, bodyBytes: Uint8Array): HttpRequest {
    const questionIndex = rawUrl.indexOf('?');
    const path = questionIndex >= 0 ? rawUrl.slice(0, questionIndex) : rawUrl;
    const queryText = questionIndex >= 0 ? rawUrl.slice(questionIndex + 1) : '';

    const request = new HttpRequest();
    request.method = method;
    try {
      request.path = decodeURIComponent(path);
      request.query = this.parseQuery(queryText);
    } catch (_err) {
      throw this.badRequest('invalid_url');
    }
    request.headers = headers;
    request.bodyBytes = bodyBytes;
    const bodyText = this.decoder.decodeToString(bodyBytes);
    request.bodyText = bodyText;

    const contentType = request.header('content-type');
    if (bodyBytes.byteLength > 0 && contentType.includes('multipart/form-data')) {
      try {
        const multipart = this.multipartParser.parse(contentType, bodyBytes);
        request.body = multipart.fields;
        request.files = multipart.files;
      } catch (err) {
        throw this.badRequest(`invalid_multipart: ${JSON.stringify(err)}`);
      }
    } else if (bodyText.length > 0 && contentType.includes('application/json')) {
      try {
        request.body = JSON.parse(bodyText) as JsonRecord;
      } catch (_err) {
        throw this.badRequest('invalid_json');
      }
    }

    return request;
  }

  private badRequest(message: string): Error {
    const error = new Error(message);
    error.name = 'BadRequest';
    return error;
  }

  private parseQuery(queryText: string): Record<string, string> {
    const query: Record<string, string> = {};
    if (queryText.length === 0) {
      return query;
    }
    for (const pair of queryText.split('&')) {
      const index = pair.indexOf('=');
      if (index >= 0) {
        query[decodeURIComponent(pair.slice(0, index))] = decodeURIComponent(pair.slice(index + 1));
      } else {
        query[decodeURIComponent(pair)] = '';
      }
    }
    return query;
  }

  private recordRequestTiming(method: string, path: string, statusCode: number, handlerDurationMs: number): void {
    const entry: JsonRecord = {};
    entry['method'] = method;
    entry['path'] = path;
    entry['statusCode'] = statusCode;
    entry['handlerDurationMs'] = handlerDurationMs;
    entry['totalDurationMs'] = handlerDurationMs;
    entry['finishedAtMs'] = Date.now();
    this.requestTimingEntries.push(entry);
    while (this.requestTimingEntries.length > 300) {
      this.requestTimingEntries.shift();
    }
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s %{public}d handler=%{public}d ms', method, path, statusCode,
      handlerDurationMs);
  }
}
