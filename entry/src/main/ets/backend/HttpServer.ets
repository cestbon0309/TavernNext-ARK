import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpRequest, HttpResponse, JsonRecord, jsonMessage, RouteHandler } from './HttpTypes';

const DOMAIN = 0x544156;
const TAG = 'TavernHttpServer';

class ClientState {
  buffer: string = '';
  responded: boolean = false;
}

export class HttpServer {
  private server: socket.TCPSocketServer | null = null;
  private startPromise: Promise<void> | null = null;
  private routes: Map<string, RouteHandler> = new Map<string, RouteHandler>();
  private fallbackHandler: RouteHandler | null = null;
  private decoder: util.TextDecoder = new util.TextDecoder();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
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

      const data = this.decoder.decodeToString(new Uint8Array(messageInfo.message));
      state.buffer += data;

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

  private async dispatch(connection: socket.TCPSocketConnection, rawRequest: string): Promise<void> {
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

  private hasCompleteRequest(buffer: string): boolean {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) {
      return false;
    }

    const headerText = buffer.slice(0, headerEnd);
    const headers = this.parseHeaders(headerText.split('\r\n').slice(1));
    const contentLength = Number(headers['content-length'] ?? '0');
    const bodyLength = buffer.length - headerEnd - 4;
    return bodyLength >= contentLength;
  }

  private parseRequest(rawRequest: string): HttpRequest {
    const headerEnd = rawRequest.indexOf('\r\n\r\n');
    const headerText = headerEnd >= 0 ? rawRequest.slice(0, headerEnd) : rawRequest;
    const bodyText = headerEnd >= 0 ? rawRequest.slice(headerEnd + 4) : '';
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
    request.bodyText = bodyText;

    const contentType = request.header('content-type');
    if (bodyText.length > 0 && contentType.includes('application/json')) {
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
}
