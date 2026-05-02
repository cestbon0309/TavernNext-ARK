import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { CancellationToken } from './CancellationToken';
import { HttpResponse, HttpStreamSend, statusTextFor } from './HttpTypes';

export type RemoteSseDataHandler = (payload: string) => Promise<void>;

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
    timeoutMs: number = 300000, cancelToken?: CancellationToken): Promise<void> {
    const nextHeaders = this.withHeader(headers, 'Content-Type', 'application/json');
    await this.streamRequest(url, 'POST', JSON.stringify(value), nextHeaders, timeoutMs, send, cancelToken);
  }

  async streamPostJsonEvents(url: string, value: Object, headers: Record<string, string>,
    onEvent: RemoteSseDataHandler, timeoutMs: number = 300000, cancelToken?: CancellationToken): Promise<void> {
    const nextHeaders = this.withHeader(headers, 'Content-Type', 'application/json');
    await this.streamEventRequest(url, 'POST', JSON.stringify(value), nextHeaders, timeoutMs, onEvent, cancelToken);
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
    timeoutMs: number, send: HttpStreamSend, cancelToken?: CancellationToken): Promise<void> {
    const request = http.createHttp();
    cancelToken?.onCancel(() => {
      request.destroy();
    });
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
      if (cancelToken?.isCancelled()) {
        return;
      }
      if (!sawChunk && (statusCode < 200 || statusCode >= 300)) {
        await send(`event: error\ndata: {"error":{"message":"HTTP ${statusCode}"}}\n\n`);
      }
    } finally {
      request.destroy();
    }
  }

  private async streamEventRequest(url: string, method: string, body: string, headers: Record<string, string>,
    timeoutMs: number, onEvent: RemoteSseDataHandler, cancelToken?: CancellationToken): Promise<void> {
    const request = http.createHttp();
    cancelToken?.onCancel(() => {
      request.destroy();
    });
    let queue: Promise<void> = Promise.resolve();
    let sawChunk = false;
    let textBuffer = '';
    const accumulator = new RemoteSseAccumulator();
    let resolveDataEnd: () => void = () => {};
    const dataEnd = new Promise<void>((resolve: () => void) => {
      resolveDataEnd = resolve;
    });
    request.on('dataReceive', (data: ArrayBuffer) => {
      sawChunk = true;
      const chunk = this.decoder.decodeToString(new Uint8Array(data));
      queue = queue.then(async () => {
        textBuffer += chunk;
        textBuffer = await this.forwardSseText(textBuffer, accumulator, onEvent);
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
      if (cancelToken?.isCancelled()) {
        return;
      }
      if (textBuffer.length > 0) {
        await accumulator.onLine(this.stripTrailingCr(textBuffer), onEvent);
      }
      await accumulator.finish(onEvent);
      if (!sawChunk && (statusCode < 200 || statusCode >= 300)) {
        const value: Record<string, Object | string | number | boolean | null> = {};
        const error: Record<string, Object | string | number | boolean | null> = {};
        error['message'] = `HTTP ${statusCode}`;
        value['error'] = error;
        await onEvent(JSON.stringify(value));
      }
    } finally {
      request.destroy();
    }
  }

  private async forwardSseText(buffer: string, accumulator: RemoteSseAccumulator,
    onEvent: RemoteSseDataHandler): Promise<string> {
    let lineStart = 0;
    let consumed = 0;
    for (let index = 0; index < buffer.length; index += 1) {
      if (buffer.charAt(index) !== '\n') {
        continue;
      }
      const line = this.stripTrailingCr(buffer.slice(lineStart, index));
      await accumulator.onLine(line, onEvent);
      consumed = index + 1;
      lineStart = consumed;
    }
    return consumed > 0 ? buffer.slice(consumed) : buffer;
  }

  private stripTrailingCr(value: string): string {
    return value.endsWith('\r') ? value.slice(0, value.length - 1) : value;
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

class RemoteSseAccumulator {
  private data: string = '';

  async onLine(line: string, onEvent: RemoteSseDataHandler): Promise<void> {
    if (line.length === 0) {
      await this.dispatch(onEvent);
      return;
    }
    if (line.startsWith(':')) {
      return;
    }
    const index = line.indexOf(':');
    const field = index >= 0 ? line.slice(0, index) : line;
    if (field !== 'data') {
      return;
    }
    let value = index >= 0 ? line.slice(index + 1) : '';
    while (value.startsWith(' ') || value.startsWith('\t')) {
      value = value.slice(1);
    }
    if (this.data.length > 0) {
      this.data += '\n';
    }
    this.data += value;
  }

  async finish(onEvent: RemoteSseDataHandler): Promise<void> {
    await this.dispatch(onEvent);
  }

  private async dispatch(onEvent: RemoteSseDataHandler): Promise<void> {
    if (this.data.length === 0) {
      return;
    }
    const payload = this.data;
    this.data = '';
    await onEvent(payload);
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
