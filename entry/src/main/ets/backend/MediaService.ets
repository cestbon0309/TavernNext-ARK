import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { zlib } from '@kit.BasicServicesKit';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { emptyJsonRecord, HttpRequest, HttpResponse, HttpUploadedFile, JsonArray, JsonRecord, JsonScalar } from './HttpTypes';
import { extensionOf, joinPath, sanitizeFileName, withoutExtension } from './PathUtils';
import { CryptoUtils } from './CryptoUtils';
import { RemoteHttpClient, RemoteHttpResult } from './RemoteHttpClient';
import { PngCardStore } from './PngCardStore';

type JsonValue = JsonScalar | JsonArray;

class BackgroundImageResponse {
  filename: string;
  isAnimated: boolean;

  constructor(filename: string, isAnimated: boolean) {
    this.filename = filename;
    this.isAnimated = isAnimated;
  }
}

class BackgroundsResponse {
  images: BackgroundImageResponse[] = [];
  config: JsonRecord = emptyJsonRecord();
}

class BackgroundFoldersResponse {
  folders: JsonArray = [];
  imageFolderMap: JsonRecord = emptyJsonRecord();
}

class SpriteEntry {
  label: string;
  path: string;

  constructor(label: string, path: string) {
    this.label = label;
    this.path = path;
  }
}

class CropParams {
  x: number = 0;
  y: number = 0;
  width: number = 0;
  height: number = 0;
  want_resize: boolean = false;
}

class RemoteContentResult {
  bytes: Uint8Array = new Uint8Array();
  fileName: string = '';
  contentType: string = 'application/octet-stream';
  contentKind: string = 'character';
}

class PerchanceContent {
  slug: string = '';
  charUrl: string = '';
  record: JsonRecord = emptyJsonRecord();
}

export class MediaService {
  private static readonly bgThumbWidth: number = 160;
  private static readonly bgThumbHeight: number = 90;
  private static readonly avatarThumbWidth: number = 96;
  private static readonly avatarThumbHeight: number = 144;
  private static readonly avatarWidth: number = 512;
  private static readonly avatarHeight: number = 768;
  private static readonly mediaRequestImage: number = 0b001;
  private static readonly mediaRequestVideo: number = 0b010;
  private static readonly mediaRequestAudio: number = 0b100;
  private static readonly imageExtensions: string[] = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.jfif', '.tif', '.tiff', '.apng'];
  private static readonly mediaExtensions: string[] = [
    'bmp', 'png', 'jpg', 'webp', 'jpeg', 'jfif', 'gif', 'mp4', 'avi', 'mov', 'wmv', 'flv', 'webm', '3gp',
    'mkv', 'mpg', 'mp3', 'wav', 'ogg', 'flac', 'aac', 'm4a', 'aiff',
  ];
  private static readonly unsafeExtensions: string[] = [
    '.php', '.exe', '.com', '.dll', '.pif', '.application', '.gadget', '.msi', '.jar', '.cmd', '.bat', '.reg',
    '.sh', '.py', '.js', '.jse', '.jsp', '.pdf', '.html', '.htm',
  ];
  private static readonly skippedThumbnailExtensions: string[] = ['.apng', '.mp4', '.webm', '.avi', '.mkv', '.flv', '.gif'];

  private store: FileStore;
  private dirs: DataDirectories;
  private userDirs: UserDirectories;
  private crypto: CryptoUtils;
  private http: RemoteHttpClient = new RemoteHttpClient();
  private cardStore: PngCardStore;
  private base64: util.Base64Helper = new util.Base64Helper();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  constructor(store: FileStore, dirs: DataDirectories, crypto: CryptoUtils) {
    this.store = store;
    this.dirs = dirs;
    this.userDirs = dirs.defaultUser;
    this.crypto = crypto;
    this.cardStore = new PngCardStore(store);
  }

  async getDataFile(request: HttpRequest): Promise<HttpResponse> {
    if (request.path === '/thumbnail') {
      return await this.getThumbnail(request);
    }

    const path = this.dataFilePath(request.path);
    if (path.length === 0) {
      return HttpResponse.empty(404);
    }

    const bytes = this.store.readBytes(path);
    if (bytes === null) {
      return HttpResponse.empty(404);
    }
    return HttpResponse.bytes(bytes, 200, this.contentTypeForFile(path));
  }

  async listBackgrounds(): Promise<HttpResponse> {
    const result = new BackgroundsResponse();
    result.config['width'] = MediaService.bgThumbWidth;
    result.config['height'] = MediaService.bgThumbHeight;

    const relativePaths: string[] = [];
    const files = this.imageFiles(this.userDirs.backgrounds, 'name', MediaService.mediaRequestImage);
    for (const file of files) {
      relativePaths.push(`backgrounds/${file}`);
    }

    const metadata = await this.getOrGenerateMetadataBatch(relativePaths, 'bg');
    for (const file of files) {
      const meta = this.asRecord(metadata[`backgrounds/${file}`]);
      result.images.push(new BackgroundImageResponse(file, meta['isAnimated'] === true));
    }
    return HttpResponse.json(result);
  }

  listBackgroundFolders(): HttpResponse {
    const index = this.readMetadataIndex();
    const response = new BackgroundFoldersResponse();
    response.folders = this.asArray(index['folders']);
    const imageFolderMap = emptyJsonRecord();
    const images = this.asRecord(index['images']);
    Object.keys(images).forEach((relativePath: string) => {
      const meta = this.asRecord(images[relativePath]);
      const folderIds = this.asArray(meta['folderIds']);
      if (folderIds.length === 0) {
        return;
      }
      const filename = this.baseName(relativePath);
      imageFolderMap[filename] = folderIds;
    });
    response.imageFolderMap = imageFolderMap;
    return HttpResponse.json(response);
  }

  deleteBackground(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const rawName = this.asString(body['bg']);
    if (rawName.length === 0) {
      return HttpResponse.empty(400);
    }
    const safeName = sanitizeFileName(rawName);
    if (safeName !== rawName) {
      return HttpResponse.empty(403);
    }
    const path = joinPath(this.userDirs.backgrounds, safeName);
    if (!this.store.exists(path)) {
      return HttpResponse.empty(400);
    }
    this.store.deleteFile(path);
    this.invalidateThumbnail('bg', safeName);
    this.removeMetadata(`backgrounds/${safeName}`);
    return HttpResponse.text('ok');
  }

  async renameBackground(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const oldName = sanitizeFileName(this.asString(body['old_bg']));
    const newName = sanitizeFileName(this.asString(body['new_bg']));
    if (oldName.length === 0 || newName.length === 0 || oldName === 'unnamed' || newName === 'unnamed') {
      return HttpResponse.empty(400);
    }

    const oldPath = joinPath(this.userDirs.backgrounds, oldName);
    const newPath = joinPath(this.userDirs.backgrounds, newName);
    if (!this.store.exists(oldPath) || this.store.exists(newPath)) {
      return HttpResponse.empty(400);
    }
    if (!this.store.copyFile(oldPath, newPath)) {
      return HttpResponse.empty(500);
    }
    this.store.deleteFile(oldPath);
    this.invalidateThumbnail('bg', oldName);
    this.renameMetadata(`backgrounds/${oldName}`, `backgrounds/${newName}`);
    await this.getOrGenerateMetadataBatch([`backgrounds/${newName}`], 'bg');
    return HttpResponse.text('ok');
  }

  async uploadBackground(request: HttpRequest): Promise<HttpResponse> {
    const file = request.file('avatar') ?? (request.files.length > 0 ? request.files[0] : null);
    if (file === null) {
      return HttpResponse.empty(400);
    }
    const filename = sanitizeFileName(file.fileName);
    if (filename.length === 0 || filename === 'unnamed') {
      return HttpResponse.empty(400);
    }
    this.store.writeBytes(joinPath(this.userDirs.backgrounds, filename), file.bytes);
    this.invalidateThumbnail('bg', filename);
    await this.getOrGenerateMetadataBatch([`backgrounds/${filename}`], 'bg');
    return HttpResponse.text(filename);
  }

  listAvatars(): HttpResponse {
    return HttpResponse.json(this.imageFiles(this.userDirs.avatars, 'name', MediaService.mediaRequestImage));
  }

  deleteAvatar(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const rawName = this.asString(body['avatar']);
    if (rawName.length === 0) {
      return HttpResponse.empty(400);
    }
    const safeName = sanitizeFileName(rawName);
    if (safeName !== rawName) {
      return HttpResponse.empty(403);
    }
    const path = joinPath(this.userDirs.avatars, safeName);
    if (!this.store.exists(path)) {
      return HttpResponse.empty(404);
    }
    this.store.deleteFile(path);
    this.invalidateThumbnail('persona', safeName);
    const response = emptyJsonRecord();
    response['result'] = 'ok';
    return HttpResponse.json(response);
  }

  async uploadAvatar(request: HttpRequest): Promise<HttpResponse> {
    const file = request.file('avatar') ?? (request.files.length > 0 ? request.files[0] : null);
    if (file === null) {
      return HttpResponse.empty(400);
    }

    try {
      const crop = this.parseCrop(request.query['crop']);
      const output = await this.processAvatarUpload(file.bytes, crop);
      const overwrite = this.asString(this.bodyAsRecord(request)['overwrite_name']);
      const filename = sanitizeFileName(overwrite.length > 0 ? overwrite : `${Date.now()}.png`);
      if (overwrite.length > 0) {
        this.invalidateThumbnail('persona', filename);
      }
      this.store.writeBytes(joinPath(this.userDirs.avatars, filename), output);
      const response = emptyJsonRecord();
      response['path'] = filename;
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.text('Is not a valid image', 400);
    }
  }

