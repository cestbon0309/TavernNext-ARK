import { CryptoUtils } from './CryptoUtils';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileStore } from './FileStore';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';
import { ShareExportService } from './ShareExportService';
import { zlib } from '@kit.BasicServicesKit';

type JsonValue = Object | string | number | boolean | null | JsonArray;

class TavernUser {
  handle: string = '';
  name: string = '';
  created: number = 0;
  password: string = '';
  salt: string = '';
  enabled: boolean = true;
  admin: boolean = false;
}

export class UsersService {
  private static readonly keyPrefix: string = 'user:';
  private static readonly avatarPrefix: string = 'avatar:';
  private static readonly publicUserAvatar: string = '/img/default-user.png';
  private store: FileStore;
  private dirs: DataDirectories;
  private crypto: CryptoUtils;
  private shareExports: ShareExportService;
  private resetCodes: Map<string, string> = new Map<string, string>();
  private recoverCodes: Map<string, string> = new Map<string, string>();

  constructor(store: FileStore, dirs: DataDirectories, crypto: CryptoUtils, shareExports: ShareExportService) {
    this.store = store;
    this.dirs = dirs;
    this.crypto = crypto;
    this.shareExports = shareExports;
    this.ensureDefaultUser();
  }

  listPublic(): HttpResponse {
    const users = this.allUsers().filter((user: TavernUser): boolean => user.enabled);
    return HttpResponse.json(users.map((user: TavernUser): JsonRecord => this.publicViewModel(user)));
  }

