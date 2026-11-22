import { util } from '@kit.ArkTS';
import { webview, WebNetErrorList } from '@kit.ArkWeb';
import { DiagnosticLogService as hilog } from './DiagnosticLogService';
import { HeaderMap, HttpResponse, jsonMessage } from './HttpTypes';
import { HttpRouter, LOCAL_BACKEND_ORIGIN } from './HttpRouter';

const DOMAIN = 0x5441;
const TAG = 'TavernWebTransport';
const LOCALHOST_ORIGIN = 'http://localhost:8000';
const BODY_READ_CHUNK_BYTES = 1024 * 1024;

// Answers the WebView's requests to the backend origin in-process, so the backend needs no listening socket.
export class WebSchemeTransport {
  private router: HttpRouter;
  private handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private configured: boolean = false;

  constructor(router: HttpRouter) {
    this.router = router;
  }

  // Must run from the Web component's onControllerAttached so the first page request is already intercepted.
  attach(controller: webview.WebviewController): void {
    if (!this.configured) {
      this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest,
        resourceHandler: webview.WebResourceHandler): boolean => this.onRequestStart(request, resourceHandler));
      this.configured = true;
    }
    try {
      controller.setWebSchemeHandler('http', this.handler);
      webview.WebviewController.setServiceWorkerWebSchemeHandler('http', this.handler);
    } catch (err) {
      // Without the handler the page cannot reach the backend at all, so make the cause visible in the log.
      hilog.error(DOMAIN, TAG, 'Failed to register the web scheme handler: %{public}s', JSON.stringify(err));
    }
  }

  private onRequestStart(request: webview.WebSchemeHandlerRequest, resourceHandler: webview.WebResourceHandler): boolean {
    const url = request.getRequestUrl();
    const rawUrl = this.localRawUrl(url);
    if (rawUrl.length === 0) {
      return false;
    }
    // The request object is only read here; it may not outlive this callback.
    const method = request.getRequestMethod();
    const headers: HeaderMap = {};
    for (const header of request.getHeader()) {
      headers[header.headerKey.toLowerCase()] = header.headerValue;
    }
    const stream = request.getHttpBodyStream();
    this.serve(url, method, rawUrl, headers, stream, resourceHandler);
    return true;
  }

  // Returns the path and query of a backend URL, or '' when the URL belongs to another origin.
  private localRawUrl(url: string): string {
    for (const origin of [LOCAL_BACKEND_ORIGIN, LOCALHOST_ORIGIN]) {
      if (url.length >= origin.length && url.slice(0, origin.length).toLowerCase() === origin) {
        let rest = url.slice(origin.length);
        const hashIndex = rest.indexOf('#');
        if (hashIndex >= 0) {
          rest = rest.slice(0, hashIndex);
        }
        if (rest.length === 0) {
          return '/';
        }
        if (rest.startsWith('/')) {
          return rest;
        }
        if (rest.startsWith('?')) {
          return `/${rest}`;
        }
      }
    }
    return '';
  }

  private async serve(url: string, method: string, rawUrl: string, headers: HeaderMap,
    stream: webview.WebHttpBodyStream | null, resourceHandler: webview.WebResourceHandler): Promise<void> {
    let headersSent = false;
    try {
      let response: HttpResponse;
      const origin = (headers['origin'] ?? '').toLowerCase();
      if (origin.length > 0 && origin !== LOCAL_BACKEND_ORIGIN && origin !== LOCALHOST_ORIGIN) {
        // Content from another origin embedded in the WebView must not drive the backend.
        response = HttpResponse.json(jsonMessage('forbidden', 'cross-origin request'), 403);
      } else {
        const body = await this.readBody(stream);
        response = await this.router.dispatch(method, rawUrl, headers, body);
      }

      const streamHandler = response.streamHandler;
      const bodyBytes = streamHandler !== null ? new Uint8Array() :
        (response.bodyBytes ?? (response.body.length > 0 ? this.encoder.encodeInto(response.body) : new Uint8Array()));
      if (streamHandler === null) {
        response.headers['content-length'] = `${bodyBytes.byteLength}`;
      }
      resourceHandler.didReceiveResponse(this.responseHead(url, response));
      headersSent = true;

      if (streamHandler !== null) {
        // A send after the page aborted the request throws, which stops the producer like a closed socket did.
        await streamHandler(async (chunk: string | Uint8Array): Promise<void> => {
          const bytes = typeof chunk === 'string' ? this.encoder.encodeInto(chunk) : chunk;
          if (bytes.byteLength > 0) {
            resourceHandler.didReceiveResponseBody(this.toArrayBuffer(bytes));
          }
        });
      } else if (bodyBytes.byteLength > 0) {
        resourceHandler.didReceiveResponseBody(this.toArrayBuffer(bodyBytes));
      }
      resourceHandler.didFinish();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Request %{public}s %{public}s failed: %{public}s', method, rawUrl, JSON.stringify(err));
      try {
        if (!headersSent) {
          resourceHandler.didReceiveResponse(this.responseHead(url, HttpResponse.json(jsonMessage('internal_error'), 500)));
        }
        resourceHandler.didFail(WebNetErrorList.ERR_FAILED);
      } catch (_err) {
      }
    }
  }

  private async readBody(stream: webview.WebHttpBodyStream | null): Promise<Uint8Array> {
    if (stream === null) {
      return new Uint8Array();
    }
    await stream.initialize();
    const chunked = stream.isChunked();
    const size = chunked ? 0 : stream.getSize();
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (!stream.isEof() && (chunked || total < size)) {
      const wanted = chunked ? BODY_READ_CHUNK_BYTES : Math.min(BODY_READ_CHUNK_BYTES, size - total);
      const chunk = new Uint8Array(await stream.read(wanted));
      if (chunk.byteLength === 0) {
        break;
      }
      chunks.push(chunk);
      total += chunk.byteLength;
    }
    if (chunks.length === 1) {
      return chunks[0];
    }
    const output = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      output.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return output;
  }

  private responseHead(url: string, response: HttpResponse): webview.WebSchemeHandlerResponse {
    const head = new webview.WebSchemeHandlerResponse();
    head.setUrl(url);
    head.setNetErrorCode(WebNetErrorList.NET_OK);
    head.setStatus(response.statusCode);
    head.setStatusText(response.statusText);
    const contentType = response.headers['content-type'] ?? '';
    const mimeType = contentType.split(';')[0].trim();
    if (mimeType.length > 0) {
      head.setMimeType(mimeType);
    }
    const charsetMatch = contentType.match(/charset=([^;]+)/i);
    if (charsetMatch !== null) {
      head.setEncoding(charsetMatch[1].trim());
    }
    Object.keys(response.headers).forEach((name: string) => {
      head.setHeaderByName(name, response.headers[name], true);
    });
    return head;
  }

  private toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    return buffer;
  }
}
