import { util } from '@kit.ArkTS';
import { fileUri } from '@kit.CoreFileKit';
import { HeaderMap, HttpResponse } from './HttpTypes';
import { RemoteHttpResult } from './RemoteHttpClient';

export type LocalDispatcher = (method: string, rawUrl: string, headers: HeaderMap, body: Uint8Array) => Promise<HttpResponse>;
export type LocalPathResolver = (avatar: string) => string;

// Lets native ArkTS code use backend routes and data files in-process instead of over HTTP.
export class LocalBackend {
  private static dispatcher: LocalDispatcher | null = null;
  private static avatarPath: LocalPathResolver | null = null;
  private static thumbnailPath: LocalPathResolver | null = null;
  private static encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private static decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  static configure(dispatcher: LocalDispatcher, avatarPath: LocalPathResolver, thumbnailPath: LocalPathResolver): void {
    LocalBackend.dispatcher = dispatcher;
    LocalBackend.avatarPath = avatarPath;
    LocalBackend.thumbnailPath = thumbnailPath;
  }

  static async postJson(path: string, value: Object): Promise<RemoteHttpResult> {
    return LocalBackend.post(path, LocalBackend.encoder.encodeInto(JSON.stringify(value)), 'application/json');
  }

  static async post(path: string, body: Uint8Array, contentType: string): Promise<RemoteHttpResult> {
    const result = new RemoteHttpResult();
    const dispatcher = LocalBackend.dispatcher;
    if (dispatcher === null) {
      return result;
    }
    const headers: HeaderMap = {};
    headers['content-type'] = contentType;
    const response = await dispatcher('POST', path, headers, body);
    result.statusCode = response.statusCode;
    result.headers = response.headers;
    result.text = response.bodyBytes !== null ? LocalBackend.decoder.decodeToString(response.bodyBytes) : response.body;
    return result;
  }

  static characterAvatarUri(avatar: string): string {
    return LocalBackend.fileUriFor(LocalBackend.avatarPath, avatar);
  }

  static characterThumbnailUri(avatar: string): string {
    return LocalBackend.fileUriFor(LocalBackend.thumbnailPath, avatar);
  }

  private static fileUriFor(resolver: LocalPathResolver | null, avatar: string): string {
    if (resolver === null || avatar.length === 0) {
      return '';
    }
    return fileUri.getUriFromPath(resolver(avatar));
  }
}
