import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpRequest, HttpResponse, JsonRecord, jsonMessage, RouteHandler } from './HttpTypes';
import { MultipartParser } from './MultipartParser';

const DOMAIN = 0x544156;
const TAG = 'TavernHttpServer';

class ClientState {
  buffer: Uint8Array = new Uint8Array();
  responded: boolean = false;
}

export class HttpServer {
  private server: socket.TCPSocketServer | null = null;
  private startPromise: Promise<void> | null = null;
  private routes: Map<string, RouteHandler> = new Map<string, RouteHandler>();
  private fallbackHandler: RouteHandler | null = null;
  private decoder: util.TextDecoder = new util.TextDecoder();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private multipartParser: MultipartParser = new MultipartParser();
  private listening: boolean = false;
  readonly host: string;
  readonly port: number;

  constructor(host: string = '127.0.0.1', port: number = 8000) {
    this.host = host;
    this.port = port;
  }

  route(method: string, path: string, handler: RouteHandler): void {
    this.routes.set(`${method.toUpperCase()} ${path}`, handler);
  }

  fallback(handler: RouteHandler): void {
    this.fallbackHandler = handler;
  }

  isListening(): boolean {
    return this.listening;
  }

  async start(): Promise<void> {
    if (this.listening) {
      return;
    }
    if (this.startPromise !== null) {
      return this.startPromise;
    }

    this.startPromise = this.listenOnce();
    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  private async listenOnce(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (connection: socket.TCPSocketConnection) => {
      this.handleConnection(connection);
    });
    server.on('error', (err: Error) => {
      hilog.error(DOMAIN, TAG, 'Server error: %{public}s', JSON.stringify(err));
    });

    try {
      await server.listen({ address: this.host, port: this.port });
    } catch (err) {
      this.server = null;
      hilog.error(DOMAIN, TAG, 'Listen failed: %{public}s', JSON.stringify(err));
      throw new Error(`Listen failed: ${JSON.stringify(err)}`);
    }
    this.listening = true;
    hilog.info(DOMAIN, TAG, 'Listening on http://%{public}s:%{public}d', this.host, this.port);
  }

  async stop(): Promise<void> {
    if (this.server === null) {
      return;
    }
    try {
      await this.server.close();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Close failed: %{public}s', JSON.stringify(err));
    }
    this.server = null;
    this.listening = false;
  }