  login(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null || !user.enabled) {
      return HttpResponse.json(this.error(user === null ? 'Incorrect credentials' : 'User is disabled'), 403);
    }
    if (user.password.length > 0 && user.password !== this.crypto.scryptSillyTavern(this.asString(body['password']), user.salt)) {
      return HttpResponse.json(this.error('Incorrect credentials'), 403);
    }
    const response = emptyJsonRecord();
    response['handle'] = user.handle;
    return HttpResponse.json(response);
  }

  recoverStep1(request: HttpRequest): HttpResponse {
    const handle = this.asString(this.bodyAsRecord(request)['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    if (!user.enabled) {
      return HttpResponse.json(this.error('User is disabled'), 403);
    }
    const code = `${1000 + Math.floor(Math.random() * 8999)}`;
    this.recoverCodes.set(user.handle, code);
    const response = emptyJsonRecord();
    response['ok'] = true;
    response['code'] = code;
    response['message'] = 'Recovery code generated locally for OHOS.';
    return HttpResponse.json(response);
  }

  recoverStep2(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    const code = this.asString(body['code']);
    if (handle.length === 0 || code.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    if (!user.enabled) {
      return HttpResponse.json(this.error('User is disabled'), 403);
    }
    if (this.recoverCodes.get(user.handle) !== code) {
      return HttpResponse.json(this.error('Incorrect code'), 403);
    }
    this.setUserPassword(user, this.asString(body['newPassword']));
    this.writeUser(user);
    this.recoverCodes.delete(user.handle);
    return HttpResponse.empty(204);
  }

  logout(): HttpResponse {
    return HttpResponse.empty(204);
  }

  me(): HttpResponse {
    const user = this.ensureDefaultUser();
    const view = this.publicViewModel(user);
    view['admin'] = user.admin;
    return HttpResponse.json(view);
  }

  getAdmin(): HttpResponse {
    return HttpResponse.json(this.allUsers().map((user: TavernUser): JsonRecord => this.adminViewModel(user)));
  }

  enable(request: HttpRequest): HttpResponse {
    return this.updateUserFlag(request, 'enabled', true);
  }

  disable(request: HttpRequest): HttpResponse {
    const handle = this.asString(this.bodyAsRecord(request)['handle']);
    if (handle === 'default-user') {
      return HttpResponse.json(this.error('Cannot disable yourself'), 400);
    }
    return this.updateUserFlag(request, 'enabled', false);
  }

  promote(request: HttpRequest): HttpResponse {
    return this.updateUserFlag(request, 'admin', true);
  }

  demote(request: HttpRequest): HttpResponse {
    const handle = this.asString(this.bodyAsRecord(request)['handle']);
    if (handle === 'default-user') {
      return HttpResponse.json(this.error('Cannot demote yourself'), 400);
    }
    return this.updateUserFlag(request, 'admin', false);
  }

  create(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    if (this.asString(body['handle']).length === 0 || this.asString(body['name']).length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const handle = this.slugifyText(this.asString(body['handle']));
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Invalid handle'), 400);
    }
    if (this.getUser(handle) !== null) {
      return HttpResponse.json(this.error('User already exists'), 409);
    }

    const user = new TavernUser();
    user.handle = handle;
    user.name = this.asString(body['name']) || 'Anonymous';
    user.created = Date.now();
    user.admin = body['admin'] === true;
    user.enabled = true;
    this.setUserPassword(user, this.asString(body['password']));
    this.writeUser(user);
    this.ensureUserDirs(new UserDirectories(this.dirs.dataRoot, handle));

    const response = emptyJsonRecord();
    response['handle'] = user.handle;
    return HttpResponse.json(response);
  }

  delete(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    if (handle === 'default-user') {
      return HttpResponse.json(this.error('Sorry, but the default user cannot be deleted. It is required as a fallback.'), 400);
    }
    this.store.deleteFile(this.datumPath(UsersService.keyPrefix + handle));
    this.store.deleteFile(this.datumPath(UsersService.avatarPrefix + handle));
    if (body['purge'] === true) {
      this.store.deleteDirectory(new UserDirectories(this.dirs.dataRoot, handle).root);
    }
    return HttpResponse.empty(204);
  }

  changeAvatar(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    const avatar = this.asString(body['avatar']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    if (!avatar.startsWith('data:image/') && avatar.length !== 0) {
      return HttpResponse.json(this.error('Invalid data URL'), 400);
    }
    if (this.getUser(handle) === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    this.writeDatum(UsersService.avatarPrefix + handle, avatar);
    return HttpResponse.empty(204);
  }

  changePassword(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    if (!user.enabled) {
      return HttpResponse.json(this.error('User is disabled'), 403);
    }
    const oldPassword = this.asString(body['oldPassword']);
    if (user.password.length > 0 && user.password !== this.crypto.scryptSillyTavern(oldPassword, user.salt)) {
      return HttpResponse.json(this.error('Incorrect password'), 403);
    }
    this.setUserPassword(user, this.asString(body['newPassword']));
    this.writeUser(user);
    return HttpResponse.empty(204);
  }

  async backup(request: HttpRequest): Promise<HttpResponse> {
    const handle = this.asString(this.bodyAsRecord(request)['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }

    const fileName = `tavernnext-data-${this.timestamp()}.zip`;
    const file = this.shareExports.exportFileReference('users', fileName,
      ShareExportService.contentTypeForExtension('.zip'), ShareExportService.utdForExtension('.zip'));
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
    };
    await zlib.compressFile(this.dirs.dataRoot, file.path, options);
    return await this.shareExports.shareHttpResponse(file, 'TavernNext data backup');
  }

  async restoreData(request: HttpRequest): Promise<HttpResponse> {
    const file = request.file('archive') ?? request.file('file') ?? (request.files.length > 0 ? request.files[0] : null);
    if (file === null) {
      return HttpResponse.json(this.error('Missing backup file'), 400);
    }
    if (!file.fileName.toLowerCase().endsWith('.zip')) {
      return HttpResponse.json(this.error('Backup file must be a zip archive'), 400);
    }

    const restoreId = this.timestampWithMs();
    const restoreRoot = joinPath(this.dirs.restoreRoot, `restore-${restoreId}`);
    const uploadPath = joinPath(restoreRoot, 'upload.zip');
    const unpackRoot = joinPath(restoreRoot, 'unpacked');
    const previousDataRoot = joinPath(this.dirs.restoreRoot, `previous-data-${restoreId}`);
    this.store.ensureDir(restoreRoot);
    this.store.ensureDir(unpackRoot);
    this.store.writeBytes(uploadPath, file.bytes);

    try {
      await zlib.decompressFile(uploadPath, unpackRoot);
    } catch (_err) {
      this.store.deleteDirectory(restoreRoot);
      return HttpResponse.json(this.error('Failed to decompress backup zip'), 400);
    }

    const candidate = this.restoreCandidatePath(unpackRoot);
    if (candidate.length === 0) {
      this.store.deleteDirectory(restoreRoot);
      return HttpResponse.json(this.error('The zip archive does not look like a TavernNext data backup'), 400);
    }

    if (!this.replaceDataDirectory(candidate, previousDataRoot)) {
      this.store.deleteDirectory(restoreRoot);
      return HttpResponse.json(this.error('Failed to restore data directory'), 500);
    }

    this.dirs.initialize();
    this.store.deleteDirectory(previousDataRoot);
    this.store.deleteDirectory(restoreRoot);

    const response = emptyJsonRecord();
    response['ok'] = true;
    response['restored'] = true;
    response['message'] = 'Data directory restored.';
    return HttpResponse.json(response);
  }

  resetSettings(request: HttpRequest): HttpResponse {
    const user = this.ensureDefaultUser();
    const password = this.asString(this.bodyAsRecord(request)['password']);
    if (user.password.length > 0 && user.password !== this.crypto.scryptSillyTavern(password, user.salt)) {
      return HttpResponse.json(this.error('Incorrect password'), 403);
    }
    this.store.deleteFile(joinPath(this.dirs.defaultUser.root, 'settings.json'));
    this.store.writeJson(joinPath(this.dirs.defaultUser.root, 'settings.json'), emptyJsonRecord());
    return HttpResponse.empty(204);
  }

  changeName(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const handle = this.asString(body['handle']);
    const name = this.asString(body['name']);
    if (handle.length === 0 || name.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    user.name = name;
    this.writeUser(user);
    return HttpResponse.empty(204);
  }

  resetStep1(): HttpResponse {
    const user = this.ensureDefaultUser();
    const code = `${1000 + Math.floor(Math.random() * 8999)}`;
    this.resetCodes.set(user.handle, code);
    const response = emptyJsonRecord();
    response['ok'] = true;
    response['code'] = code;
    response['message'] = 'Reset code generated locally for OHOS.';
    return HttpResponse.json(response);
  }

  resetStep2(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const user = this.ensureDefaultUser();
    const code = this.asString(body['code']);
    if (code.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    if (user.password.length > 0 && user.password !== this.crypto.scryptSillyTavern(this.asString(body['password']), user.salt)) {
      return HttpResponse.json(this.error('Incorrect password'), 400);
    }
    if (this.resetCodes.get(user.handle) !== code) {
      return HttpResponse.json(this.error('Incorrect code'), 400);
    }
    const root = this.dirs.defaultUser.root;
    this.store.deleteDirectory(root);
    this.ensureUserDirs(this.dirs.defaultUser);
    this.store.writeJson(joinPath(root, 'settings.json'), emptyJsonRecord());
    this.store.writeJson(joinPath(root, 'secrets.json'), emptyJsonRecord());
    this.store.writeJson(joinPath(root, 'stats.json'), emptyJsonRecord());
    this.store.writeText(joinPath(root, 'content.log'), '');
    this.store.writeText(joinPath(root, 'image-metadata.json'), '{}');
    this.resetCodes.delete(user.handle);
    return HttpResponse.empty(204);
  }

  slugify(request: HttpRequest): HttpResponse {
    const text = this.asString(this.bodyAsRecord(request)['text']);
    if (text.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    return HttpResponse.text(this.slugifyText(text));
  }

  private ensureDefaultUser(): TavernUser {
    let user = this.getUser('default-user');
    if (user !== null) {
      return user;
    }
    user = new TavernUser();
    user.handle = 'default-user';
    user.name = 'User';
    user.created = Date.now();
    user.password = '';
    user.salt = '';
    user.admin = true;
    user.enabled = true;
    this.writeUser(user);
    return user;
  }

  private allUsers(): TavernUser[] {
    const users: TavernUser[] = [];
    for (const entry of this.store.list(this.dirs.storageRoot)) {
      if (!entry.isFile) {
        continue;
      }
      const datum = this.store.readJsonRecord(entry.path);
      const key = this.asString(datum['key']);
      if (!key.startsWith(UsersService.keyPrefix)) {
        continue;
      }
      const value = this.asObject(datum['value']) as JsonRecord;
      users.push(this.userFromRecord(value));
    }
    users.sort((left: TavernUser, right: TavernUser): number => left.created - right.created);
    return users;
  }

  private getUser(handle: string): TavernUser | null {
    const datum = this.store.readJsonRecord(this.datumPath(UsersService.keyPrefix + handle));
    const value = this.asObject(datum['value']) as JsonRecord;
    if (Object.keys(value).length === 0) {
      return null;
    }
    return this.userFromRecord(value);
  }

  private writeUser(user: TavernUser): void {
    this.writeDatum(UsersService.keyPrefix + user.handle, user);
  }

  private writeDatum(key: string, value: Object | string): void {
    const datum = emptyJsonRecord();
    datum['key'] = key;
    datum['value'] = value;
    datum['ttl'] = null;
    this.store.writeJson(this.datumPath(key), datum);
  }

  private datumPath(key: string): string {
    return joinPath(this.dirs.storageRoot, this.crypto.sha256Hex(key));
  }

  private userFromRecord(record: JsonRecord): TavernUser {
    const user = new TavernUser();
    user.handle = this.asString(record['handle']);
    user.name = this.asString(record['name']) || user.handle;
    user.created = Number(record['created'] ?? Date.now());
    user.password = this.asString(record['password']);
    user.salt = this.asString(record['salt']);
    user.enabled = record['enabled'] !== false;
    user.admin = record['admin'] === true;
    return user;
  }

  private publicViewModel(user: TavernUser): JsonRecord {
    const view = emptyJsonRecord();
    view['handle'] = user.handle;
    view['name'] = user.name;
    view['created'] = user.created;
    view['avatar'] = this.getUserAvatar(user.handle);
    view['password'] = user.password.length > 0;
    return view;
  }

  private adminViewModel(user: TavernUser): JsonRecord {
    const view = this.publicViewModel(user);
    view['admin'] = user.admin;
    view['enabled'] = user.enabled;
    return view;
  }

  private getUserAvatar(handle: string): string {
    const avatarDatum = this.store.readJsonRecord(this.datumPath(UsersService.avatarPrefix + handle));
    const avatar = this.asString(avatarDatum['value']);
    if (avatar.length > 0) {
      return avatar;
    }
    const dirs = handle === 'default-user' ? this.dirs.defaultUser : new UserDirectories(this.dirs.dataRoot, handle);
    const settings = this.store.readJsonRecord(joinPath(dirs.root, 'settings.json'));
    const powerUser = this.asObject(settings['power_user']) as JsonRecord;
    const avatarFile = sanitizeFileName(this.asString(powerUser['default_persona']) || this.asString(settings['user_avatar']));
    if (avatarFile.length === 0 || avatarFile === 'unnamed') {
      return UsersService.publicUserAvatar;
    }
    const avatarPath = joinPath(dirs.avatars, avatarFile);
    const bytes = this.store.readBytes(avatarPath);
    if (bytes === null) {
      return UsersService.publicUserAvatar;
    }
    return `data:${this.contentTypeForFile(avatarPath)};base64,${this.base64(bytes)}`;
  }

  private setUserPassword(user: TavernUser, password: string): void {
    if (password.length === 0) {
      user.password = '';
      user.salt = '';
      return;
    }
    user.salt = this.crypto.randomBase64(16);
    user.password = this.crypto.scryptSillyTavern(password, user.salt);
  }

  private updateUserFlag(request: HttpRequest, flag: string, value: boolean): HttpResponse {
    const handle = this.asString(this.bodyAsRecord(request)['handle']);
    if (handle.length === 0) {
      return HttpResponse.json(this.error('Missing required fields'), 400);
    }
    const user = this.getUser(handle);
    if (user === null) {
      return HttpResponse.json(this.error('User not found'), 404);
    }
    if (flag === 'enabled') {
      user.enabled = value;
    }
    if (flag === 'admin') {
      user.admin = value;
    }
    this.writeUser(user);
    return HttpResponse.empty(204);
  }

  private ensureUserDirs(dirs: UserDirectories): void {
    const paths: string[] = [
      dirs.root, dirs.thumbnails, dirs.thumbnailsBg, dirs.thumbnailsAvatar, dirs.thumbnailsPersona, dirs.worlds,
      dirs.user, dirs.avatars, dirs.userImages, dirs.characters, dirs.chats, dirs.groupChats, dirs.groups,
      dirs.backgrounds, dirs.novelAISettings, dirs.koboldAISettings, dirs.openAISettings, dirs.textGenSettings,
      dirs.themes, dirs.movingUI, dirs.extensions, dirs.instruct, dirs.context, dirs.quickreplies, dirs.assets,
      dirs.comfyWorkflows, dirs.files, dirs.vectors, dirs.backups, dirs.sysprompt, dirs.reasoning,
      joinPath(dirs.assets, 'bgm'), joinPath(dirs.assets, 'ambient'), joinPath(dirs.assets, 'blip'),
      joinPath(dirs.assets, 'live2d'), joinPath(dirs.assets, 'vrm'), joinPath(dirs.assets, 'character'),
      joinPath(dirs.assets, 'temp'),
    ];
    for (const path of paths) {
      this.store.ensureDir(path);
    }
  }

  private slugifyText(text: string): string {
    return text.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  }

  private restoreCandidatePath(unpackRoot: string): string {
    const nestedDataRoot = joinPath(unpackRoot, 'data');
    if (this.isDataDirectory(nestedDataRoot)) {
      return nestedDataRoot;
    }
    if (this.isDataDirectory(unpackRoot)) {
      return unpackRoot;
    }
    return '';
  }

  private isDataDirectory(path: string): boolean {
    return this.store.exists(joinPath(path, 'default-user')) ||
      this.store.exists(joinPath(path, '_storage')) ||
      this.store.exists(joinPath(path, 'cookie-secret.txt'));
  }

  private replaceDataDirectory(source: string, previousDataRoot: string): boolean {
    const hadDataRoot = this.store.exists(this.dirs.dataRoot);
    if (hadDataRoot && !this.store.moveDirectory(this.dirs.dataRoot, previousDataRoot)) {
      return false;
    }

    if (this.store.exists(this.dirs.dataRoot)) {
      this.store.deleteDirectory(this.dirs.dataRoot);
    }

    if (this.store.copyDirectory(source, this.dirs.dataRoot)) {
      return true;
    }

    this.store.deleteDirectory(this.dirs.dataRoot);
    if (hadDataRoot) {
      this.store.moveDirectory(previousDataRoot, this.dirs.dataRoot);
    }
    return false;
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

  private asObject(value: JsonValue | JsonArray | undefined): Object {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      return emptyJsonRecord();
    }
    return value as Object;
  }

  private error(message: string): JsonRecord {
    const response = emptyJsonRecord();
    response['error'] = message;
    return response;
  }

  private base64(bytes: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let output = '';
    for (let index = 0; index < bytes.byteLength; index += 3) {
      const b1 = bytes[index];
      const b2 = index + 1 < bytes.byteLength ? bytes[index + 1] : 0;
      const b3 = index + 2 < bytes.byteLength ? bytes[index + 2] : 0;
      output += chars.charAt(b1 >> 2);
      output += chars.charAt(((b1 & 0x03) << 4) | (b2 >> 4));
      output += index + 1 < bytes.byteLength ? chars.charAt(((b2 & 0x0f) << 2) | (b3 >> 6)) : '=';
      output += index + 2 < bytes.byteLength ? chars.charAt(b3 & 0x3f) : '=';
    }
    return output;
  }

  private timestamp(): string {
    const date = new Date();
    const parts: string[] = [
      `${date.getFullYear()}`,
      `${date.getMonth() + 1}`.padStart(2, '0'),
      `${date.getDate()}`.padStart(2, '0'),
      `${date.getHours()}`.padStart(2, '0'),
      `${date.getMinutes()}`.padStart(2, '0'),
      `${date.getSeconds()}`.padStart(2, '0'),
    ];
    return `${parts[0]}${parts[1]}${parts[2]}-${parts[3]}${parts[4]}${parts[5]}`;
  }

  private timestampWithMs(): string {
    return `${this.timestamp()}-${Date.now() % 1000000}`;
  }

  private contentTypeForFile(path: string): string {
    const lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'application/octet-stream';
  }
}
