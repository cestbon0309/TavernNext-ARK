import { resourceManager } from '@kit.LocalizationKit';
import { HttpRequest, HttpResponse, jsonMessage } from './HttpTypes';

export class StaticFileServer {
  private manager: resourceManager.ResourceManager;

  constructor(manager: resourceManager.ResourceManager) {
    this.manager = manager;
  }

  serve(request: HttpRequest): HttpResponse {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return HttpResponse.json(jsonMessage('method_not_allowed'), 405);
    }

    const rawPath = this.rawFilePathForRequest(request.path);
    if (rawPath.length === 0) {
      return HttpResponse.json(jsonMessage('not_found'), 404);
    }

    try {
      const bytes = this.manager.getRawFileContentSync(rawPath);
      const response = HttpResponse.bytes(bytes, 200, this.contentType(rawPath));
      response.headers['cache-control'] = rawPath.endsWith('.html') ? 'no-cache' : 'public, max-age=3600';
      if (request.method === 'HEAD') {
        response.bodyBytes = new Uint8Array();
      }
      return response;
    } catch (_err) {
      return HttpResponse.json(jsonMessage('not_found'), 404);
    }
  }

  private rawFilePathForRequest(path: string): string {
    if (path === '/' || path === '') {
      return 'public/index.html';
    }

    const decoded = this.decodePath(path);
    if (decoded.length === 0 || decoded.includes('\u0000') || decoded.includes('..')) {
      return '';
    }

    const withoutSlash = decoded.startsWith('/') ? decoded.slice(1) : decoded;
    if (withoutSlash.length === 0) {
      return 'public/index.html';
    }
    return `public/${withoutSlash}`;
  }

  private decodePath(path: string): string {
    const question = path.indexOf('?');
    const hash = path.indexOf('#');
    let end = path.length;
    if (question >= 0) {
      end = Math.min(end, question);
    }
    if (hash >= 0) {
      end = Math.min(end, hash);
    }

    try {
      return decodeURIComponent(path.slice(0, end)).replace(/\\/g, '/');
    } catch (_err) {
      return '';
    }
  }

  private contentType(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.html')) {
      return 'text/html; charset=utf-8';
    }
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
      return 'text/javascript; charset=utf-8';
    }
    if (lower.endsWith('.css')) {
      return 'text/css; charset=utf-8';
    }
    if (lower.endsWith('.json') || lower.endsWith('.map') || lower.endsWith('.webmanifest')) {
      return 'application/json; charset=utf-8';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.ico')) {
      return 'image/x-icon';
    }
    if (lower.endsWith('.woff')) {
      return 'font/woff';
    }
    if (lower.endsWith('.woff2')) {
      return 'font/woff2';
    }
    if (lower.endsWith('.ttf')) {
      return 'font/ttf';
    }
    if (lower.endsWith('.otf')) {
      return 'font/otf';
    }
    if (lower.endsWith('.wasm')) {
      return 'application/wasm';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (lower.endsWith('.wav')) {
      return 'audio/wav';
    }
    if (lower.endsWith('.ogg')) {
      return 'audio/ogg';
    }
    if (lower.endsWith('.txt')) {
      return 'text/plain; charset=utf-8';
    }
    return 'application/octet-stream';
  }
}
