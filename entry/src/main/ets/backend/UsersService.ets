import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { CryptoUtils } from './CryptoUtils';
import { DataRestoreProgressService } from './DataRestoreProgressService';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { DefaultContentSeeder } from './DefaultContentSeeder';
import { FileEntry, FileStore } from './FileStore';
import { GitService } from './GitService';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName, withoutExtension } from './PathUtils';
import { ShareExportService } from './ShareExportService';

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

class RestorePaths {
  restoreRoot: string;
  uploadPath: string;
  unpackRoot: string;
  previousDataRoot: string;

  constructor(restoreRoot: string, uploadPath: string, unpackRoot: string, previousDataRoot: string) {
    this.restoreRoot = restoreRoot;
    this.uploadPath = uploadPath;
    this.unpackRoot = unpackRoot;
    this.previousDataRoot = previousDataRoot;
  }
}

type DataRestoreMode = 'incremental' | 'clean';

export class UsersService {
  private static readonly keyPrefix: string = 'user:';
  private static readonly avatarPrefix: string = 'avatar:';
  private static readonly publicUserAvatar: string = '/img/default-user.png';
  private store: FileStore;
  private dirs: DataDirectories;
  private crypto: CryptoUtils;
  private shareExports: ShareExportService;
  private context: common.UIAbilityContext;
  private git: GitService;
  private manager: resourceManager.ResourceManager;
  private restoreProgress: DataRestoreProgressService = DataRestoreProgressService.getInstance();
  private resetCodes: Map<string, string> = new Map<string, string>();
  private recoverCodes: Map<string, string> = new Map<string, string>();

  constructor(store: FileStore, dirs: DataDirectories, crypto: CryptoUtils, shareExports: ShareExportService,
    context: common.UIAbilityContext, git: GitService, manager: resourceManager.ResourceManager) {
    this.store = store;
    this.dirs = dirs;
    this.crypto = crypto;
    this.shareExports = shareExports;
    this.context = context;
    this.git = git;
    this.manager = manager;
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
    this.restoreProgress.begin('正在接收备份文件...');
    const file = request.file('archive') ?? request.file('file') ?? (request.files.length > 0 ? request.files[0] : null);
    if (file === null) {
      this.restoreProgress.finish('导入已取消');
      return HttpResponse.json(this.error('Missing backup file'), 400);
    }
    if (!file.fileName.toLowerCase().endsWith('.zip')) {
      this.restoreProgress.finish('导入失败');
      return HttpResponse.json(this.error('Backup file must be a zip archive'), 400);
    }

    const paths = this.createRestorePaths();
    this.store.ensureDir(paths.restoreRoot);
    this.store.ensureDir(paths.unpackRoot);
    this.restoreProgress.update('正在保存备份文件...');
    await this.allowRestoreProgressFrame();
    this.store.writeBytes(paths.uploadPath, file.bytes);
    const mode = this.restoreMode(request);
    return await this.restorePreparedZip(paths, mode);
  }

