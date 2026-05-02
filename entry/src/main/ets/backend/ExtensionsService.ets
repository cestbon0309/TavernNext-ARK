import { resourceManager } from '@kit.LocalizationKit';
import { DataDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { GitBranchInfo, GitService, GitUpdateResult, GitVersionResult } from './GitService';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';

type JsonValue = Object | string | number | boolean | null | JsonArray;

export class ExtensionsService {
  private static readonly rawSystemRoot: string = 'public/scripts/extensions';
  private store: FileStore;
  private dirs: DataDirectories;
  private manager: resourceManager.ResourceManager;
  private git: GitService;

  constructor(store: FileStore, dirs: DataDirectories, manager: resourceManager.ResourceManager, git: GitService) {
    this.store = store;
    this.dirs = dirs;
    this.manager = manager;
    this.git = git;
  }

  discover(): HttpResponse {
    this.store.ensureDir(this.dirs.defaultUser.extensions);
    this.store.ensureDir(this.dirs.globalExtensionsRoot);
    const extensions: JsonRecord[] = [];
    const localRoots = this.localExtensionRoots();
    const globalRoots = this.globalExtensionRoots();

    for (const name of this.rawDirectoryNames(ExtensionsService.rawSystemRoot)) {
      if (name === 'third-party') {
        continue;
      }
      const row = emptyJsonRecord();
      row['type'] = 'system';
      row['name'] = name;
      extensions.push(row);
    }

    const localNames = this.localExtensionNames(localRoots);
    for (const name of localNames) {
      const row = emptyJsonRecord();
      row['type'] = 'local';
      row['name'] = `third-party/${name}`;
      extensions.push(row);
    }

    const rawGlobalNames = this.rawDirectoryNames(`${ExtensionsService.rawSystemRoot}/third-party`);
    const privateGlobalNames = this.localExtensionNames(globalRoots);
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

  async install(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const url = this.asString(body['url']).trim();
    if (url.length === 0) {
      return HttpResponse.text('Bad Request: URL is required in the request body.', 400);
    }
    const folderName = this.git.folderNameFromUrl(url);
    if (folderName.length === 0) {
      return HttpResponse.text('Bad Request: URL does not contain a valid extension folder name.', 400);
    }

    const global = body['global'] === true;
    const branch = this.asString(body['branch']).trim();
    const targetPath = this.extensionPath(folderName, global);
    if (this.store.exists(targetPath)) {
      return HttpResponse.text(`Directory already exists at ${targetPath}`, 409);
    }

    try {
      this.store.ensureDir(global ? this.dirs.globalExtensionsRoot : this.dirs.defaultUser.extensions);
      await this.git.clone(url, targetPath, { branch, depth: 1 });
      const manifest = this.git.readManifest(targetPath);
      const response = emptyJsonRecord();
      response['version'] = this.asString(manifest['version']) || '0.0.0';
      response['author'] = this.asString(manifest['author']) || 'Unknown';
      response['display_name'] = this.asString(manifest['display_name']) || folderName;
      response['extensionPath'] = targetPath;
      response['folderName'] = folderName;
      return HttpResponse.json(response);
    } catch (err) {
      if (this.store.exists(targetPath)) {
        this.store.deleteDirectory(targetPath);
      }
      return HttpResponse.text(`Server Error: ${this.errorMessage(err)}`, 500);
    }
  }

  async update(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    try {
      return HttpResponse.json(this.gitUpdateToJson(await this.git.update(path)));
    } catch (err) {
      return HttpResponse.text(`Internal Server Error. ${this.errorMessage(err)}`, 500);
    }
  }

  async branches(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    try {
      return HttpResponse.json((await this.git.branches(path)).map((branch: GitBranchInfo): JsonRecord => {
        const row = emptyJsonRecord();
        row['name'] = branch.name;
        row['commit'] = branch.commit;
        row['current'] = branch.current;
        row['label'] = branch.label;
        return row;
      }));
    } catch (err) {
      return HttpResponse.text(`Internal Server Error. ${this.errorMessage(err)}`, 500);
    }
  }

  async switchBranch(request: HttpRequest): Promise<HttpResponse> {
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
    try {
      await this.git.switchBranch(path, branch);
      return HttpResponse.empty(204);
    } catch (err) {
      return HttpResponse.text(`Internal Server Error. ${this.errorMessage(err)}`, 500);
    }
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

  async version(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const extensionName = this.cleanExtensionName(this.asString(body['extensionName']));
    if (extensionName.length === 0) {
      return HttpResponse.text('Bad Request: extensionName is required in the request body.', 400);
    }
    const path = this.extensionPath(extensionName, body['global'] === true);
    if (!this.store.exists(path)) {
      return HttpResponse.text(`Directory does not exist at ${path}`, 404);
    }
    try {
      return HttpResponse.json(this.gitVersionToJson(await this.git.version(path)));
    } catch (_err) {
      const response = emptyJsonRecord();
      response['currentBranchName'] = '';
      response['currentCommitHash'] = '';
      response['isUpToDate'] = true;
      response['remoteUrl'] = '';
      return HttpResponse.json(response);
    }
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

    for (const root of this.localExtensionRoots()) {
      const localPath = joinPath(root, relative);
      const localBytes = this.store.readBytes(localPath);
      if (localBytes !== null) {
        return HttpResponse.bytes(localBytes, 200, this.contentTypeForFile(localPath));
      }
    }

    for (const root of this.globalExtensionRoots()) {
      const globalPath = joinPath(root, relative);
      const globalBytes = this.store.readBytes(globalPath);
      if (globalBytes !== null) {
        return HttpResponse.bytes(globalBytes, 200, this.contentTypeForFile(globalPath));
      }
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

  private localExtensionNames(paths: string[]): string[] {
    const names: string[] = [];
    const seen = new Set<string>();
    for (const path of paths) {
      for (const entry of this.store.list(path)) {
        if (entry.name === 'third-party' && !this.store.exists(joinPath(entry.path, 'manifest.json'))) {
          continue;
        }
        if (entry.isDirectory && !seen.has(entry.name)) {
          seen.add(entry.name);
          names.push(entry.name);
        }
      }
    }
    return names.sort();
  }

  private localExtensionRoots(): string[] {
    return [
      this.dirs.defaultUser.extensions,
      joinPath(this.dirs.defaultUser.extensions, 'third-party'),
      joinPath(this.dirs.defaultUser.root, 'public', 'scripts', 'extensions', 'third-party'),
      joinPath(this.dirs.defaultUser.root, 'scripts', 'extensions', 'third-party'),
      joinPath(this.dirs.dataRoot, 'extensions'),
      joinPath(this.dirs.dataRoot, 'extensions', 'third-party'),
      joinPath(this.dirs.dataRoot, 'public', 'scripts', 'extensions', 'third-party'),
      joinPath(this.dirs.dataRoot, 'scripts', 'extensions', 'third-party'),
    ].filter((path: string, index: number, paths: string[]): boolean => paths.indexOf(path) === index);
  }

  private globalExtensionRoots(): string[] {
    return [
      this.dirs.globalExtensionsRoot,
      joinPath(this.dirs.dataRoot, 'globalExtensions'),
      joinPath(this.dirs.dataRoot, 'public', 'scripts', 'extensions', 'third-party'),
    ].filter((path: string, index: number, paths: string[]): boolean => paths.indexOf(path) === index);
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

  private gitUpdateToJson(result: GitUpdateResult): JsonRecord {
    const response = emptyJsonRecord();
    response['shortCommitHash'] = result.shortCommitHash;
    response['currentCommitHash'] = result.currentCommitHash;
    response['currentBranchName'] = result.currentBranchName;
    response['extensionPath'] = result.extensionPath;
    response['isUpToDate'] = result.isUpToDate;
    response['remoteUrl'] = result.remoteUrl;
    return response;
  }

  private gitVersionToJson(result: GitVersionResult): JsonRecord {
    const response = emptyJsonRecord();
    response['currentBranchName'] = result.currentBranchName;
    response['currentCommitHash'] = result.currentCommitHash;
    response['isUpToDate'] = result.isUpToDate;
    response['remoteUrl'] = result.remoteUrl;
    return response;
  }

  private errorMessage(err: Object | null | undefined): string {
    if (err === undefined || err === null) {
      return 'Unknown error';
    }
    if (typeof err === 'string') {
      return err;
    }
    return JSON.stringify(err);
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