  async uploadImage(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const base64Text = this.asString(body['image']);
    const format = this.asString(body['format']).toLowerCase();
    if (base64Text.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = 'No image data provided';
      return HttpResponse.json(response, 400);
    }
    if (!MediaService.mediaExtensions.includes(format)) {
      const response = emptyJsonRecord();
      response['error'] = 'Invalid image format';
      return HttpResponse.json(response, 400);
    }

    const filename = this.asString(body['filename']).length > 0 ?
      `${withoutExtension(sanitizeFileName(this.asString(body['filename'])))}.${format}` : `${Date.now()}.${format}`;
    const characterName = sanitizeFileName(this.asString(body['ch_name']));
    const target = characterName.length > 0 && characterName !== 'unnamed' ?
      joinPath(this.userDirs.userImages, characterName, sanitizeFileName(filename)) :
      joinPath(this.userDirs.userImages, sanitizeFileName(filename));

    try {
      this.store.writeBytes(target, this.base64.decodeSync(this.stripDataUrl(base64Text), util.Type.BASIC));
      const response = emptyJsonRecord();
      response['path'] = this.clientRelativePath(this.userDirs.root, target);
      return HttpResponse.json(response);
    } catch (_err) {
      const response = emptyJsonRecord();
      response['error'] = 'Failed to save the image';
      return HttpResponse.json(response, 500);
    }
  }

  listImages(request: HttpRequest): HttpResponse {
    let folderFromPath = '';
    if (request.path.startsWith('/api/images/list/')) {
      folderFromPath = request.path.slice('/api/images/list/'.length);
    } else if (request.path.startsWith('/listimgfiles/')) {
      folderFromPath = request.path.slice('/listimgfiles/'.length);
    }
    const body = this.bodyAsRecord(request);
    if (folderFromPath.length > 0 && this.asString(body['folder']).length > 0) {
      const response = emptyJsonRecord();
      response['error'] = 'Folder specified in both URL and body';
      return HttpResponse.json(response, 400);
    }
    const folder = sanitizeFileName(folderFromPath.length > 0 ? folderFromPath : this.asString(body['folder']));
    if (folder.length === 0 || folder === 'unnamed') {
      const response = emptyJsonRecord();
      response['error'] = 'No folder specified';
      return HttpResponse.json(response, 400);
    }
    const directory = joinPath(this.userDirs.userImages, folder);
    this.store.ensureDir(directory);
    const type = Number(body['type'] ?? MediaService.mediaRequestImage);
    const sort = this.asString(body['sortField']) || 'date';
    const order = this.asString(body['sortOrder']) || 'asc';
    const images = this.imageFiles(directory, sort, type);
    if (order === 'desc') {
      images.reverse();
    }
    return HttpResponse.json(images);
  }

  imageFolders(): HttpResponse {
    const folders: string[] = [];
    this.store.ensureDir(this.userDirs.userImages);
    for (const entry of this.store.list(this.userDirs.userImages)) {
      if (entry.isDirectory) {
        folders.push(entry.name);
      }
    }
    return HttpResponse.json(folders);
  }

  deleteImage(request: HttpRequest): HttpResponse {
    return this.deleteClientRelativeFile(request, this.userDirs.userImages, 'No path specified');
  }

  sanitizeUploadedFileName(request: HttpRequest): HttpResponse {
    const fileName = this.asString(this.bodyAsRecord(request)['fileName']);
    if (fileName.length === 0) {
      return HttpResponse.text('No fileName specified', 400);
    }
    const response = emptyJsonRecord();
    response['fileName'] = sanitizeFileName(fileName);
    return HttpResponse.json(response);
  }

