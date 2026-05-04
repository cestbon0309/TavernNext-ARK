import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { HttpRequest, HttpResponse, jsonMessage } from './HttpTypes';

type ThemeColorProvider = () => string;

export class StaticFileServer {
  private manager: resourceManager.ResourceManager;
  private themeColorProvider: ThemeColorProvider | null;
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');

  constructor(manager: resourceManager.ResourceManager, themeColorProvider: ThemeColorProvider | null = null) {
    this.manager = manager;
    this.themeColorProvider = themeColorProvider;
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
      const response = rawPath === 'public/index.html' ?
        this.indexHtmlResponse(bytes) :
        HttpResponse.bytes(bytes, 200, this.contentType(rawPath));
      response.headers['cache-control'] = rawPath.endsWith('.html') ? 'no-cache' : 'public, max-age=3600';
      if (request.method === 'HEAD') {
        response.bodyBytes = new Uint8Array();
        response.body = '';
      }
      return response;
    } catch (_err) {
      return HttpResponse.json(jsonMessage('not_found'), 404);
    }
  }

  private indexHtmlResponse(bytes: Uint8Array): HttpResponse {
    const html = this.decoder.decodeToString(bytes);
    return HttpResponse.bytes(this.encoder.encodeInto(this.injectEarlyThemeColor(html)), 200, this.contentType('public/index.html'));
  }

  private injectEarlyThemeColor(html: string): string {
    const color = this.safeThemeColor();
    if (color.length === 0) {
      return html;
    }

    const marker = '</head>';
    const markerIndex = html.indexOf(marker);
    if (markerIndex < 0) {
      return html;
    }

    const style = `<style id="tavernnext-early-theme">:root{--SmartThemeBlurTintColor:${color};--SmartThemeChatTintColor:${color}}body,#preloader{background-color:${color}}</style>`;
    return `${html.slice(0, markerIndex)}${style}${html.slice(markerIndex)}`;
  }

  private safeThemeColor(): string {
    const color = this.themeColorProvider === null ? '' : this.themeColorProvider();
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? color : '';
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
