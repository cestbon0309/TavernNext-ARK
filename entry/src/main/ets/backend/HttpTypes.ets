export type HeaderMap = Record<string, string>;
export type JsonScalar = Object | string | number | boolean | null;
export type JsonArray = Array<Object | string | number | boolean | null>;
export type JsonRecord = Record<string, JsonScalar | JsonArray>;
export type HttpStreamSend = (chunk: string | Uint8Array) => Promise<void>;
export type HttpStreamHandler = (send: HttpStreamSend) => Promise<void>;

export function emptyJsonRecord(): JsonRecord {
  const value: JsonRecord = {};
  return value;
}

export function jsonMessage(error: string, message: string = ''): JsonRecord {
  const value: JsonRecord = {};
  value['error'] = error;
  if (message.length > 0) {
    value['message'] = message;
  }
  return value;
}

export class HttpRequest {
  method: string = 'GET';
  path: string = '/';
  query: Record<string, string> = {};
  headers: HeaderMap = {};
  bodyText: string = '';
  bodyBytes: Uint8Array = new Uint8Array();
  body: Object | null = null;
  files: HttpUploadedFile[] = [];

  header(name: string): string {
    return this.headers[name.toLowerCase()] ?? '';
  }

  file(name: string): HttpUploadedFile | null {
    for (const file of this.files) {
      if (file.fieldName === name) {
        return file;
      }
    }
    return null;
  }
}

export class HttpUploadedFile {
  fieldName: string;
  fileName: string;
  contentType: string;
  bytes: Uint8Array;

  constructor(fieldName: string, fileName: string, contentType: string, bytes: Uint8Array) {
    this.fieldName = fieldName;
    this.fileName = fileName;
    this.contentType = contentType;
    this.bytes = bytes;
  }
}

export class HttpResponse {
  statusCode: number = 200;
  statusText: string = 'OK';
  headers: HeaderMap = {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type, x-csrf-token',
  };
  body: string = '';
  bodyBytes: Uint8Array | null = null;
  streamHandler: HttpStreamHandler | null = null;

  static json(value: Object | string | number | boolean | null, statusCode: number = 200): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = JSON.stringify(value);
    response.headers['content-type'] = 'application/json; charset=utf-8';
    return response;
  }

  static jsonText(value: string, statusCode: number = 200): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = value;
    response.headers['content-type'] = 'application/json; charset=utf-8';
    return response;
  }

  static text(value: string, statusCode: number = 200, contentType: string = 'text/plain; charset=utf-8'): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = value;
    response.headers['content-type'] = contentType;
    return response;
  }

  static bytes(value: Uint8Array, statusCode: number = 200, contentType: string = 'application/octet-stream'): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = '';
    response.bodyBytes = value;
    response.headers['content-type'] = contentType;
    return response;
  }

  static empty(statusCode: number = 204): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = '';
    response.headers['content-type'] = 'text/plain; charset=utf-8';
    return response;
  }

  static stream(contentType: string, handler: HttpStreamHandler, statusCode: number = 200): HttpResponse {
    const response = new HttpResponse();
    response.statusCode = statusCode;
    response.statusText = statusTextFor(statusCode);
    response.body = '';
    response.streamHandler = handler;
    response.headers['content-type'] = contentType;
    response.headers['cache-control'] = 'no-cache';
    return response;
  }
}

export type RouteHandler = (request: HttpRequest) => Promise<HttpResponse>;

export function statusTextFor(statusCode: number): string {
  switch (statusCode) {
    case 200:
      return 'OK';
    case 204:
      return 'No Content';
    case 400:
      return 'Bad Request';
    case 403:
      return 'Forbidden';
    case 404:
      return 'Not Found';
    case 405:
      return 'Method Not Allowed';
    case 415:
      return 'Unsupported Media Type';
    case 409:
      return 'Conflict';
    case 500:
      return 'Internal Server Error';
    case 501:
      return 'Not Implemented';
    default:
      return 'OK';
  }
}