  private handleConnection(connection: socket.TCPSocketConnection): void {
    const state = new ClientState();
    connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
      if (state.responded) {
        return;
      }

      state.buffer = this.concatBytes(state.buffer, new Uint8Array(messageInfo.message));

      if (!this.hasCompleteRequest(state.buffer)) {
        return;
      }

      state.responded = true;
      hilog.info(DOMAIN, TAG, 'Request received');
      this.dispatch(connection, state.buffer);
    });
    connection.on('error', (err: Error) => {
      hilog.warn(DOMAIN, TAG, 'Client error: %{public}s', JSON.stringify(err));
    });
  }

  private async dispatch(connection: socket.TCPSocketConnection, rawRequest: Uint8Array): Promise<void> {
    let response: HttpResponse;
    try {
      const request = this.parseRequest(rawRequest);
      hilog.info(DOMAIN, TAG, '%{public}s %{public}s', request.method, request.path);
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

    try {
      await connection.send({ data: this.serializeResponse(response) });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Send failed: %{public}s', JSON.stringify(err));
    }

    try {
      await connection.close();
    } catch (_err) {
    }
  }

  private hasCompleteRequest(buffer: Uint8Array): boolean {
    const headerEnd = this.indexOfBytes(buffer, this.asciiBytes('\r\n\r\n'), 0);
    if (headerEnd < 0) {
      return false;
    }

    const headerText = this.decoder.decodeToString(buffer.slice(0, headerEnd));
    const headers = this.parseHeaders(headerText.split('\r\n').slice(1));
    const contentLength = Number(headers['content-length'] ?? '0');
    const bodyLength = buffer.byteLength - headerEnd - 4;
    return bodyLength >= contentLength;
  }

  private parseRequest(rawRequest: Uint8Array): HttpRequest {
    const headerEnd = this.indexOfBytes(rawRequest, this.asciiBytes('\r\n\r\n'), 0);
    const headerText = headerEnd >= 0 ? this.decoder.decodeToString(rawRequest.slice(0, headerEnd)) :
      this.decoder.decodeToString(rawRequest);
    const lines = headerText.split('\r\n');
    const requestLine = lines[0].split(' ');
    const method = requestLine[0]?.toUpperCase() ?? 'GET';
    const rawUrl = requestLine[1] ?? '/';
    const questionIndex = rawUrl.indexOf('?');
    const path = questionIndex >= 0 ? rawUrl.slice(0, questionIndex) : rawUrl;
    const queryText = questionIndex >= 0 ? rawUrl.slice(questionIndex + 1) : '';

    const request = new HttpRequest();
    request.method = method;
    request.path = decodeURIComponent(path);
    request.query = this.parseQuery(queryText);
    request.headers = this.parseHeaders(lines.slice(1));
    request.bodyBytes = this.rawBodyBytes(rawRequest, headerEnd);
    const bodyText = this.decoder.decodeToString(request.bodyBytes);
    request.bodyText = bodyText;

    const contentType = request.header('content-type');
    if (request.bodyBytes.byteLength > 0 && contentType.includes('multipart/form-data')) {
      try {
        const multipart = this.multipartParser.parse(contentType, request.bodyBytes);
        request.body = multipart.fields;
        request.files = multipart.files;
      } catch (err) {
        const error = new Error(`invalid_multipart: ${JSON.stringify(err)}`);
        error.name = 'BadRequest';
        throw error;
      }
    } else if (bodyText.length > 0 && contentType.includes('application/json')) {
      try {
        request.body = JSON.parse(bodyText) as JsonRecord;
      } catch (_err) {
        const error = new Error('invalid_json');
        error.name = 'BadRequest';
        throw error;
      }
    }

    return request;
  }

  private rawBodyBytes(rawRequest: Uint8Array, headerEnd: number): Uint8Array {
    if (headerEnd < 0) {
      return new Uint8Array();
    }
    const bodyStart = headerEnd + 4;
    return rawRequest.slice(bodyStart);
  }

  private parseHeaders(lines: string[]): Record<string, string> {
    const headers: Record<string, string> = {};
    for (const line of lines) {
      const index = line.indexOf(':');
      if (index < 0) {
        continue;
      }
      const name = line.slice(0, index).trim().toLowerCase();
      const value = line.slice(index + 1).trim();
      headers[name] = value;
    }
    return headers;
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

  private serializeResponse(response: HttpResponse): ArrayBuffer {
    const bodyBytes = response.bodyBytes ?? this.encoder.encodeInto(response.body);
    response.headers['content-length'] = `${bodyBytes.byteLength}`;
    response.headers['connection'] = 'close';

    const lines: string[] = [`HTTP/1.1 ${response.statusCode} ${response.statusText}`];
    Object.keys(response.headers).forEach((name: string) => {
      lines.push(`${name}: ${response.headers[name]}`);
    });
    lines.push('');
    lines.push('');

    const headerBytes = this.encoder.encodeInto(lines.join('\r\n'));
    const packet = new Uint8Array(headerBytes.byteLength + bodyBytes.byteLength);
    packet.set(headerBytes, 0);
    packet.set(bodyBytes, headerBytes.byteLength);
    return packet.buffer;
  }

  private concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
    const output = new Uint8Array(left.byteLength + right.byteLength);
    output.set(left, 0);
    output.set(right, left.byteLength);
    return output;
  }

  private asciiBytes(value: string): Uint8Array {
    const output = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index += 1) {
      output[index] = value.charCodeAt(index) & 0xff;
    }
    return output;
  }

  private indexOfBytes(source: Uint8Array, target: Uint8Array, start: number): number {
    if (target.byteLength === 0) {
      return start;
    }
    for (let index = Math.max(0, start); index <= source.byteLength - target.byteLength; index += 1) {
      let matched = true;
      for (let inner = 0; inner < target.byteLength; inner += 1) {
        if (source[index + inner] !== target[inner]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return index;
      }
    }
    return -1;
  }
}