  async restoreDataWithPicker(request: HttpRequest): Promise<HttpResponse> {
    const mode = this.restoreMode(request);
    let selectedFiles: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        fileSuffixFilters: ['ZIP archive|.zip'],
      };
      selectedFiles = await documentPicker.select(options);
    } catch (_err) {
      return HttpResponse.json(this.error('Failed to open file picker'), 500);
    }

    if (selectedFiles.length === 0 || selectedFiles[0].length === 0) {
      const response = emptyJsonRecord();
      response['ok'] = false;
      response['cancelled'] = true;
      response['message'] = 'File selection cancelled.';
      return HttpResponse.json(response);
    }

    const paths = this.createRestorePaths();
    this.store.ensureDir(paths.restoreRoot);
    this.store.ensureDir(paths.unpackRoot);
    this.restoreProgress.begin('正在读取所选备份文件...');
    await this.allowRestoreProgressFrame();
    if (!this.copySelectedFile(selectedFiles[0], paths.uploadPath)) {
      this.store.deleteDirectory(paths.restoreRoot);
      this.restoreProgress.finish('导入失败');
      return HttpResponse.json(this.error('Failed to read selected backup file'), 400);
    }

    return await this.restorePreparedZip(paths, mode);
  }

  private async restorePreparedZip(paths: RestorePaths, mode: DataRestoreMode): Promise<HttpResponse> {
    const restoreRoot = paths.restoreRoot;
    const unpackRoot = paths.unpackRoot;
    const previousDataRoot = paths.previousDataRoot;

    try {
      this.restoreProgress.update('正在解压备份压缩包...');
      await zlib.decompressFile(paths.uploadPath, unpackRoot);
    } catch (_err) {
      this.store.deleteDirectory(restoreRoot);
      this.restoreProgress.finish('导入失败');
      return HttpResponse.json(this.error('Failed to decompress backup zip'), 400);
    }

    try {
      this.restoreProgress.update('正在检查备份内容...');
      const candidate = this.restoreCandidatePath(unpackRoot, restoreRoot);
      if (candidate.length === 0) {
        this.store.deleteDirectory(restoreRoot);
        this.restoreProgress.finish('导入失败');
        return HttpResponse.json(this.error('The zip archive does not look like a TavernNext data backup'), 400);
      }

      this.restoreProgress.update(mode === 'clean' ? '正在重置 data 目录...' : '正在合并 data 目录...');
      await this.allowRestoreProgressFrame();
      if (!this.mergeDataDirectory(candidate, previousDataRoot, mode)) {
        this.store.deleteDirectory(restoreRoot);
        this.restoreProgress.finish('导入失败');
        return HttpResponse.json(this.error('Failed to restore data directory'), 500);
      }

      this.restoreProgress.update('正在初始化数据目录...');
      await this.allowRestoreProgressFrame();
      this.dirs.initialize();
      this.dirs.ensureDefaultUserFiles();
      this.ensureDefaultUser();
      this.restoreProgress.update('正在检查插件 Git 信息...');
      const gitRepair = await this.rehydrateImportedExtensionRepositories();
      this.restoreProgress.update('正在清理临时文件...');
      await this.allowRestoreProgressFrame();
      this.store.deleteDirectory(previousDataRoot);
      this.store.deleteDirectory(restoreRoot);

      const response = emptyJsonRecord();
      response['ok'] = true;
      response['restored'] = true;
      response['mode'] = mode;
      response['message'] = 'Data directory restored.';
      response['extensionGitRepair'] = gitRepair;
      this.restoreProgress.finish('导入完成', this.gitRepairFailures(gitRepair));
      return HttpResponse.json(response);
    } catch (err) {
      this.store.deleteDirectory(restoreRoot);
      this.restoreProgress.finish('导入失败');
      return HttpResponse.json(this.error(this.errorMessage(err)), 500);
    }
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

  private async rehydrateImportedExtensionRepositories(): Promise<JsonRecord> {
    const result = emptyJsonRecord();
    result['checked'] = 0;
    result['rehydrated'] = 0;
    result['skipped'] = 0;
    result['failed'] = 0;
    result['failedExtensions'] = [];

    const sourceRoot = joinPath(this.dirs.dataRoot, '_tauritavern', 'extension-sources');
    if (!this.store.exists(sourceRoot)) {
      return result;
    }

    const localEntries = this.extensionMetadataEntries(joinPath(sourceRoot, 'local'));
    const globalEntries = this.extensionMetadataEntries(joinPath(sourceRoot, 'global'));
    const total = localEntries.length + globalEntries.length;
    result['total'] = total;

    await this.rehydrateExtensionScope('local', localEntries, this.localExtensionRoots(), result, total);
    await this.rehydrateExtensionScope('global', globalEntries, this.globalExtensionRoots(), result, total);
    return result;
  }

  private async rehydrateExtensionScope(scope: string, metadataEntries: FileEntry[], extensionRoots: string[],
    result: JsonRecord, total: number): Promise<void> {
    for (const entry of metadataEntries) {
      result['checked'] = Number(result['checked'] ?? 0) + 1;
      const extensionName = sanitizeFileName(withoutExtension(entry.name));
      this.restoreProgress.update('正在检查插件 Git 信息...', this.extensionGitRepairDetail(extensionName, result, total));
      const extensionPath = this.findExtensionPath(extensionName, extensionRoots);
      if (extensionPath.length === 0 || this.store.exists(joinPath(extensionPath, '.git'))) {
        result['skipped'] = Number(result['skipped'] ?? 0) + 1;
        continue;
      }

      const metadata = this.store.readJsonRecord(entry.path);
      const remoteUrl = this.extensionRemoteUrl(metadata);
      const reference = this.asString(metadata['reference']);
      const installedCommit = this.asString(metadata['installed_commit']);
      if (remoteUrl.length === 0 || !this.isFullCommit(installedCommit)) {
        result['skipped'] = Number(result['skipped'] ?? 0) + 1;
        continue;
      }

      try {
        this.restoreProgress.update('正在重建插件 Git 信息...', this.extensionGitRepairDetail(extensionName, result, total));
        await this.git.rehydrate(remoteUrl, extensionPath, reference, installedCommit);
        result['rehydrated'] = Number(result['rehydrated'] ?? 0) + 1;
      } catch (err) {
        this.store.deleteDirectory(joinPath(extensionPath, '.git'));
        result['failed'] = Number(result['failed'] ?? 0) + 1;
        this.addGitRepairFailure(result, extensionName);
        this.appendExtensionGitRepairFailure(scope, extensionName, this.errorMessage(err));
      }
    }
  }

  private addGitRepairFailure(result: JsonRecord, extensionName: string): void {
    const failures = result['failedExtensions'];
    if (!Array.isArray(failures)) {
      result['failedExtensions'] = [extensionName];
      return;
    }
    if (!failures.includes(extensionName)) {
      failures.push(extensionName);
    }
  }

  private gitRepairFailures(result: JsonRecord): string[] {
    const failures = result['failedExtensions'];
    if (!Array.isArray(failures)) {
      return [];
    }
    return failures
      .filter((value: Object | string | number | boolean | null): boolean => typeof value === 'string' && value.length > 0)
      .map((value: Object | string | number | boolean | null): string => `${value}`);
  }

  private extensionMetadataEntries(metadataRoot: string): FileEntry[] {
    return this.store.list(metadataRoot).filter((entry: FileEntry): boolean => {
      return entry.isFile && entry.name.toLowerCase().endsWith('.json');
    });
  }

  private extensionGitRepairDetail(extensionName: string, result: JsonRecord, total: number): string {
    const checked = Number(result['checked'] ?? 0);
    if (total <= 0) {
      return extensionName;
    }
    return `${extensionName} (${checked}/${total})`;
  }

  private appendExtensionGitRepairFailure(scope: string, extensionName: string, message: string): void {
    const logPath = joinPath(this.dirs.cacheRoot, 'extension-git-repair.log');
    const line = `${new Date().toISOString()} [${scope}] ${extensionName}: ${message}\n`;
    this.store.writeText(logPath, this.store.readText(logPath, '') + line);
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
      joinPath(this.dirs.dataRoot, 'extensions', 'third-party'),
      joinPath(this.dirs.dataRoot, 'public', 'scripts', 'extensions', 'third-party'),
    ].filter((path: string, index: number, paths: string[]): boolean => paths.indexOf(path) === index);
  }

  private findExtensionPath(extensionName: string, roots: string[]): string {
    for (const root of roots) {
      const candidate = joinPath(root, extensionName);
      if (this.store.exists(joinPath(candidate, 'manifest.json'))) {
        return candidate;
      }
    }
    return '';
  }

  private extensionRemoteUrl(metadata: JsonRecord): string {
    const remoteUrl = this.asString(metadata['remote_url']).trim();
    if (remoteUrl.length > 0) {
      return this.ensureGitRemoteSuffix(remoteUrl);
    }

    const host = this.asString(metadata['host']).trim();
    const repoPath = this.asString(metadata['repo_path']).trim().replace(/^\/+|\/+$/g, '');
    if (host.length === 0 || repoPath.length === 0) {
      return '';
    }
    return this.ensureGitRemoteSuffix(`https://${host}/${repoPath}`);
  }

  private ensureGitRemoteSuffix(url: string): string {
    const clean = url.trim();
    if (clean.length === 0 || clean.toLowerCase().endsWith('.git')) {
      return clean;
    }
    return `${clean}.git`;
  }

  private isFullCommit(value: string): boolean {
    return /^[0-9a-fA-F]{40}$/.test(value);
  }

  private slugifyText(text: string): string {
    return text.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  }

  private createRestorePaths(): RestorePaths {
    const restoreId = this.timestampWithMs();
    const restoreRoot = joinPath(this.dirs.restoreRoot, `restore-${restoreId}`);
    return new RestorePaths(restoreRoot, joinPath(restoreRoot, 'upload.zip'), joinPath(restoreRoot, 'unpacked'),
      joinPath(this.dirs.restoreRoot, `previous-data-${restoreId}`));
  }

  private restoreMode(request: HttpRequest): DataRestoreMode {
    const body = this.bodyAsRecord(request);
    const mode = this.asString(body['mode']) || this.asString(body['restoreMode']);
    if (mode === 'clean') {
      return 'clean';
    }
    return 'incremental';
  }

  private copySelectedFile(sourceUri: string, targetPath: string): boolean {
    this.store.ensureParentDir(targetPath);
    let source: fileIo.File | null = null;
    let target: fileIo.File | null = null;
    try {
      source = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      target = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
      const chunkSize = 1024 * 1024;
      const buffer = new ArrayBuffer(chunkSize);
      while (true) {
        const readLength = fileIo.readSync(source.fd, buffer, { length: chunkSize });
        if (readLength <= 0) {
          break;
        }
        fileIo.writeSync(target.fd, buffer, { length: readLength });
      }
      return this.store.exists(targetPath);
    } catch (_err) {
      this.store.deleteFile(targetPath);
      return false;
    } finally {
      if (source !== null) {
        try {
          fileIo.closeSync(source);
        } catch (_err) {
        }
      }
      if (target !== null) {
        try {
          fileIo.closeSync(target);
        } catch (_err) {
        }
      }
    }
  }

  private restoreCandidatePath(unpackRoot: string, restoreRoot: string): string {
    const directDataRoot = this.findDataRootCandidate(unpackRoot);
    if (directDataRoot.length > 0) {
      return directDataRoot;
    }

    const directUserRoot = this.findUserRootCandidate(unpackRoot);
    if (directUserRoot.length > 0) {
      return this.wrapUserBackupAsDataRoot(directUserRoot, restoreRoot);
    }

    for (const entry of this.store.list(unpackRoot)) {
      if (!entry.isDirectory) {
        continue;
      }
      const nestedDataRoot = this.findDataRootCandidate(entry.path);
      if (nestedDataRoot.length > 0) {
        return nestedDataRoot;
      }
      const nestedUserRoot = this.findUserRootCandidate(entry.path);
      if (nestedUserRoot.length > 0) {
        return this.wrapUserBackupAsDataRoot(nestedUserRoot, restoreRoot);
      }
    }

    return '';
  }

  private findDataRootCandidate(root: string): string {
    const nestedDataRoot = joinPath(root, 'data');
    if (this.isDataDirectory(nestedDataRoot)) {
      return nestedDataRoot;
    }
    if (this.isDataDirectory(root)) {
      return root;
    }
    return '';
  }

  private findUserRootCandidate(root: string): string {
    if (this.isUserDirectory(root)) {
      return root;
    }
    return '';
  }

  private isDataDirectory(path: string): boolean {
    return this.store.exists(joinPath(path, 'default-user')) ||
      this.store.exists(joinPath(path, '_tauritavern')) ||
      this.store.exists(joinPath(path, 'extensions', 'third-party')) ||
      this.store.exists(joinPath(path, '_storage')) ||
      this.store.exists(joinPath(path, 'cookie-secret.txt'));
  }

  private isUserDirectory(path: string): boolean {
    return this.store.exists(joinPath(path, 'settings.json')) ||
      this.store.exists(joinPath(path, 'characters')) ||
      this.store.exists(joinPath(path, 'chats')) ||
      this.store.exists(joinPath(path, 'group chats')) ||
      this.store.exists(joinPath(path, 'extensions')) ||
      this.store.exists(joinPath(path, 'User Avatars'));
  }

  private wrapUserBackupAsDataRoot(userRoot: string, restoreRoot: string): string {
    const normalizedRoot = joinPath(restoreRoot, 'normalized-data');
    const normalizedUserRoot = joinPath(normalizedRoot, 'default-user');
    this.store.deleteDirectory(normalizedRoot);
    this.store.ensureDir(normalizedRoot);
    if (!this.store.copyDirectory(userRoot, normalizedUserRoot)) {
      this.store.deleteDirectory(normalizedRoot);
      return '';
    }
    return normalizedRoot;
  }

  private mergeDataDirectory(source: string, previousDataRoot: string, mode: DataRestoreMode): boolean {
    const hadDataRoot = this.store.exists(this.dirs.dataRoot);
    if (hadDataRoot && !this.store.copyDirectory(this.dirs.dataRoot, previousDataRoot)) {
      return false;
    }

    if (mode === 'clean') {
      this.store.deleteDirectory(this.dirs.dataRoot);
      this.initializeCleanDataDirectory();
    }

    if (this.copyDirectoryOverlay(source, this.dirs.dataRoot)) {
      return true;
    }

    this.store.deleteDirectory(this.dirs.dataRoot);
    if (hadDataRoot) {
      this.store.moveDirectory(previousDataRoot, this.dirs.dataRoot);
    }
    return false;
  }

  private initializeCleanDataDirectory(): void {
    this.dirs.initialize();
    new DefaultContentSeeder(this.store, this.dirs, this.manager).seedDefaultUser();
    this.dirs.ensureDefaultUserFiles();
    this.ensureDefaultUser();
  }

  private copyDirectoryOverlay(source: string, target: string): boolean {
    const sourceEntry = this.store.stat(source);
    if (sourceEntry === null) {
      return false;
    }

    const targetEntry = this.store.stat(target);
    if (sourceEntry.isDirectory) {
      if (targetEntry !== null && targetEntry.isFile) {
        this.store.deleteFile(target);
      }
      this.store.ensureDir(target);
      for (const entry of this.store.list(source)) {
        if (!this.copyDirectoryOverlay(entry.path, joinPath(target, entry.name))) {
          return false;
        }
      }
      return true;
    }

    if (sourceEntry.isFile) {
      if (targetEntry !== null && targetEntry.isDirectory) {
        this.store.deleteDirectory(target);
      }
      return this.store.copyFile(source, target);
    }

    return true;
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

  private errorMessage(err: Object | string | null | undefined): string {
    if (err === undefined || err === null) {
      return 'Unknown error';
    }
    if (typeof err === 'string') {
      return err;
    }
    return JSON.stringify(err);
  }

  private async allowRestoreProgressFrame(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 24);
    });
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
