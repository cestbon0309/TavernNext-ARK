import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpResponse, HttpStreamSend, statusTextFor } from './HttpTypes';

export class RemoteHttpResult {
  statusCode: number = 0;
  headers: Record<string, string> = {};
  text: string = '';
  bytes: Uint8Array | null = null;
}

export class RemoteHttpClient {
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  async getText(url: string, headers: Record<string, string> = {}, timeoutMs: number = 120000): Promise<RemoteHttpResult> {
    return this.request(url, 'GET', '', headers, timeoutMs, false);
  }

  async postJson(url: string, value: Object, headers: Record<string, string> = {},
    timeoutMs: number = 300000): Promise<RemoteHttpResult> {
    const nextHeaders = this.withHeader(headers, 'Content-Type', 'application/json');
    return this.request(url, 'POST', JSON.stringify(value), nextHeaders, timeoutMs, false);
  }

  async streamPostJson(url: string, value: Object, headers: Record<string, string>, send: HttpStreamSend,
    timeoutMs: number = 300000): Promise<void> {
    const nextHeaders = this.withHeader(headers, 'Content-Type', 'application/json');
    await this.streamRequest(url, 'POST', JSON.stringify(value), nextHeaders, timeoutMs, send);
  }

  async postText(url: string, value: string, headers: Record<string, string> = {},
    timeoutMs: number = 300000): Promise<RemoteHttpResult> {
    return this.request(url, 'POST', value, headers, timeoutMs, false);
  }

  async postBytes(url: string, value: Uint8Array, headers: Record<string, string> = {},
    timeoutMs: number = 300000): Promise<RemoteHttpResult> {
    const buffer = new ArrayBuffer(value.byteLength);
    new Uint8Array(buffer).set(value);
    return this.request(url, 'POST', buffer, headers, timeoutMs, true);
  }

  responseFromRemote(result: RemoteHttpResult): HttpResponse {
    const contentType = result.headers['content-type'] ?? 'application/json; charset=utf-8';
    if (result.bytes !== null) {
      return HttpResponse.bytes(result.bytes, result.statusCode, contentType);
    }
    return HttpResponse.text(result.text, result.statusCode, contentType);
  }

  normalizeBaseUrl(url: string): string {
    let value = url.trim();
    while (value.endsWith('/')) {
      value = value.slice(0, value.length - 1);
    }
    return value;
  }

  joinUrl(baseUrl: string, path: string): string {
    const base = this.normalizeBaseUrl(baseUrl);
    const suffix = path.startsWith('/') ? path : `/${path}`;
    return `${base}${suffix}`;
  }

  private async request(url: string, method: string, body: string | ArrayBuffer, headers: Record<string, string>,
    timeoutMs: number, expectBytes: boolean): Promise<RemoteHttpResult> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headers,
        readTimeout: timeoutMs,
        connectTimeout: timeoutMs,
        expectDataType: expectBytes ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      };
      if (method !== 'GET') {
        options.extraData = body;
      }
      const response = await request.request(url, options);
      const result = new RemoteHttpResult();
      result.statusCode = Number(response.responseCode);
      result.headers = this.headersToRecord(response.header);
      if (response.result instanceof ArrayBuffer) {
        const bytes = new Uint8Array(response.result);
        result.bytes = bytes;
        result.text = this.decoder.decodeToString(bytes);
      } else if (typeof response.result === 'string') {
        result.text = response.result;
      } else {
        result.text = JSON.stringify(response.result);
      }
      return result;
    } finally {
      request.destroy();
    }
  }

  private async streamRequest(url: string, method: string, body: string, headers: Record<string, string>,
    timeoutMs: number, send: HttpStreamSend): Promise<void> {
    const request = http.createHttp();
    let queue: Promise<void> = Promise.resolve();
    let sawChunk = false;
    let resolveDataEnd: () => void = () => {};
    const dataEnd = new Promise<void>((resolve: () => void) => {
      resolveDataEnd = resolve;
    });
    request.on('dataReceive', (data: ArrayBuffer) => {
      sawChunk = true;
      const bytes = new Uint8Array(data);
      const chunk = new Uint8Array(bytes.byteLength);
      chunk.set(bytes);
      queue = queue.then(async () => {
        await send(chunk);
      });
    });
    request.on('dataEnd', () => {
      resolveDataEnd();
    });
    try {
      const options: http.HttpRequestOptions = {
        method: method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headers,
        readTimeout: timeoutMs,
        connectTimeout: timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      if (method !== 'GET') {
        options.extraData = body;
      }
      const statusCode = Number(await request.requestInStream(url, options));
      await dataEnd;
      await queue;
      if (!sawChunk && (statusCode < 200 || statusCode >= 300)) {
        await send(`event: error\ndata: {"error":{"message":"HTTP ${statusCode}"}}\n\n`);
      }
    } finally {
      request.destroy();
    }
  }

  private headersToRecord(value: Object): Record<string, string> {
    const result: Record<string, string> = {};
    const source = value as Record<string, Object | string | number | boolean | null>;
    Object.keys(source).forEach((key: string) => {
      const raw = source[key];
      if (raw === null || raw === undefined) {
        return;
      }
      result[key.toLowerCase()] = `${raw}`;
    });
    return result;
  }

  private withHeader(headers: Record<string, string>, name: string, value: string): Record<string, string> {
    const next: Record<string, string> = {};
    Object.keys(headers).forEach((key: string) => {
      next[key] = headers[key];
    });
    next[name] = value;
    return next;
  }
}

export function proxyErrorResponse(message: string, statusCode: number = 502): HttpResponse {
  const value: Record<string, Object | string | number | boolean | null> = {};
  const error: Record<string, Object | string | number | boolean | null> = {};
  error['message'] = message;
  value['error'] = error;
  return HttpResponse.json(value, statusCode);
}

export function remoteStatusText(statusCode: number): string {
  return statusTextFor(statusCode);
}