  uploadFile(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const name = this.asString(body['name']);
    const data = this.asString(body['data']);
    if (name.length === 0) {
      return HttpResponse.text('No upload name specified', 400);
    }
    if (data.length === 0) {
      return HttpResponse.text('No upload data specified', 400);
    }
    const validationError = this.validateAssetFileName(name);
    if (validationError.length > 0) {
      return HttpResponse.text(validationError, 400);
    }

    try {
      const path = joinPath(this.userDirs.files, name);
      this.store.writeBytes(path, this.base64.decodeSync(this.stripDataUrl(data), util.Type.BASIC));
      const response = emptyJsonRecord();
      response['path'] = this.clientRelativePath(this.userDirs.root, path);
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  deleteFile(request: HttpRequest): HttpResponse {
    return this.deleteClientRelativeFile(request, this.userDirs.files, 'No path specified');
  }

  verifyFiles(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    if (!Array.isArray(body['urls'])) {
      return HttpResponse.text('No URLs specified', 400);
    }
    const urls = this.asArray(body['urls']);
    const verified = emptyJsonRecord();
    for (const item of urls) {
      const url = this.asString(item);
      const path = joinPath(this.userDirs.root, url);
      if (!this.isPathUnderParent(this.userDirs.files, path)) {
        continue;
      }
      verified[url] = this.store.exists(path);
    }
    return HttpResponse.json(verified);
  }

  assetsGet(): HttpResponse {
    this.ensureAssetFolders();
    const response = emptyJsonRecord();
    response['bgm'] = this.assetFileList('bgm');
    response['ambient'] = this.assetFileList('ambient');
    response['blip'] = this.assetFileList('blip');
    response['live2d'] = this.live2dAssets(joinPath(this.userDirs.assets, 'live2d'), 'assets/live2d');
    response['character'] = this.assetFileList('character');
    const vrm = emptyJsonRecord();
    vrm['model'] = this.recursiveClientFiles(joinPath(this.userDirs.assets, 'vrm', 'model'));
    vrm['animation'] = this.recursiveClientFiles(joinPath(this.userDirs.assets, 'vrm', 'animation'));
    response['vrm'] = vrm;
    return HttpResponse.json(response);
  }

  async assetsDownload(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const url = this.asString(body['url']);
    const category = this.asString(body['category']);
    const filename = this.asString(body['filename']);
    if (!this.isValidHttpUrl(url) || !this.isHostWhitelisted(this.hostFromUrl(url)) || !this.validAssetCategory(category)) {
      return HttpResponse.empty(!this.isHostWhitelisted(this.hostFromUrl(url)) ? 404 : 400);
    }
    const validation = this.validateAssetFileName(filename);
    if (validation.length > 0) {
      return HttpResponse.text(validation, 400);
    }
    try {
      this.ensureAssetFolders();
      const result = await this.http.getBytes(url, { 'User-Agent': 'SillyTavern' }, 120000);
      if (result.statusCode < 200 || result.statusCode >= 300 || result.bytes === null) {
        return HttpResponse.empty(500);
      }
      if (category === 'character') {
        return HttpResponse.bytes(result.bytes, 200, result.headers['content-type'] ?? this.contentTypeForFile(filename));
      }
      this.store.writeBytes(joinPath(this.userDirs.assets, category, filename), result.bytes);
      return HttpResponse.empty(200);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  assetsDelete(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const category = this.asString(body['category']);
    const filename = this.asString(body['filename']);
    if (!this.validAssetCategory(category)) {
      return HttpResponse.empty(400);
    }
    const validation = this.validateAssetFileName(filename);
    if (validation.length > 0) {
      return HttpResponse.text(validation, 400);
    }
    const path = joinPath(this.userDirs.assets, category, filename);
    if (!this.store.exists(path)) {
      return HttpResponse.empty(400);
    }
    this.store.deleteFile(path);
    return HttpResponse.empty(200);
  }

  assetsCharacter(request: HttpRequest): HttpResponse {
    const name = sanitizeFileName(this.asString(request.query['name']));
    const category = this.asString(request.query['category']);
    if (name.length === 0 || !this.validAssetCategory(category)) {
      return HttpResponse.empty(400);
    }
    const directory = joinPath(this.userDirs.characters, name, category);
    if (category === 'live2d') {
      return HttpResponse.json(this.live2dAssets(directory, `characters/${name}/${category}`));
    }
    const files: string[] = [];
    for (const entry of this.store.list(directory)) {
      if (entry.isFile && entry.name !== '.placeholder') {
        files.push(`/characters/${name}/${category}/${entry.name}`);
      }
    }
    return HttpResponse.json(files);
  }

  async contentImportUrl(request: HttpRequest): Promise<HttpResponse> {
    const url = this.asString(this.bodyAsRecord(request)['url']);
    if (url.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.downloadContentFromUrl(url);
      if (result === null) {
        return HttpResponse.empty(404);
      }
      return this.contentDownloadResponse(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  async contentImportUuid(request: HttpRequest): Promise<HttpResponse> {
    const uuid = this.asString(this.bodyAsRecord(request)['url']);
    if (uuid.length === 0) {
      return HttpResponse.empty(400);
    }
    try {
      const result = await this.downloadContentFromUuid(uuid);
      if (result === null) {
        return HttpResponse.empty(404);
      }
      return this.contentDownloadResponse(result);
    } catch (_err) {
      return HttpResponse.empty(500);
    }
  }

  spritesGet(request: HttpRequest): HttpResponse {
    const name = this.asString(request.query['name']);
    const spritesPath = this.spritesPath(name);
    const sprites: SpriteEntry[] = [];
    if (spritesPath.length === 0) {
      return HttpResponse.json(sprites);
    }
    const entries = this.imageFiles(spritesPath, 'name', MediaService.mediaRequestImage);
    for (const file of entries) {
      const stat = this.store.stat(joinPath(spritesPath, file), file);
      const stamp = stat === null ? '' : this.spriteTimestamp(stat.mtimeMs);
      const fileBase = withoutExtension(file).toLowerCase();
      const label = this.spriteLabel(fileBase);
      const suffix = stamp.length > 0 ? `?t=${stamp}` : '';
      sprites.push(new SpriteEntry(label, `/characters/${name}/${file}${suffix}`));
    }
    return HttpResponse.json(sprites);
  }

  spritesDelete(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const name = this.asString(body['name']);
    const label = this.asString(body['label']);
    const spriteName = this.asString(body['spriteName']) || label;
    if (name.length === 0 || spriteName.length === 0) {
      return HttpResponse.empty(400);
    }
    const spritesPath = this.spritesPath(name);
    if (spritesPath.length === 0 || !this.store.exists(spritesPath)) {
      return HttpResponse.empty(404);
    }
    for (const entry of this.store.list(spritesPath)) {
      if (entry.isFile && withoutExtension(entry.name) === spriteName) {
        this.store.deleteFile(entry.path);
      }
    }
    return HttpResponse.empty(200);
  }

  spritesUpload(request: HttpRequest): HttpResponse {
    const file = request.file('avatar') ?? (request.files.length > 0 ? request.files[0] : null);
    const body = this.bodyAsRecord(request);
    const label = this.asString(body['label']);
    const name = this.asString(body['name']);
    const spriteName = this.asString(body['spriteName']) || label;
    if (file === null || label.length === 0 || name.length === 0) {
      return HttpResponse.empty(400);
    }
    const spritesPath = this.spritesPath(name);
    if (spritesPath.length === 0) {
      return HttpResponse.empty(400);
    }
    this.store.ensureDir(spritesPath);
    for (const entry of this.store.list(spritesPath)) {
      if (entry.isFile && withoutExtension(entry.name) === spriteName) {
        this.store.deleteFile(entry.path);
      }
    }
    const filename = sanitizeFileName(`${spriteName}${extensionOf(file.fileName)}`);
    this.store.writeBytes(joinPath(spritesPath, filename), file.bytes);
    const response = emptyJsonRecord();
    response['ok'] = true;
    return HttpResponse.json(response);
  }

  async spritesUploadZip(request: HttpRequest): Promise<HttpResponse> {
    const file = request.file('avatar') ?? (request.files.length > 0 ? request.files[0] : null);
    const name = this.asString(this.bodyAsRecord(request)['name']);
    if (file === null || name.length === 0) {
      return HttpResponse.empty(400);
    }
    const spritesPath = this.spritesPath(name);
    if (spritesPath.length === 0) {
      return HttpResponse.empty(400);
    }

    const uploadId = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const tempRoot = joinPath(this.dirs.uploadRoot, `sprites-${uploadId}`);
    const zipPath = joinPath(tempRoot, 'sprites.zip');
    const unpackPath = joinPath(tempRoot, 'unpacked');
    this.store.ensureDir(tempRoot);
    this.store.ensureDir(unpackPath);
    this.store.writeBytes(zipPath, file.bytes);
    try {
      await zlib.decompressFile(zipPath, unpackPath, {
        parallel: zlib.ParallelStrategy.PARALLEL_STRATEGY_SEQUENTIAL,
        pathSeparatorStrategy: zlib.PathSeparatorStrategy.PATH_SEPARATOR_STRATEGY_REPLACE_BACKSLASH,
      });
      this.store.ensureDir(spritesPath);
      const images = this.collectImageFiles(unpackPath);
      for (const imageFile of images) {
        const existing = this.findByBaseName(spritesPath, withoutExtension(imageFile.name));
        if (existing.length > 0) {
          this.store.deleteFile(existing);
        }
        this.store.writeBytes(joinPath(spritesPath, sanitizeFileName(imageFile.name)), this.store.readBytes(imageFile.path) ?? new Uint8Array());
      }
      const response = emptyJsonRecord();
      response['ok'] = true;
      response['count'] = images.length;
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.empty(500);
    } finally {
      this.store.deleteDirectory(tempRoot);
    }
  }

  imageMetadataAll(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const prefix = this.asString(body['prefix']);
    const index = this.readMetadataIndex();
    if (prefix.length === 0) {
      return HttpResponse.json(index);
    }
    const filtered = emptyJsonRecord();
    const images = this.asRecord(index['images']);
    Object.keys(images).forEach((key: string) => {
      if (key.startsWith(prefix)) {
        filtered[key] = images[key];
      }
    });
    const response = emptyJsonRecord();
    response['version'] = Number(index['version'] ?? 1);
    response['images'] = filtered;
    return HttpResponse.json(response);
  }

  async imageMetadata(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const singlePath = this.asString(body['path']);
    const type = this.asString(body['type']) || 'bg';
    const paths = this.asArray(body['paths']).map((item: JsonValue): string => this.asString(item));
    if (singlePath.length === 0 && paths.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = 'Either "path" or "paths" is required.';
      return HttpResponse.json(response, 400);
    }
    if (singlePath.length > 0 && paths.length === 0) {
      if (!this.validRelativePath(singlePath) || !this.store.exists(joinPath(this.userDirs.root, singlePath))) {
        const response = emptyJsonRecord();
        response['error'] = 'File not found.';
        return HttpResponse.json(response, 404);
      }
      const results = await this.getOrGenerateMetadataBatch([singlePath], type);
      const metadata = this.asRecord(results[singlePath]);
      if (Object.keys(metadata).length === 0) {
        const response = emptyJsonRecord();
        response['error'] = 'Could not generate metadata for file.';
        return HttpResponse.json(response, 404);
      }
      return HttpResponse.json(metadata);
    }

    const validPaths: string[] = [];
    const response = emptyJsonRecord();
    for (const path of paths) {
      if (this.validRelativePath(path)) {
        validPaths.push(path);
      } else {
        const err = emptyJsonRecord();
        err['error'] = `Path "${path}" is outside the user data directory.`;
        response[path] = err;
      }
    }
    const results = await this.getOrGenerateMetadataBatch(validPaths, type);
    for (const path of validPaths) {
      response[path] = results[path] ?? this.metadataError('File not found or could not process.');
    }
    return HttpResponse.json(response);
  }

  imageMetadataFoldersGet(): HttpResponse {
    return HttpResponse.json(this.asArray(this.readMetadataIndex()['folders']));
  }

  imageMetadataFoldersCreate(request: HttpRequest): HttpResponse {
    const name = this.asString(this.bodyAsRecord(request)['name']).trim();
    if (name.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = '"name" is required.';
      return HttpResponse.json(response, 400);
    }
    const index = this.readMetadataIndex();
    const folders = this.asArray(index['folders']);
    const folder = emptyJsonRecord();
    folder['id'] = this.crypto.uuid();
    folder['name'] = name;
    folder['thumbnailFile'] = '';
    folders.push(folder);
    index['folders'] = folders;
    this.writeMetadataIndex(index);
    return HttpResponse.json(folder);
  }

  imageMetadataFoldersUpdate(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const id = this.asString(body['id']);
    if (id.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = '"id" is required.';
      return HttpResponse.json(response, 400);
    }
    const index = this.readMetadataIndex();
    const folder = this.findFolder(index, id);
    if (folder === null) {
      return HttpResponse.json(this.metadataError(`Folder '${id}' not found.`), 404);
    }
    if (body['name'] !== undefined) {
      folder['name'] = this.asString(body['name']);
    }
    if (body['thumbnailFile'] !== undefined) {
      folder['thumbnailFile'] = this.asString(body['thumbnailFile']);
    }
    this.writeMetadataIndex(index);
    return HttpResponse.json(folder);
  }

  imageMetadataFoldersDelete(request: HttpRequest): HttpResponse {
    const id = this.asString(this.bodyAsRecord(request)['id']);
    if (id.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = '"id" is required.';
      return HttpResponse.json(response, 400);
    }
    const index = this.readMetadataIndex();
    const folders = this.asArray(index['folders']);
    const nextFolders = folders.filter((item: JsonValue): boolean => this.asString(this.asRecord(item)['id']) !== id);
    if (nextFolders.length === folders.length) {
      return HttpResponse.json(this.metadataError(`Folder '${id}' not found.`), 404);
    }
    index['folders'] = nextFolders;
    const images = this.asRecord(index['images']);
    Object.keys(images).forEach((key: string) => {
      const meta = this.asRecord(images[key]);
      meta['folderIds'] = this.asArray(meta['folderIds']).filter((item: JsonValue): boolean => this.asString(item) !== id);
    });
    this.writeMetadataIndex(index);
    const response = emptyJsonRecord();
    response['ok'] = true;
    return HttpResponse.json(response);
  }

  imageMetadataFoldersSetThumbnails(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    if (!Array.isArray(body['updates'])) {
      const response = emptyJsonRecord();
      response['error'] = '"updates" must be an array of {id, thumbnailFile}.';
      return HttpResponse.json(response, 400);
    }
    const updates = this.asArray(body['updates']);
    const index = this.readMetadataIndex();
    for (const item of updates) {
      const update = this.asRecord(item);
      const id = this.asString(update['id']);
      if (id.length === 0 || typeof update['thumbnailFile'] !== 'string') {
        const response = emptyJsonRecord();
        response['error'] = '"updates" must be an array of {id, thumbnailFile}.';
        return HttpResponse.json(response, 400);
      }
      const folder = this.findFolder(index, id);
      if (folder !== null) {
        folder['thumbnailFile'] = this.asString(update['thumbnailFile']);
      }
    }
    this.writeMetadataIndex(index);
    const response = emptyJsonRecord();
    response['ok'] = true;
    return HttpResponse.json(response);
  }

  imageMetadataFoldersAssign(request: HttpRequest): HttpResponse {
    return this.updateFolderAssignments(request, true);
  }

  imageMetadataFoldersUnassign(request: HttpRequest): HttpResponse {
    return this.updateFolderAssignments(request, false);
  }

  imageMetadataCleanup(): HttpResponse {
    const index = this.readMetadataIndex();
    const images = this.asRecord(index['images']);
    const nextImages = emptyJsonRecord();
    const removed: string[] = [];
    Object.keys(images).forEach((relativePath: string) => {
      if (!this.validRelativePath(relativePath) || !this.store.exists(joinPath(this.userDirs.root, relativePath))) {
        removed.push(relativePath);
      } else {
        nextImages[relativePath] = images[relativePath];
      }
    });
    if (removed.length > 0) {
      index['images'] = nextImages;
      this.writeMetadataIndex(index);
    }
    const response = emptyJsonRecord();
    response['removed'] = removed;
    response['count'] = removed.length;
    return HttpResponse.json(response);
  }

  private async getThumbnail(request: HttpRequest): Promise<HttpResponse> {
    const rawFile = this.asString(request.query['file']);
    const type = this.asString(request.query['type']);
    if (rawFile.length === 0 || !this.isThumbnailType(type)) {
      return HttpResponse.empty(400);
    }
    const file = sanitizeFileName(rawFile);
    if (file !== rawFile) {
      return HttpResponse.empty(403);
    }
    const original = this.thumbnailSourcePath(type, file);
    if (!this.store.exists(original)) {
      return HttpResponse.empty(404);
    }

    const ext = extensionOf(file);
    if (ext === '.gif' || (request.query['animated'] === 'true' && MediaService.skippedThumbnailExtensions.includes(ext))) {
      return this.serveFile(original);
    }

    const thumbnail = this.thumbnailPath(type, file);
    const originalStat = this.store.stat(original, file);
    const thumbStat = this.store.stat(thumbnail, file);
    if (thumbStat === null || (originalStat !== null && originalStat.mtimeMs > thumbStat.ctimeMs)) {
      const generated = await this.generateThumbnail(type, file);
      if (!generated) {
        return this.serveFile(original);
      }
    }
    return this.serveFile(thumbnail);
  }

  private async processAvatarUpload(bytes: Uint8Array, crop: CropParams | null): Promise<Uint8Array> {
    const pixelMap = await this.createPixelMap(bytes);
    try {
      if (crop !== null) {
        await pixelMap.crop({
          x: Math.max(0, Math.round(crop.x)),
          y: Math.max(0, Math.round(crop.y)),
          size: {
            width: Math.max(1, Math.round(crop.width)),
            height: Math.max(1, Math.round(crop.height)),
          },
        });
      }
      const info = await pixelMap.getImageInfo();
      const targetWidth = crop !== null && crop.want_resize ? MediaService.avatarWidth : Number(info.size.width);
      const targetHeight = crop !== null && crop.want_resize ? MediaService.avatarHeight : Number(info.size.height);
      await this.coverPixelMap(pixelMap, Number(info.size.width), Number(info.size.height), targetWidth, targetHeight);
      return await this.packPixelMap(pixelMap, 'image/png', 100);
    } finally {
      await this.releasePixelMap(pixelMap);
    }
  }

  private async generateThumbnail(type: string, file: string): Promise<boolean> {
    const original = this.thumbnailSourcePath(type, file);
    const bytes = this.store.readBytes(original);
    if (bytes === null || this.isAnimatedBytes(extensionOf(file), bytes)) {
      return false;
    }
    if (MediaService.skippedThumbnailExtensions.includes(extensionOf(file))) {
      return false;
    }

    try {
      const info = await this.imageInfo(bytes);
      const width = Number(info.size.width);
      const height = Number(info.size.height);
      let pixelMap: image.PixelMap;
      if (type === 'avatar' || type === 'persona') {
        pixelMap = await this.createPixelMap(bytes);
      } else {
        const target = this.thumbnailSize(type, width, height);
        const options: image.DecodingOptions = {
          desiredSize: {
            width: target.width,
            height: target.height,
          },
        };
        pixelMap = await this.createPixelMap(bytes, options);
      }
      try {
        if (type === 'avatar' || type === 'persona') {
          const current = await pixelMap.getImageInfo();
          await this.coverPixelMap(pixelMap, Number(current.size.width), Number(current.size.height),
            MediaService.avatarThumbWidth, MediaService.avatarThumbHeight);
        }
        const output = await this.packPixelMap(pixelMap, 'image/jpeg', 95);
        this.store.writeBytes(this.thumbnailPath(type, file), output);
        return true;
      } finally {
        await this.releasePixelMap(pixelMap);
      }
    } catch (_err) {
      return false;
    }
  }

  private async createPixelMap(bytes: Uint8Array, options?: image.DecodingOptions): Promise<image.PixelMap> {
    const source = image.createImageSource(this.toArrayBuffer(bytes));
    try {
      return await source.createPixelMap(options);
    } finally {
      await source.release();
    }
  }

  private async imageInfo(bytes: Uint8Array): Promise<image.ImageInfo> {
    const source = image.createImageSource(this.toArrayBuffer(bytes));
    try {
      return await source.getImageInfo();
    } finally {
      await source.release();
    }
  }

  private async averageColor(bytes: Uint8Array, animated: boolean): Promise<string> {
    if (animated) {
      return '#808080';
    }

    try {
      const pixelMap = await this.createPixelMap(bytes, {
        desiredSize: {
          width: 1,
          height: 1,
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      try {
        const buffer = new ArrayBuffer(4);
        await pixelMap.readPixelsToBuffer(buffer);
        const pixels = new Uint8Array(buffer);
        return `#${this.hexByte(pixels[0])}${this.hexByte(pixels[1])}${this.hexByte(pixels[2])}`;
      } finally {
        await this.releasePixelMap(pixelMap);
      }
    } catch (_err) {
      return '#808080';
    }
  }

  private async packPixelMap(pixelMap: image.PixelMap, format: string, quality: number): Promise<Uint8Array> {
    const packer = image.createImagePacker();
    try {
      const packed = await packer.packToData(pixelMap, {
        format,
        quality,
      });
      return new Uint8Array(packed);
    } finally {
      await packer.release();
    }
  }

  private async releasePixelMap(pixelMap: image.PixelMap): Promise<void> {
    try {
      await pixelMap.release();
    } catch (_err) {
    }
  }

  private async coverPixelMap(pixelMap: image.PixelMap, width: number, height: number, targetWidth: number,
    targetHeight: number): Promise<void> {
    if (width <= 0 || height <= 0) {
      return;
    }
    if (width === targetWidth && height === targetHeight) {
      return;
    }
    const scale = Math.max(targetWidth / width, targetHeight / height) + 0.0001;
    await pixelMap.scale(scale, scale);
    const scaled = await pixelMap.getImageInfo();
    const scaledWidth = Number(scaled.size.width);
    const scaledHeight = Number(scaled.size.height);
    if (scaledWidth < targetWidth || scaledHeight < targetHeight) {
      return;
    }
    const x = Math.max(0, Math.floor((scaledWidth - targetWidth) / 2));
    const y = Math.max(0, Math.floor((scaledHeight - targetHeight) / 2));
    await pixelMap.crop({
      x,
      y,
      size: {
        width: targetWidth,
        height: targetHeight,
      },
    });
  }

  private thumbnailSize(type: string, width: number, height: number): image.Size {
    if (type === 'avatar' || type === 'persona') {
      return {
        width: MediaService.avatarThumbWidth,
        height: MediaService.avatarThumbHeight,
      };
    }
    const ratio = height > 0 ? width / height : 1.0;
    const area = MediaService.bgThumbWidth * MediaService.bgThumbHeight;
    return {
      width: Math.max(1, Math.round(Math.sqrt(area * ratio))),
      height: Math.max(1, Math.round(Math.sqrt(area / ratio))),
    };
  }

  private async getOrGenerateMetadataBatch(relativePaths: string[], type: string): Promise<JsonRecord> {
    const index = this.readMetadataIndex();
    const images = this.asRecord(index['images']);
    const results = emptyJsonRecord();
    let modified = false;
    for (const relativePath of relativePaths) {
      if (!this.validRelativePath(relativePath)) {
        continue;
      }
      const path = joinPath(this.userDirs.root, relativePath);
      const stat = this.store.stat(path);
      if (stat === null) {
        continue;
      }
      const key = this.posixPath(relativePath);
      const cached = this.asRecord(images[key]);
      if (Object.keys(cached).length > 0 && Number(cached['mtime'] ?? 0) === stat.mtimeMs) {
        results[key] = cached;
        continue;
      }
      const meta = await this.generateMetadata(path, type, stat);
      if (Object.keys(cached).length > 0) {
        meta['folderIds'] = this.asArray(cached['folderIds']);
      }
      images[key] = meta;
      results[key] = meta;
      modified = true;
    }
    index['images'] = images;
    if (modified) {
      this.writeMetadataIndex(index);
    }
    return results;
  }

  private async generateMetadata(path: string, type: string, stat: FileEntry): Promise<JsonRecord> {
    const bytes = this.store.readBytes(path) ?? new Uint8Array();
    const meta = emptyJsonRecord();
    meta['hash'] = this.hex(this.crypto.sha256(bytes));
    let width = 1;
    let height = 1;
    try {
      const info = await this.imageInfo(bytes);
      width = Number(info.size.width);
      height = Number(info.size.height);
    } catch (_err) {
    }
    const animated = this.isAnimatedBytes(extensionOf(path), bytes);
    meta['aspectRatio'] = Number((height > 0 ? width / height : 1.0).toFixed(4));
    meta['isAnimated'] = animated;
    meta['dominantColor'] = await this.averageColor(bytes, animated);
    meta['folderIds'] = [];
    meta['addedTimestamp'] = Math.floor(stat.ctimeMs || stat.mtimeMs || Date.now());
    meta['thumbnailResolution'] = this.thumbnailResolution(type);
    meta['mtime'] = stat.mtimeMs;
    return meta;
  }

  private readMetadataIndex(): JsonRecord {
    const index = this.store.readJsonRecord(joinPath(this.userDirs.root, 'image-metadata.json'));
    if (typeof index['version'] !== 'number') {
      index['version'] = 1;
    }
    if (index['images'] === undefined || Array.isArray(index['images']) || typeof index['images'] !== 'object') {
      index['images'] = emptyJsonRecord();
    }
    if (!Array.isArray(index['folders'])) {
      index['folders'] = [];
    }
    return index;
  }

  private writeMetadataIndex(index: JsonRecord): void {
    this.store.writeJson(joinPath(this.userDirs.root, 'image-metadata.json'), index);
  }

  private removeMetadata(relativePath: string): void {
    const key = this.posixPath(relativePath);
    const index = this.readMetadataIndex();
    const images = this.asRecord(index['images']);
    index['images'] = this.withoutRecordKey(images, key);
    const filename = this.baseName(key);
    const folders = this.asArray(index['folders']);
    for (const item of folders) {
      const folder = this.asRecord(item);
      if (this.asString(folder['thumbnailFile']) === filename) {
        folder['thumbnailFile'] = '';
      }
    }
    this.writeMetadataIndex(index);
  }

  private renameMetadata(oldPath: string, newPath: string): void {
    const oldKey = this.posixPath(oldPath);
    const newKey = this.posixPath(newPath);
    const index = this.readMetadataIndex();
    const images = this.asRecord(index['images']);
    const meta = this.asRecord(images[oldKey]);
    if (Object.keys(meta).length > 0) {
      const nextImages = this.withoutRecordKey(images, oldKey);
      nextImages[newKey] = meta;
      index['images'] = nextImages;
    }
    const oldName = this.baseName(oldKey);
    const newName = this.baseName(newKey);
    const folders = this.asArray(index['folders']);
    for (const item of folders) {
      const folder = this.asRecord(item);
      if (this.asString(folder['thumbnailFile']) === oldName) {
        folder['thumbnailFile'] = newName;
      }
    }
    this.writeMetadataIndex(index);
  }

  private updateFolderAssignments(request: HttpRequest, assign: boolean): HttpResponse {
    const body = this.bodyAsRecord(request);
    const id = this.asString(body['id']);
    if (id.length === 0) {
      const response = emptyJsonRecord();
      response['error'] = '"id" is required.';
      return HttpResponse.json(response, 400);
    }
    if (!Array.isArray(body['paths'])) {
      const response = emptyJsonRecord();
      response['error'] = '"paths" array is required.';
      return HttpResponse.json(response, 400);
    }
    const paths = this.asArray(body['paths']).map((item: JsonValue): string => this.asString(item));
    const index = this.readMetadataIndex();
    if (assign && this.findFolder(index, id) === null) {
      return HttpResponse.json(this.metadataError(`Folder '${id}' not found.`), 404);
    }
    const images = this.asRecord(index['images']);
    for (const path of paths) {
      const normalized = this.posixPath(path);
      if (!normalized.startsWith('backgrounds/') || normalized.includes('../')) {
        return HttpResponse.json(this.metadataError(`Invalid background path: '${path}'`), 500);
      }
      if (assign && !this.store.exists(joinPath(this.userDirs.root, normalized))) {
        continue;
      }
      const meta = this.asRecord(images[normalized]);
      if (Object.keys(meta).length === 0 && assign) {
        meta['folderIds'] = [];
        images[normalized] = meta;
      }
      const folderIds = this.asArray(meta['folderIds']).map((item: JsonValue): string => this.asString(item));
      if (assign) {
        if (!folderIds.includes(id)) {
          folderIds.push(id);
        }
      } else {
        const indexOf = folderIds.indexOf(id);
        if (indexOf >= 0) {
          folderIds.splice(indexOf, 1);
        }
      }
      meta['folderIds'] = folderIds;
    }
    index['images'] = images;
    this.writeMetadataIndex(index);
    const response = emptyJsonRecord();
    response['ok'] = true;
    return HttpResponse.json(response);
  }

  private findFolder(index: JsonRecord, id: string): JsonRecord | null {
    for (const item of this.asArray(index['folders'])) {
      const folder = this.asRecord(item);
      if (this.asString(folder['id']) === id) {
        return folder;
      }
    }
    return null;
  }

  private withoutRecordKey(record: JsonRecord, excludedKey: string): JsonRecord {
    const next = emptyJsonRecord();
    Object.keys(record).forEach((key: string) => {
      if (key !== excludedKey) {
        next[key] = record[key];
      }
    });
    return next;
  }

  private imageFiles(directory: string, sortBy: string, type: number): string[] {
    const files = this.store.list(directory).filter((entry: FileEntry): boolean => entry.isFile &&
      this.mediaTypeMatches(entry.name, type));
    files.sort((a: FileEntry, b: FileEntry): number => {
      if (sortBy === 'date') {
        return a.mtimeMs - b.mtimeMs;
      }
      return a.name.localeCompare(b.name);
    });
    return files.map((entry: FileEntry): string => entry.name);
  }

  private mediaTypeMatches(name: string, type: number): boolean {
    const contentType = this.contentTypeForFile(name);
    if ((type & MediaService.mediaRequestImage) !== 0 && contentType.startsWith('image/')) {
      return true;
    }
    if ((type & MediaService.mediaRequestVideo) !== 0 && contentType.startsWith('video/')) {
      return true;
    }
    if ((type & MediaService.mediaRequestAudio) !== 0 && contentType.startsWith('audio/')) {
      return true;
    }
    return false;
  }

  private dataFilePath(requestPath: string): string {
    if (requestPath.startsWith('/characters/')) {
      const relative = requestPath.slice('/characters/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.characters, relative);
    }
    if (requestPath.startsWith('/User Avatars/')) {
      const relative = requestPath.slice('/User Avatars/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.avatars, relative);
    }
    if (requestPath.startsWith('/backgrounds/')) {
      const relative = requestPath.slice('/backgrounds/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.backgrounds, relative);
    }
    if (requestPath.startsWith('/user/images/')) {
      const relative = requestPath.slice('/user/images/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.userImages, relative);
    }
    if (requestPath.startsWith('/user/files/')) {
      const relative = requestPath.slice('/user/files/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.files, relative);
    }
    if (requestPath.startsWith('/assets/')) {
      const relative = requestPath.slice('/assets/'.length);
      if (!this.validRelativePath(relative)) {
        return '';
      }
      return joinPath(this.userDirs.assets, relative);
    }
    return '';
  }

  private serveFile(path: string): HttpResponse {
    const bytes = this.store.readBytes(path);
    if (bytes === null) {
      return HttpResponse.empty(404);
    }
    return HttpResponse.bytes(bytes, 200, this.contentTypeForFile(path));
  }

  private deleteClientRelativeFile(request: HttpRequest, allowedRoot: string, missingMessage: string): HttpResponse {
    const relativePath = this.asString(this.bodyAsRecord(request)['path']);
    if (relativePath.length === 0) {
      return HttpResponse.text(missingMessage, 400);
    }
    const path = joinPath(this.userDirs.root, relativePath);
    if (!this.isPathUnderParent(allowedRoot, path)) {
      return HttpResponse.text('Invalid path', 400);
    }
    if (!this.store.exists(path)) {
      return HttpResponse.text('File not found', 404);
    }
    this.store.deleteFile(path);
    return HttpResponse.empty(200);
  }

  private spritesPath(name: string): string {
    if (name.includes('/')) {
      const parts = name.split('/');
      if (parts.length < 2) {
        return '';
      }
      const characterName = sanitizeFileName(parts[0]);
      const subfolderName = sanitizeFileName(parts[1]);
      if (characterName.length === 0 || subfolderName.length === 0 || characterName === 'unnamed' || subfolderName === 'unnamed') {
        return '';
      }
      return joinPath(this.userDirs.characters, characterName, subfolderName);
    }
    const safeName = sanitizeFileName(name);
    if (safeName.length === 0 || safeName === 'unnamed') {
      return '';
    }
    return joinPath(this.userDirs.characters, safeName);
  }

  private collectImageFiles(root: string): FileEntry[] {
    const results: FileEntry[] = [];
    for (const entry of this.store.list(root)) {
      if (entry.isDirectory) {
        results.push(...this.collectImageFiles(entry.path));
      } else if (entry.isFile && MediaService.imageExtensions.includes(extensionOf(entry.name)) &&
        !entry.path.replace(/\\/g, '/').includes('/__MACOSX/')) {
        results.push(entry);
      }
    }
    return results;
  }

  private findByBaseName(directory: string, baseName: string): string {
    for (const entry of this.store.list(directory)) {
      if (entry.isFile && withoutExtension(entry.name) === baseName) {
        return entry.path;
      }
    }
    return '';
  }

  private ensureAssetFolders(): void {
    for (const category of ['bgm', 'ambient', 'blip', 'live2d', 'vrm', 'character', 'temp']) {
      this.store.ensureDir(joinPath(this.userDirs.assets, category));
    }
    this.store.ensureDir(joinPath(this.userDirs.assets, 'vrm', 'model'));
    this.store.ensureDir(joinPath(this.userDirs.assets, 'vrm', 'animation'));
  }

  private validAssetCategory(category: string): boolean {
    return ['bgm', 'ambient', 'blip', 'live2d', 'vrm', 'character', 'temp'].includes(category);
  }

  private assetFileList(category: string): string[] {
    const files: string[] = [];
    for (const entry of this.store.list(joinPath(this.userDirs.assets, category))) {
      if (entry.isFile && entry.name !== '.placeholder') {
        files.push(`assets/${category}/${entry.name}`);
      }
    }
    return files;
  }

  private live2dAssets(root: string, clientRoot: string): string[] {
    const files: string[] = [];
    for (const entry of this.collectFiles(root)) {
      if (entry.isFile && entry.name.includes('model') && extensionOf(entry.name) === '.json') {
        const relative = this.clientRelativePath(root, entry.path);
        if (relative.length > 0) {
          files.push(`${clientRoot}/${relative}`);
        }
      }
    }
    return files;
  }

  private recursiveClientFiles(root: string): string[] {
    const files: string[] = [];
    for (const entry of this.collectFiles(root)) {
      if (entry.isFile && entry.name !== '.placeholder') {
        const relative = this.clientRelativePath(this.userDirs.root, entry.path);
        if (relative.length > 0) {
          files.push(relative);
        }
      }
    }
    return files;
  }

  private collectFiles(root: string): FileEntry[] {
    const results: FileEntry[] = [];
    for (const entry of this.store.list(root)) {
      if (entry.isDirectory) {
        results.push(...this.collectFiles(entry.path));
      } else if (entry.isFile) {
        results.push(entry);
      }
    }
    return results;
  }

  private async downloadContentFromUrl(url: string): Promise<RemoteContentResult | null> {
    if (!this.isValidHttpUrl(url)) {
      return null;
    }
    const host = this.hostFromUrl(url);
    if (host.includes('chub.ai') || host.includes('characterhub.org')) {
      const parsed = this.parseChubUrl(url);
      if (parsed.length === 0) {
        return null;
      }
      return parsed.startsWith('lorebooks/') ? await this.downloadChubLorebook(parsed) :
        await this.downloadChubCharacter(parsed);
    }
    if (host.includes('pygmalion.chat')) {
      const uuid = this.uuidFromText(url);
      return uuid.length > 0 ? await this.downloadPygmalionCharacter(uuid) : null;
    }
    if (host.includes('janitorai')) {
      const uuid = this.uuidFromText(url);
      return uuid.length > 0 ? await this.downloadJanitorCharacter(uuid) : null;
    }
    if (host.includes('realm.risuai.net')) {
      const uuid = this.risuUuid(url);
      return uuid.length > 0 ? await this.downloadDirectCharacter(`https://realm.risuai.net/api/v1/download/png-v3/${uuid}?non_commercial=true`,
        `${uuid}.png`) : null;
    }
    if (host.includes('aicharactercards.com')) {
      const path = this.lastPathSegments(url, 2);
      return path.length > 0 ? await this.downloadDirectCharacter(`https://aicharactercards.com/wp-json/pngapi/v1/image/${path}`,
        `${path.replace(/\//g, '_')}.png`) : null;
    }
    if (host.includes('perchance.org')) {
      const slug = this.perchanceSlug(url);
      return slug.length > 0 ? await this.downloadPerchanceCharacter(slug) : null;
    }
    if (this.isHostWhitelisted(host)) {
      return await this.downloadGenericPng(url);
    }
    return null;
  }

  private async downloadContentFromUuid(uuid: string): Promise<RemoteContentResult | null> {
    if (this.isPerchanceUuid(uuid)) {
      return await this.downloadPerchanceCharacter(this.perchanceSlug(uuid));
    }
    if (uuid.includes('_character')) {
      const characterId = uuid.split('_')[0];
      return characterId.length > 0 ? await this.downloadJanitorCharacter(characterId) : null;
    }
    if (uuid.length === 36 && this.uuidFromText(uuid) === uuid) {
      return await this.downloadPygmalionCharacter(uuid);
    }
    if (uuid.startsWith('AICC/')) {
      const parts = uuid.split('/');
      if (parts.length >= 3) {
        return await this.downloadDirectCharacter(`https://aicharactercards.com/wp-json/pngapi/v1/image/${parts[1]}/${parts[2]}`,
          `${sanitizeFileName(parts[2])}.png`);
      }
    }
    if (uuid.includes('lorebook')) {
      return await this.downloadChubLorebook(uuid);
    }
    return await this.downloadChubCharacter(uuid);
  }

  private async downloadChubLorebook(id: string): Promise<RemoteContentResult | null> {
    const parts = id.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length < 3) {
      return null;
    }
    const metadataUrl = `https://api.chub.ai/api/${parts[0]}/${parts[1]}/${parts.slice(2).join('/')}`;
    const metadata = await this.http.getText(metadataUrl, { 'Accept': 'application/json', 'User-Agent': 'SillyTavern' }, 120000);
    if (metadata.statusCode < 200 || metadata.statusCode >= 300) {
      return null;
    }
    const record = this.parseJsonRecord(metadata.text);
    const node = this.asRecord(record['node']);
    const projectId = this.asString(node['id']);
    if (projectId.length === 0) {
      return null;
    }
    const raw = await this.http.getBytes(`https://api.chub.ai/api/v4/projects/${projectId}/repository/files/raw%252Fsillytavern_raw.json/raw`,
      { 'Accept': 'application/json', 'User-Agent': 'SillyTavern' }, 120000);
    if (raw.statusCode < 200 || raw.statusCode >= 300 || raw.bytes === null) {
      return null;
    }
    const result = new RemoteContentResult();
    result.bytes = raw.bytes;
    result.fileName = `${sanitizeFileName(parts[parts.length - 1])}.json`;
    result.contentType = raw.headers['content-type'] ?? 'application/json; charset=utf-8';
    result.contentKind = 'lorebook';
    return result;
  }

  private async downloadChubCharacter(id: string): Promise<RemoteContentResult | null> {
    const parts = id.replace(/^characters\//, '').split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length < 2) {
      return null;
    }
    const metadata = await this.http.getText(`https://api.chub.ai/api/characters/${parts[0]}/${parts.slice(1).join('/')}?full=true`,
      { 'Accept': 'application/json', 'User-Agent': 'SillyTavern' }, 120000);
    if (metadata.statusCode < 200 || metadata.statusCode >= 300) {
      return null;
    }
    const record = this.parseJsonRecord(metadata.text);
    const node = this.asRecord(record['node']);
    const definition = this.asRecord(node['definition']);
    const card = this.chubCharacterCard(parts[0], definition, this.asArray(node['topics']));
    let avatar = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0,
      0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1,
      122, 94, 171, 63, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
    const imageUrl = this.asString(node['max_res_url']);
    if (imageUrl.length > 0) {
      const downloaded = await this.http.getBytes(imageUrl, { 'User-Agent': 'SillyTavern' }, 120000);
      if (downloaded.statusCode >= 200 && downloaded.statusCode < 300 && downloaded.bytes !== null) {
        avatar = downloaded.bytes;
      }
    }
    const output = this.cardStore.writeCardToBytes(avatar, card);
    if (output === null) {
      return null;
    }
    const result = new RemoteContentResult();
    result.bytes = output;
    result.fileName = `${sanitizeFileName(this.asString(this.asRecord(card['data'])['name']) || parts[parts.length - 1])}.png`;
    result.contentType = 'image/png';
    result.contentKind = 'character';
    return result;
  }

  private async downloadPygmalionCharacter(uuid: string): Promise<RemoteContentResult | null> {
    const data = await this.http.getText(`https://server.pygmalion.chat/api/export/character/${uuid}/v2`,
      { 'User-Agent': 'SillyTavern' }, 120000);
    if (data.statusCode < 200 || data.statusCode >= 300) {
      return null;
    }
    const result = new RemoteContentResult();
    result.fileName = `${sanitizeFileName(uuid)}.json`;
    result.contentType = 'application/json; charset=utf-8';
    result.contentKind = 'character';
    result.bytes = this.utf8Bytes(data.text);
    const parsed = this.parseJsonRecord(data.text);
    const character = this.asRecord(parsed['character']);
    const characterData = this.asRecord(character['data']);
    const avatarUrl = this.asString(characterData['avatar']);
    if (avatarUrl.length > 0) {
      const avatar = await this.http.getBytes(avatarUrl, { 'User-Agent': 'SillyTavern' }, 120000);
      if (avatar.statusCode >= 200 && avatar.statusCode < 300 && avatar.bytes !== null) {
        const cardBytes = this.cardStore.writeCardToBytes(avatar.bytes, character);
        if (cardBytes !== null) {
          result.bytes = cardBytes;
          result.fileName = `${sanitizeFileName(uuid)}.png`;
          result.contentType = 'image/png';
        }
      }
    }
    return result;
  }

  private async downloadJanitorCharacter(uuid: string): Promise<RemoteContentResult | null> {
    const payload = emptyJsonRecord();
    payload['characterId'] = uuid;
    const response = await this.http.postJsonBytes('https://api.jannyai.com/api/v1/download',
      payload, { 'Content-Type': 'application/json', 'User-Agent': 'SillyTavern' }, 120000);
    if (response.statusCode < 200 || response.statusCode >= 300 || response.bytes === null) {
      return null;
    }
    const record = this.parseJsonRecord(response.text);
    if (this.asString(record['status']) !== 'ok') {
      return null;
    }
    const downloadUrl = this.asString(record['downloadUrl']);
    if (downloadUrl.length === 0) {
      return null;
    }
    return await this.downloadDirectCharacter(downloadUrl, `${sanitizeFileName(uuid)}.png`);
  }

  private async downloadPerchanceCharacter(slug: string): Promise<RemoteContentResult | null> {
    const content = await this.fetchPerchanceContent(slug);
    if (content === null) {
      return null;
    }
    const perchance = content.record;
    const avatarUrl = this.asString(this.asRecord(perchance['avatar'])['url']);
    const card = this.perchanceCharacterCard(content, avatarUrl);
    const avatar = await this.fetchPerchanceAvatar(avatarUrl);
    const output = this.cardStore.writeCardToBytes(avatar, card);
    if (output === null) {
      return null;
    }
    const name = this.asString(this.asRecord(card['data'])['name']) || 'Unnamed Perchance Character';
    const result = new RemoteContentResult();
    result.bytes = output;
    result.fileName = `${sanitizeFileName(name)}.png`;
    result.contentType = 'image/png';
    result.contentKind = 'character';
    return result;
  }

  private async fetchPerchanceContent(slug: string): Promise<PerchanceContent | null> {
    const safeSlug = sanitizeFileName(slug);
    if (safeSlug.length === 0 || !safeSlug.endsWith('.gz')) {
      return null;
    }
    const charUrl = `https://user.uploads.dev/file/${safeSlug}`;
    const downloaded = await this.http.getBytes(charUrl, { 'Content-Type': 'application/json', 'User-Agent': 'SillyTavern' }, 120000);
    if (downloaded.statusCode < 200 || downloaded.statusCode >= 300 || downloaded.bytes === null) {
      return null;
    }
    const gzipPath = joinPath(this.dirs.uploadRoot, `perchance-${Date.now()}-${safeSlug}`);
    this.store.writeBytes(gzipPath, downloaded.bytes);
    try {
      const gzip = zlib.createGZipSync();
      await gzip.gzopen(gzipPath, 'rb');
      try {
        const chunks: Uint8Array[] = [];
        while (await gzip.gzeof() === 0) {
          const buffer = new ArrayBuffer(32768);
          const read = await gzip.gzfread(buffer, 1, 32768);
          if (read <= 0) {
            break;
          }
          chunks.push(new Uint8Array(buffer).slice(0, read));
        }
        const text = this.decoder.decodeToString(this.concatByteArrays(chunks));
        const root = this.parseJsonRecord(text);
        const addCharacter = this.asRecord(root['addCharacter']);
        if (Object.keys(addCharacter).length === 0) {
          return null;
        }
        const content = new PerchanceContent();
        content.slug = safeSlug;
        content.charUrl = charUrl;
        content.record = addCharacter;
        return content;
      } finally {
        await gzip.gzclose();
      }
    } catch (_err) {
      return null;
    } finally {
      this.store.deleteFile(gzipPath);
    }
  }

  private async fetchPerchanceAvatar(avatarUrl: string): Promise<Uint8Array> {
    if (avatarUrl.startsWith('data:image/')) {
      try {
        const raw = this.base64.decodeSync(this.stripDataUrl(avatarUrl), util.Type.BASIC);
        return avatarUrl.startsWith('data:image/png;base64,') ? raw : await this.convertImageToPng(raw);
      } catch (_err) {
        return this.defaultPngBytes();
      }
    }
    if (!this.isValidHttpUrl(avatarUrl)) {
      return this.defaultPngBytes();
    }
    try {
      const avatar = await this.http.getBytes(avatarUrl, { 'User-Agent': 'SillyTavern' }, 120000);
      if (avatar.statusCode < 200 || avatar.statusCode >= 300 || avatar.bytes === null) {
        return this.defaultPngBytes();
      }
      const contentType = avatar.headers['content-type'] ?? '';
      return contentType.includes('image/png') ? avatar.bytes : await this.convertImageToPng(avatar.bytes);
    } catch (_err) {
      return this.defaultPngBytes();
    }
  }

  private perchanceCharacterCard(content: PerchanceContent, avatarUrl: string): JsonRecord {
    const perchance = content.record;
    const data = emptyJsonRecord();
    data['name'] = this.asString(perchance['name']) || 'Unnamed Perchance Character';
    data['first_mes'] = '';
    data['tags'] = [];
    data['description'] = this.asString(perchance['roleInstruction']);
    data['creator'] = this.asString(perchance['metaTitle']);
    data['creator_notes'] = this.asString(perchance['metaDescription']);
    data['alternate_greetings'] = [];
    data['character_version'] = '';
    data['mes_example'] = '';
    data['post_history_instructions'] = '';
    data['system_prompt'] = '';
    data['scenario'] = '';
    data['personality'] = this.asString(perchance['reminderMessage']);
    const extensions = emptyJsonRecord();
    const perchanceData = emptyJsonRecord();
    perchanceData['slug'] = content.slug;
    perchanceData['char_url'] = content.charUrl;
    perchanceData['uuid'] = this.asString(perchance['uuid']) || null;
    perchanceData['avatar_url'] = avatarUrl.startsWith('data:image/') ? null : (avatarUrl || null);
    perchanceData['folder_path'] = this.asString(perchance['folderPath']) || null;
    perchanceData['folder_name'] = this.asString(perchance['folderName']) || null;
    perchanceData['custom_data'] = this.asRecord(perchance['customData']);
    extensions['perchance_data'] = perchanceData;
    data['extensions'] = extensions;
    const card = emptyJsonRecord();
    card['spec'] = 'chara_card_v2';
    card['spec_version'] = '2.0';
    card['data'] = data;
    return card;
  }

  private async downloadDirectCharacter(url: string, filename: string): Promise<RemoteContentResult | null> {
    const downloaded = await this.http.getBytes(url, { 'User-Agent': 'SillyTavern' }, 120000);
    if (downloaded.statusCode < 200 || downloaded.statusCode >= 300 || downloaded.bytes === null) {
      return null;
    }
    const result = new RemoteContentResult();
    result.bytes = downloaded.bytes;
    result.fileName = sanitizeFileName(filename);
    result.contentType = downloaded.headers['content-type'] ?? this.contentTypeForFile(filename);
    result.contentKind = 'character';
    return result;
  }

  private async downloadGenericPng(url: string): Promise<RemoteContentResult | null> {
    const downloaded = await this.http.getBytes(url, { 'User-Agent': 'SillyTavern' }, 120000);
    if (downloaded.statusCode < 200 || downloaded.statusCode >= 300 || downloaded.bytes === null) {
      return null;
    }
    const result = new RemoteContentResult();
    result.bytes = downloaded.bytes;
    result.contentType = downloaded.headers['content-type'] ?? 'image/png';
    result.contentKind = 'character';
    let fileName = sanitizeFileName(this.urlFileName(url));
    if (fileName.length === 0 || fileName === 'unnamed') {
      fileName = `${Date.now()}.png`;
    }
    if (result.contentType.includes('image/png') && extensionOf(fileName).length === 0) {
      fileName = `${fileName}.png`;
    }
    result.fileName = fileName;
    return result;
  }

  private contentDownloadResponse(result: RemoteContentResult): HttpResponse {
    const response = HttpResponse.bytes(result.bytes, 200, result.contentType);
    response.headers['content-disposition'] = `attachment; filename="${encodeURIComponent(result.fileName)}"`;
    response.headers['x-custom-content-type'] = result.contentKind;
    return response;
  }

  private chubCharacterCard(creator: string, definition: JsonRecord, topics: JsonArray): JsonRecord {
    const data = emptyJsonRecord();
    data['name'] = this.asString(definition['name']) || 'Chub Character';
    data['description'] = this.asString(definition['personality']);
    data['personality'] = this.asString(definition['tavern_personality']);
    data['scenario'] = this.asString(definition['scenario']);
    data['first_mes'] = this.asString(definition['first_message']);
    data['mes_example'] = this.asString(definition['example_dialogs']);
    data['creator_notes'] = this.asString(definition['description']);
    data['system_prompt'] = this.asString(definition['system_prompt']);
    data['post_history_instructions'] = this.asString(definition['post_history_instructions']);
    data['alternate_greetings'] = this.asArray(definition['alternate_greetings']);
    data['tags'] = topics;
    data['creator'] = creator;
    data['character_version'] = '';
    data['character_book'] = definition['embedded_lorebook'] ?? emptyJsonRecord();
    data['extensions'] = this.asRecord(definition['extensions']);
    const card = emptyJsonRecord();
    card['spec'] = 'chara_card_v2';
    card['spec_version'] = '2.0';
    card['data'] = data;
    return card;
  }

  private parseChubUrl(url: string): string {
    const marker = this.hostFromUrl(url);
    const path = this.urlPath(url);
    const parts = path.split('/').filter((part: string): boolean => part.length > 0);
    if (!(marker.includes('chub.ai') || marker.includes('characterhub.org'))) {
      return '';
    }
    if (parts.length >= 3 && (parts[0] === 'characters' || parts[0] === 'lorebooks')) {
      return parts.join('/');
    }
    if (parts.length >= 2) {
      return parts.join('/');
    }
    return '';
  }

  private hostFromUrl(url: string): string {
    const match = url.match(/^https?:\/\/([^/?#:]+)(?::\d+)?/i);
    return match === null ? '' : match[1].toLowerCase();
  }

  private urlPath(url: string): string {
    const match = url.match(/^https?:\/\/[^/?#:]+(?::\d+)?([^?#]*)/i);
    return match === null ? '' : match[1];
  }

  private urlFileName(url: string): string {
    const path = this.urlPath(url);
    const parts = path.split('/').filter((part: string): boolean => part.length > 0);
    return parts.length === 0 ? '' : parts[parts.length - 1];
  }

  private uuidFromText(text: string): string {
    const match = text.match(/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/i);
    return match === null ? '' : match[0];
  }

  private risuUuid(url: string): string {
    const parts = this.urlPath(url).split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length >= 2 && parts[0] === 'character') {
      return sanitizeFileName(parts[1]);
    }
    return '';
  }

  private perchanceSlug(url: string): string {
    const marker = url.indexOf('~');
    if (marker < 0) {
      return '';
    }
    const afterMarker = url.slice(marker + 1);
    const gzIndex = afterMarker.indexOf('.gz');
    if (gzIndex < 0) {
      return '';
    }
    return sanitizeFileName(afterMarker.slice(0, gzIndex + 3));
  }

  private isPerchanceUuid(value: string): boolean {
    return /^\w+~[a-f0-9]{32}\.gz$/i.test(value);
  }

  private lastPathSegments(url: string, count: number): string {
    const parts = this.urlPath(url).split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length < count) {
      return '';
    }
    return parts.slice(parts.length - count).map((part: string): string => sanitizeFileName(part)).join('/');
  }

  private isValidHttpUrl(url: string): boolean {
    return /^https?:\/\/[^/?#]+\.[^/?#]+/i.test(url) || /^https?:\/\/localhost(?::\d+)?/i.test(url) ||
      /^https?:\/\/127\.0\.0\.1(?::\d+)?/i.test(url);
  }

  private isHostWhitelisted(host: string): boolean {
    return ['localhost', '127.0.0.1', 'cdn.discordapp.com', 'media.discordapp.net', 'files.catbox.moe',
      'raw.githubusercontent.com'].includes(host);
  }

  private parseJsonRecord(text: string): JsonRecord {
    try {
      const parsed = JSON.parse(text) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        return emptyJsonRecord();
      }
      return parsed as JsonRecord;
    } catch (_err) {
      return emptyJsonRecord();
    }
  }

  private utf8Bytes(value: string): Uint8Array {
    return new util.TextEncoder('utf-8').encodeInto(value);
  }

  private concatByteArrays(chunks: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const chunk of chunks) {
      total += chunk.byteLength;
    }
    const output = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      output.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return output;
  }

  private async convertImageToPng(bytes: Uint8Array): Promise<Uint8Array> {
    const pixelMap = await this.createPixelMap(bytes);
    try {
      return await this.packPixelMap(pixelMap, 'image/png', 100);
    } finally {
      await this.releasePixelMap(pixelMap);
    }
  }

  private defaultPngBytes(): Uint8Array {
    return new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0,
      0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1,
      122, 94, 171, 63, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
  }

  private validateAssetFileName(inputFilename: string): string {
    if (!/^[a-zA-Z0-9_\-.]+$/.test(inputFilename)) {
      return "Illegal character in filename; only alphanumeric, '_', '-' are accepted.";
    }
    if (MediaService.unsafeExtensions.includes(extensionOf(inputFilename))) {
      return 'Forbidden file extension.';
    }
    if (inputFilename.startsWith('.')) {
      return "Filename cannot start with '.'";
    }
    if (sanitizeFileName(inputFilename) !== inputFilename) {
      return 'Reserved or long filename.';
    }
    return '';
  }

  private parseCrop(text: string | undefined): CropParams | null {
    if (text === undefined || text.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(text) as JsonRecord;
      const crop = new CropParams();
      crop.x = Number(parsed['x']);
      crop.y = Number(parsed['y']);
      crop.width = Number(parsed['width']);
      crop.height = Number(parsed['height']);
      crop.want_resize = parsed['want_resize'] === true;
      if ([crop.x, crop.y, crop.width, crop.height].some((value: number): boolean => !Number.isFinite(value)) ||
        crop.width <= 0 || crop.height <= 0) {
        return null;
      }
      return crop;
    } catch (_err) {
      return null;
    }
  }

  private thumbnailSourcePath(type: string, file: string): string {
    switch (type) {
      case 'avatar':
        return joinPath(this.userDirs.characters, file);
      case 'persona':
        return joinPath(this.userDirs.avatars, file);
      case 'bg':
        return joinPath(this.userDirs.backgrounds, file);
      default:
        return '';
    }
  }

  private thumbnailPath(type: string, file: string): string {
    switch (type) {
      case 'avatar':
        return joinPath(this.userDirs.thumbnailsAvatar, file);
      case 'persona':
        return joinPath(this.userDirs.thumbnailsPersona, file);
      case 'bg':
        return joinPath(this.userDirs.thumbnailsBg, file);
      default:
        return '';
    }
  }

  private invalidateThumbnail(type: string, file: string): void {
    const path = this.thumbnailPath(type, sanitizeFileName(file));
    if (path.length > 0) {
      this.store.deleteFile(path);
    }
  }

  private thumbnailResolution(type: string): number {
    if (type === 'avatar' || type === 'persona') {
      return MediaService.avatarThumbWidth * MediaService.avatarThumbHeight;
    }
    return MediaService.bgThumbWidth * MediaService.bgThumbHeight;
  }

  private isThumbnailType(type: string): boolean {
    return type === 'bg' || type === 'avatar' || type === 'persona';
  }

  private contentTypeForFile(path: string): string {
    switch (extensionOf(path)) {
      case '.png':
      case '.apng':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
      case '.jfif':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.tif':
      case '.tiff':
        return 'image/tiff';
      case '.mp4':
        return 'video/mp4';
      case '.avi':
        return 'video/x-msvideo';
      case '.mov':
        return 'video/quicktime';
      case '.wmv':
        return 'video/x-ms-wmv';
      case '.flv':
        return 'video/x-flv';
      case '.webm':
        return 'video/webm';
      case '.3gp':
        return 'video/3gpp';
      case '.mkv':
        return 'video/x-matroska';
      case '.mpg':
        return 'video/mpeg';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.ogg':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.aac':
        return 'audio/aac';
      case '.m4a':
        return 'audio/mp4';
      case '.aiff':
        return 'audio/aiff';
      case '.svg':
        return 'image/svg+xml';
      case '.json':
        return 'application/json; charset=utf-8';
      case '.txt':
        return 'text/plain; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  private isAnimatedBytes(ext: string, bytes: Uint8Array): boolean {
    if (ext === '.gif' || ext === '.apng') {
      return true;
    }
    const header = this.asciiHeader(bytes, 200);
    if (ext === '.png') {
      return header.includes('acTL');
    }
    if (ext === '.webp') {
      return header.includes('ANIM') || header.includes('ANMF');
    }
    return false;
  }

  private validRelativePath(path: string): boolean {
    if (path.length === 0 || path.includes('\u0000')) {
      return false;
    }
    const normalized = path.replace(/\\/g, '/');
    return !normalized.split('/').some((segment: string): boolean => segment === '..' || segment.length === 0);
  }

  private isPathUnderParent(parentPath: string, childPath: string): boolean {
    const parent = parentPath.replace(/\\/g, '/').replace(/\/+$/, '');
    const child = childPath.replace(/\\/g, '/');
    return child === parent || child.startsWith(`${parent}/`);
  }

  private clientRelativePath(root: string, path: string): string {
    const normalizedRoot = root.replace(/\\/g, '/').replace(/\/+$/, '');
    const normalizedPath = path.replace(/\\/g, '/');
    if (!normalizedPath.startsWith(normalizedRoot)) {
      return '';
    }
    return normalizedPath.slice(normalizedRoot.length).replace(/^\/+/, '');
  }

  private bodyAsRecord(request: HttpRequest): JsonRecord {
    if (request.body === null || Array.isArray(request.body)) {
      return emptyJsonRecord();
    }
    return request.body as JsonRecord;
  }

  private asString(value: JsonValue | undefined): string {
    if (value === undefined || value === null || Array.isArray(value)) {
      return '';
    }
    return `${value}`;
  }

  private asArray(value: JsonValue | undefined): JsonArray {
    return Array.isArray(value) ? value : [];
  }

  private asRecord(value: JsonValue | undefined): JsonRecord {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      return emptyJsonRecord();
    }
    return value as JsonRecord;
  }

  private stripDataUrl(value: string): string {
    const comma = value.indexOf(',');
    if (value.startsWith('data:') && comma >= 0) {
      return value.slice(comma + 1);
    }
    return value;
  }

  private toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const buffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    return buffer;
  }

  private hex(bytes: Uint8Array): string {
    const parts: string[] = [];
    for (let index = 0; index < bytes.byteLength; index += 1) {
      parts.push(this.hexByte(bytes[index]));
    }
    return parts.join('');
  }

  private hexByte(value: number): string {
    return value.toString(16).padStart(2, '0');
  }

  private posixPath(path: string): string {
    return path.replace(/\\/g, '/').replace(/^\/+/, '');
  }

  private baseName(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.slice(slash + 1) : normalized;
  }

  private spriteTimestamp(mtimeMs: number): string {
    const date = new Date(Math.round(mtimeMs));
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  }

  private spriteLabel(fileBase: string): string {
    const dash = fileBase.indexOf('-');
    const dot = fileBase.indexOf('.');
    let end = fileBase.length;
    if (dash >= 0) {
      end = Math.min(end, dash);
    }
    if (dot >= 0) {
      end = Math.min(end, dot);
    }
    return fileBase.slice(0, end);
  }

  private asciiHeader(bytes: Uint8Array, length: number): string {
    const end = Math.min(bytes.byteLength, length);
    let output = '';
    for (let index = 0; index < end; index += 1) {
      output += String.fromCharCode(bytes[index]);
    }
    return output;
  }

  private metadataError(message: string): JsonRecord {
    const response = emptyJsonRecord();
    response['error'] = message;
    return response;
  }
}
