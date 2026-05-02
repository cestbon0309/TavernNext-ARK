import { resourceManager } from '@kit.LocalizationKit';
import { DataDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';

type JsonValue = Object | string | number | boolean | null | JsonArray;

export class ExtensionsService {
  private static readonly rawSystemRoot: string = 'public/scripts/extensions';
  private store: FileStore;
  private dirs: DataDirectories;
  private manager: resourceManager.ResourceManager;

  constructor(store: FileStore, dirs: DataDirectories, manager: resourceManager.ResourceManager) {
    this.store = store;
    this.dirs = dirs;
    this.manager = manager;
  }

  discover(): HttpResponse {
    this.store.ensureDir(this.dirs.defaultUser.extensions);
    this.store.ensureDir(this.dirs.globalExtensionsRoot);
    const extensions: JsonRecord[] = [];

    for (const name of this.rawDirectoryNames(ExtensionsService.rawSystemRoot)) {
      if (name === 'third-party') {
        continue;
      }
      const row = emptyJsonRecord();
      row['type'] = 'system';
      row['name'] = name;
      extensions.push(row);
    }

    const localNames = this.localExtensionNames(this.dirs.defaultUser.extensions);
    for (const name of localNames) {
      const row = emptyJsonRecord();
      row['type'] = 'local';
      row['name'] = `third-party/${name}`;
      extensions.push(row);
    }

    const rawGlobalNames = this.rawDirectoryNames(`${ExtensionsService.rawSystemRoot}/third-party`);
    const privateGlobalNames = this.localExtensionNames(this.dirs.globalExtensionsRoot);
    const globalNames = [...rawGlobalNames, ...privateGlobalNames];
    const seen = new Set<string>();
    for (const name of globalNames) {
      if (seen.has(name) || localNames.includes(name)) {
        continue;
      }
      seen.add(name);
      const row = emptyJsonRecord();
      row['type'] = 'global';
      row['name'] = `third-party/${name}`;
      extensions.push(row);
    }

    return HttpResponse.json(extensions);
  }

  install(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    if (this.asString(body['url']).length === 0) {
      return HttpResponse.text('Bad Request: URL is required in the request body.', 400);
    }
    return HttpResponse.json(this.gitUnavailable('install', 'Git clone is not available inside the OHOS ArkTS runtime.'), 501);
  }

  update(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    const response = emptyJsonRecord();
    response['shortCommitHash'] = '';
    response['extensionPath'] = path;
    response['isUpToDate'] = true;
    response['remoteUrl'] = '';
    response['message'] = 'Local OHOS extension directory is treated as up-to-date; Git pull is unavailable.';
    return HttpResponse.json(response);
  }

  branches(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    return HttpResponse.json([]);
  }

  switchBranch(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    const branch = this.asString(body['branch']);
    if (extensionName.length === 0 || branch.length === 0) {
      return HttpResponse.text('Bad Request: extensionName and branch are required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    return HttpResponse.json(this.gitUnavailable('switch', 'Git checkout is not available inside the OHOS ArkTS runtime.'), 501);
  }

  move(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    const source = this.asString(body['source']);
    const destination = this.asString(body['destination']);
    if (extensionName.length === 0 || source.length === 0 || destination.length === 0) {
      return HttpResponse.text('Bad Request. Not all required parameters are provided.', 400);
    }
    if (source === destination) {
      return HttpResponse.text('Source and destination directories are the same.', 409);
    }

    const sourcePath = this.extensionPath(extensionName, source === 'global');
    const destinationPath = this.extensionPath(extensionName, destination === 'global');
    if (!this.store.exists(sourcePath)) {
      return HttpResponse.text('Source directory does not exist.', 404);
    }
    if (this.store.exists(destinationPath)) {
      return HttpResponse.text('Destination directory already exists.', 409);
    }
    if (!this.store.moveDirectory(sourcePath, destinationPath)) {
      return HttpResponse.text('Internal Server Error. Check the server logs for more details.', 500);
    }
    return HttpResponse.empty(204);
  }

  version(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    const response = emptyJsonRecord();
    response['currentBranchName'] = '';
    response['currentCommitHash'] = '';
    response['isUpToDate'] = true;
    response['remoteUrl'] = '';
    return HttpResponse.json(response);
  }

  delete(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const global = body['global'] === true;
    const path = this.extensionPath(extensionName, global);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    if (!this.store.deleteDirectory(path)) {
      return HttpResponse.text('Internal Server Error. Check the server logs for more details.', 500);
    }
    return HttpResponse.text(`Extension has been deleted at ${path}`);
  }

  serveThirdPartyFile(request: HttpRequest): HttpResponse {
    const prefix = '/scripts/extensions/third-party/';
    if (!request.path.startsWith(prefix)) {
      return HttpResponse.empty(404);
    }
    const relative = this.safeRelativePath(request.path.slice(prefix.length));
    if (relative.length === 0) {
      return HttpResponse.empty(404);
    }

    const localPath = joinPath(this.dirs.defaultUser.extensions, relative);
    const localBytes = this.store.readBytes(localPath);
    if (localBytes !== null) {
      return HttpResponse.bytes(localBytes, 200, this.contentTypeForFile(localPath));
    }

    const globalPath = joinPath(this.dirs.globalExtensionsRoot, relative);
    const globalBytes = this.store.readBytes(globalPath);
    if (globalBytes !== null) {
      return HttpResponse.bytes(globalBytes, 200, this.contentTypeForFile(globalPath));
    }

    try {
      const raw = `${ExtensionsService.rawSystemRoot}/third-party/${relative}`;
      return HttpResponse.bytes(this.manager.getRawFileContentSync(raw), 200, this.contentTypeForFile(raw));
    } catch (_err) {
      return HttpResponse.empty(404);
    }
  }

  private rawDirectoryNames(path: string): string[] {
    try {
      const names = this.manager.getRawFileListSync(path);
      const result: string[] = [];
      for (const name of names) {
        if (name.includes('.') || name.length === 0) {
          continue;
        }
        try {
          this.manager.getRawFileListSync(`${path}/${name}`);
          result.push(name);
        } catch (_err) {
        }
      }
      return result.sort();
    } catch (_err) {
      return [];
    }
  }

  private localExtensionNames(path: string): string[] {
    const names: string[] = [];
    for (const entry of this.store.list(path)) {
      if (entry.isDirectory) {
        names.push(entry.name);
      }
    }
    return names.sort();
  }

  private extensionPath(extensionName: string, global: boolean): string {
    const name = this.cleanExtensionName(extensionName);
    return joinPath(global ? this.dirs.globalExtensionsRoot : this.dirs.defaultUser.extensions, name);
  }

  private cleanExtensionName(name: string): string {
    let cleaned = name.replace(/\\/g, '/');
    if (cleaned.startsWith('third-party/')) {
      cleaned = cleaned.slice('third-party/'.length);
    }
    const parts = cleaned.split('/').filter((part: string): boolean => part.length > 0 && part !== '.' && part !== '..');
    if (parts.length === 0) {
      return '';
    }
    return sanitizeFileName(parts[parts.length - 1]);
  }

  private safeRelativePath(path: string): string {
    const decoded = decodeURIComponent(path).replace(/\\/g, '/');
    if (decoded.includes('\u0000')) {
      return '';
    }
    const parts = decoded.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length === 0 || parts.some((part: string): boolean => part === '.' || part === '..')) {
      return '';
    }
    return parts.map((part: string): string => sanitizeFileName(part)).join('/');
  }

  private gitUnavailable(operation: string, message: string): JsonRecord {
    const response = emptyJsonRecord();
    response['error'] = 'git_unavailable';
    response['operation'] = operation;
    response['message'] = message;
    return response;
  }

  private bodyAsRecord(request: HttpRequest): JsonRecord {
    if (request.body === null || Array.isArray(request.body)) {
      return emptyJsonRecord();
    }
    return request.body as JsonRecord;
  }

  private asString(value: JsonValue | JsonArray | undefined): string {
    if (value === undefined || value === null || Array.isArray(value)) {
      return '';
    }
    return `${value}`;
  }

  private contentTypeForFile(path: string): string {
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
    if (lower.endsWith('.json')) {
      return 'application/json; charset=utf-8';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (lower.endsWith('.wav')) {
      return 'audio/wav';
    }
    return 'application/octet-stream';
  }
}
