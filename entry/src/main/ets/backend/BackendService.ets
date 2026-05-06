import { common, Context } from '@kit.AbilityKit';
import { ChatBrowserService } from './ChatBrowserService';
import { DataDirectories } from './DataDirectories';
import { CryptoUtils } from './CryptoUtils';
import { DefaultContentSeeder } from './DefaultContentSeeder';
import { ExtensionsService } from './ExtensionsService';
import { FileStore } from './FileStore';
import { GitService } from './GitService';
import { JsonRecord } from './HttpTypes';
import { HttpServer } from './HttpServer';
import { asRecord, asString } from './JsonUtils';
import { LlmBackgroundTaskService } from './LlmBackgroundTaskService';
import { MediaService } from './MediaService';
import { ModelProxyService } from './ModelProxyService';
import { joinPath } from './PathUtils';
import { SecretsService } from './SecretsService';
import { ShareExportService } from './ShareExportService';
import { ShellThemeService } from './ShellThemeService';
import { SillyTavernCore } from './SillyTavernCore';
import { StaticFileServer } from './StaticFileServer';
import { TokenizerService } from './TokenizerService';
import { UsersService } from './UsersService';
import { VectorService } from './VectorService';

export class BackendStatus {
  running: boolean;
  url: string;
  dataRoot: string;
  message: string;

  constructor(running: boolean, url: string, dataRoot: string, message: string) {
    this.running = running;
    this.url = url;
    this.dataRoot = dataRoot;
    this.message = message;
  }
}

export class BackendService {
  private static instance: BackendService | null = null;
  private server: HttpServer;
  private directories: DataDirectories;
  private store: FileStore;
  private core: SillyTavernCore;
  private media: MediaService;
  private crypto: CryptoUtils;
  private secrets: SecretsService;
  private users: UsersService;
  private git: GitService;
  private extensions: ExtensionsService;
  private modelProxy: ModelProxyService;
  private llmBackgroundTasks: LlmBackgroundTaskService;
  private tokenizers: TokenizerService;
  private vectors: VectorService;
  private shareExports: ShareExportService;
  private shellTheme: ShellThemeService;
  private chatBrowser: ChatBrowserService;
  private staticFiles: StaticFileServer;
  private lastMessage: string = 'Not started';

  private constructor(context: Context) {
    this.store = new FileStore();
    this.crypto = new CryptoUtils();
    this.directories = new DataDirectories(context.filesDir, this.store);
    this.directories.initialize();
    new DefaultContentSeeder(this.store, this.directories, context.resourceManager).seedDefaultUser();
    this.directories.ensureDefaultUserFiles();
    this.shellTheme = ShellThemeService.getInstance(context);
    this.syncShellThemeFromCurrentSettings();
    this.shareExports = new ShareExportService(context as common.UIAbilityContext, this.store, this.directories.exportRoot);
    this.core = new SillyTavernCore(this.store, this.directories, this.shareExports, context.resourceManager,
      (settings: JsonRecord) => this.syncShellThemeFromSettings(settings));
    this.media = new MediaService(this.store, this.directories, this.crypto);
    this.secrets = new SecretsService(this.store, this.directories.defaultUser, this.crypto);
    this.users = new UsersService(this.store, this.directories, this.crypto, this.shareExports,
      context as common.UIAbilityContext);
    this.git = new GitService(this.store, this.prepareGitCaBundle(context));
    this.extensions = new ExtensionsService(this.store, this.directories, context.resourceManager, this.git);
    this.llmBackgroundTasks = new LlmBackgroundTaskService(context as common.UIAbilityContext);
    this.modelProxy = new ModelProxyService(this.directories, this.secrets, this.llmBackgroundTasks);
    this.tokenizers = new TokenizerService();
    this.vectors = new VectorService(this.store, this.directories, this.secrets);
    this.chatBrowser = new ChatBrowserService(this.store, this.directories);
    this.staticFiles = new StaticFileServer(context.resourceManager, () => this.shellTheme.getBackgroundColor());
    this.server = new HttpServer('127.0.0.1', 8000);
    this.registerRoutes();
  }

  static getInstance(context: Context): BackendService {
    if (BackendService.instance === null) {
      BackendService.instance = new BackendService(context);
    }
    return BackendService.instance;
  }

  getChatBrowser(): ChatBrowserService {
    return this.chatBrowser;
  }

  async start(): Promise<BackendStatus> {
    try {
      await this.server.start();
      this.lastMessage = 'ArkTS backend is listening.';
    } catch (err) {
      this.lastMessage = `Failed to start backend: ${JSON.stringify(err)}`;
    }
    return this.status();
  }

  async stop(): Promise<BackendStatus> {
    await this.server.stop();
    this.lastMessage = 'ArkTS backend stopped.';
    return this.status();
  }

  status(): BackendStatus {
    return new BackendStatus(this.server.isListening(), `http://${this.server.host}:${this.server.port}`,
      this.directories.dataRoot, this.lastMessage);
  }

  private registerRoutes(): void {
    this.server.route('GET', '/', async (request) => this.staticFiles.serve(request));
    this.server.route('GET', '/health', async () => this.core.health());
    this.server.route('GET', '/csrf-token', async () => this.core.csrfToken());
    this.server.route('GET', '/version', async () => this.core.version());
    this.server.route('GET', '/thumbnail', async (request) => await this.media.getDataFile(request));
    this.server.route('POST', '/api/ohos/shell-theme/background',
      async (request) => this.shellTheme.reportBackground(request));
    this.server.route('POST', '/api/ohos/chats/browser/open', async () => this.chatBrowser.openBrowser());
    this.server.route('POST', '/api/ohos/chats/browser/list', async (request) => this.chatBrowser.listResponse(request));
    this.server.route('POST', '/api/ohos/chats/browser/refresh', async () => this.chatBrowser.refreshResponse());
    this.server.route('POST', '/api/ohos/chats/browser/delete',
      async (request) => this.chatBrowser.deleteResponse(request));

    this.server.route('POST', '/api/ping', async () => this.core.ping());

    this.server.route('POST', '/api/stats/get', async () => this.core.statsGet());
    this.server.route('POST', '/api/stats/update', async (request) => this.core.statsUpdate(request));
    this.server.route('POST', '/api/stats/recreate', async () => this.core.statsRecreate());

    this.server.route('POST', '/api/settings/get', async () => this.core.getSettings());
    this.server.route('POST', '/api/settings/save', async (request) => this.core.saveSettings(request));
    this.server.route('POST', '/api/settings/get-snapshots', async () => this.core.settingsSnapshots());
    this.server.route('POST', '/api/settings/load-snapshot', async (request) => this.core.loadSettingsSnapshot(request));
    this.server.route('POST', '/api/settings/make-snapshot', async () => this.core.makeSettingsSnapshot());
    this.server.route('POST', '/api/settings/restore-snapshot',
      async (request) => this.core.restoreSettingsSnapshot(request));
    this.server.route('POST', '/api/presets/save', async (request) => this.core.savePreset(request));
    this.server.route('POST', '/api/presets/delete', async (request) => this.core.deletePreset(request));
    this.server.route('POST', '/api/presets/restore', async (request) => this.core.restorePreset(request));
    this.server.route('POST', '/api/themes/save', async (request) => this.core.saveTheme(request));
    this.server.route('POST', '/api/themes/delete', async (request) => this.core.deleteTheme(request));
    this.server.route('POST', '/api/moving-ui/save', async (request) => this.core.saveMovingUi(request));
    this.server.route('POST', '/savetheme', async (request) => this.core.saveTheme(request));
    this.server.route('POST', '/savemovingui', async (request) => this.core.saveMovingUi(request));

    this.server.route('POST', '/api/characters/all', async () => this.core.listCharacters());
    this.server.route('POST', '/api/characters/get', async (request) => this.core.getCharacter(request));
    this.server.route('POST', '/api/characters/create', async (request) => this.core.createCharacter(request));
    this.server.route('POST', '/api/characters/edit', async (request) => this.core.editCharacter(request));
    this.server.route('POST', '/api/characters/edit-avatar', async (request) => this.core.editCharacterAvatar(request));
    this.server.route('POST', '/api/characters/edit-attribute',
      async (request) => this.core.editCharacterAttribute(request));
    this.server.route('POST', '/api/characters/merge-attributes',
      async (request) => this.core.mergeCharacterAttributes(request));
    this.server.route('POST', '/api/characters/duplicate', async (request) => this.core.duplicateCharacter(request));
    this.server.route('POST', '/api/characters/rename', async (request) => this.core.renameCharacter(request));
    this.server.route('POST', '/api/characters/delete', async (request) => this.core.deleteCharacter(request));
    this.server.route('POST', '/api/characters/chats', async (request) => this.core.listCharacterChats(request));
    this.server.route('POST', '/api/characters/import', async (request) => this.core.importCharacter(request));
    this.server.route('POST', '/api/characters/export', async (request) => await this.core.exportCharacter(request));

    this.server.route('POST', '/api/chats/get', async (request) => this.core.getChat(request));
    this.server.route('POST', '/api/chats/save', async (request) => this.core.saveChat(request));
    this.server.route('POST', '/api/chats/delete', async (request) => this.core.deleteChat(request));
    this.server.route('POST', '/api/chats/rename', async (request) => this.core.renameChat(request));
    this.server.route('POST', '/api/chats/import', async (request) => this.core.importChat(request));
    this.server.route('POST', '/api/chats/export', async (request) => await this.core.exportChat(request));
    this.server.route('POST', '/api/chats/search', async (request) => this.core.searchChats(request));
    this.server.route('POST', '/api/chats/group/get', async (request) => this.core.getGroupChat(request));
    this.server.route('POST', '/api/chats/group/save', async (request) => this.core.saveGroupChat(request));
    this.server.route('POST', '/api/chats/group/delete', async (request) => this.core.deleteGroupChat(request));
    this.server.route('POST', '/api/chats/group/import', async (request) => this.core.importGroupChat(request));
    this.server.route('POST', '/api/chats/group/info', async (request) => this.core.groupChatInfo(request));
    this.server.route('POST', '/api/chats/recent', async (request) => this.core.recentChats(request));
    this.server.route('POST', '/api/backups/chat/get', async () => this.core.chatBackups());
    this.server.route('POST', '/api/backups/chat/download', async (request) => this.core.downloadChatBackup(request));
    this.server.route('POST', '/api/backups/chat/delete', async (request) => this.core.deleteChatBackup(request));

    this.server.route('POST', '/api/worldinfo/list', async () => this.core.listWorlds());
    this.server.route('POST', '/api/worldinfo/get', async (request) => this.core.getWorld(request));
    this.server.route('POST', '/api/worldinfo/edit', async (request) => this.core.editWorld(request));
    this.server.route('POST', '/api/worldinfo/import', async (request) => this.core.importWorld(request));
    this.server.route('POST', '/api/worldinfo/export', async (request) => await this.core.exportWorld(request));
    this.server.route('POST', '/api/worldinfo/delete', async (request) => this.core.deleteWorld(request));
    this.server.route('POST', '/importworldinfo', async (request) => this.core.importWorld(request));

    this.server.route('POST', '/api/groups/all', async () => this.core.listGroups());
    this.server.route('POST', '/api/groups/create', async (request) => this.core.createGroup(request));
    this.server.route('POST', '/api/groups/edit', async (request) => this.core.editGroup(request));
    this.server.route('POST', '/api/groups/delete', async (request) => this.core.deleteGroup(request));

    this.server.route('POST', '/api/backgrounds/all', async () => await this.media.listBackgrounds());
    this.server.route('POST', '/api/backgrounds/folders', async () => this.media.listBackgroundFolders());
    this.server.route('POST', '/api/backgrounds/delete', async (request) => this.media.deleteBackground(request));
    this.server.route('POST', '/api/backgrounds/rename', async (request) => await this.media.renameBackground(request));
    this.server.route('POST', '/api/backgrounds/upload', async (request) => await this.media.uploadBackground(request));
    this.server.route('POST', '/getbackgrounds', async () => await this.media.listBackgrounds());
    this.server.route('POST', '/delbackground', async (request) => this.media.deleteBackground(request));
    this.server.route('POST', '/renamebackground', async (request) => await this.media.renameBackground(request));
    this.server.route('POST', '/downloadbackground', async (request) => await this.media.uploadBackground(request));

    this.server.route('POST', '/api/avatars/get', async () => this.media.listAvatars());
    this.server.route('POST', '/api/avatars/delete', async (request) => this.media.deleteAvatar(request));
    this.server.route('POST', '/api/avatars/upload', async (request) => await this.media.uploadAvatar(request));
    this.server.route('POST', '/getuseravatars', async () => this.media.listAvatars());
    this.server.route('POST', '/deleteuseravatar', async (request) => this.media.deleteAvatar(request));
    this.server.route('POST', '/uploaduseravatar', async (request) => await this.media.uploadAvatar(request));

    this.server.route('POST', '/api/images/upload', async (request) => await this.media.uploadImage(request));
    this.server.route('POST', '/api/images/list', async (request) => this.media.listImages(request));
    this.server.route('POST', '/api/images/folders', async () => this.media.imageFolders());
    this.server.route('POST', '/api/images/delete', async (request) => this.media.deleteImage(request));
    this.server.route('POST', '/uploadimage', async (request) => await this.media.uploadImage(request));
    this.server.route('POST', '/listimgfiles', async (request) => this.media.listImages(request));

    this.server.route('POST', '/api/files/sanitize-filename',
      async (request) => this.media.sanitizeUploadedFileName(request));
    this.server.route('POST', '/api/files/upload', async (request) => this.media.uploadFile(request));
    this.server.route('POST', '/api/files/delete', async (request) => this.media.deleteFile(request));
    this.server.route('POST', '/api/files/verify', async (request) => this.media.verifyFiles(request));
    this.server.route('POST', '/api/assets/get', async () => this.media.assetsGet());
    this.server.route('POST', '/api/assets/download', async (request) => await this.media.assetsDownload(request));
    this.server.route('POST', '/api/assets/delete', async (request) => this.media.assetsDelete(request));
    this.server.route('POST', '/api/assets/character', async (request) => this.media.assetsCharacter(request));
    this.server.route('POST', '/api/content/importURL', async (request) => await this.media.contentImportUrl(request));
    this.server.route('POST', '/api/content/importUUID', async (request) => await this.media.contentImportUuid(request));
    this.server.route('POST', '/api/content/import', async (request) => await this.media.contentImportUrl(request));
    this.server.route('POST', '/api/content-manager/importURL',
      async (request) => await this.media.contentImportUrl(request));
    this.server.route('POST', '/api/content-manager/importUUID',
      async (request) => await this.media.contentImportUuid(request));

    this.server.route('GET', '/api/sprites/get', async (request) => this.media.spritesGet(request));
    this.server.route('POST', '/api/sprites/delete', async (request) => this.media.spritesDelete(request));
    this.server.route('POST', '/api/sprites/upload', async (request) => this.media.spritesUpload(request));
    this.server.route('POST', '/api/sprites/upload-zip', async (request) => await this.media.spritesUploadZip(request));

    this.server.route('POST', '/api/image-metadata/all', async (request) => this.media.imageMetadataAll(request));
    this.server.route('POST', '/api/image-metadata', async (request) => await this.media.imageMetadata(request));
    this.server.route('POST', '/api/image-metadata/folders/get',
      async () => this.media.imageMetadataFoldersGet());
    this.server.route('POST', '/api/image-metadata/folders/create',
      async (request) => this.media.imageMetadataFoldersCreate(request));
    this.server.route('POST', '/api/image-metadata/folders/update',
      async (request) => this.media.imageMetadataFoldersUpdate(request));
    this.server.route('POST', '/api/image-metadata/folders/delete',
      async (request) => this.media.imageMetadataFoldersDelete(request));
    this.server.route('POST', '/api/image-metadata/folders/set-thumbnails',
      async (request) => this.media.imageMetadataFoldersSetThumbnails(request));
    this.server.route('POST', '/api/image-metadata/folders/assign',
      async (request) => this.media.imageMetadataFoldersAssign(request));
    this.server.route('POST', '/api/image-metadata/folders/unassign',
      async (request) => this.media.imageMetadataFoldersUnassign(request));
    this.server.route('POST', '/api/image-metadata/cleanup', async () => this.media.imageMetadataCleanup());
    this.server.route('POST', '/api/quick-reply/save', async (request) => this.core.saveQuickReply(request));
    this.server.route('POST', '/api/quick-reply/delete', async (request) => this.core.deleteQuickReply(request));
    this.server.route('POST', '/api/quick-replies/save', async (request) => this.core.saveQuickReply(request));
    this.server.route('POST', '/api/quick-replies/delete', async (request) => this.core.deleteQuickReply(request));
    this.server.route('POST', '/savequickreply', async (request) => this.core.saveQuickReply(request));
    this.server.route('POST', '/deletequickreply', async (request) => this.core.deleteQuickReply(request));

    this.server.route('POST', '/api/secrets/settings', async () => this.secrets.settings());
    this.server.route('POST', '/api/secrets/write', async (request) => this.secrets.write(request));
    this.server.route('POST', '/api/secrets/read', async () => this.secrets.read());
    this.server.route('POST', '/api/secrets/view', async () => this.secrets.view());
    this.server.route('POST', '/api/secrets/find', async (request) => this.secrets.find(request));
    this.server.route('POST', '/api/secrets/delete', async (request) => this.secrets.delete(request));
    this.server.route('POST', '/api/secrets/rotate', async (request) => this.secrets.rotate(request));
    this.server.route('POST', '/api/secrets/rename', async (request) => this.secrets.rename(request));

    this.server.route('POST', '/api/users/list', async () => this.users.listPublic());
    this.server.route('POST', '/api/users/login', async (request) => this.users.login(request));
    this.server.route('POST', '/api/users/recover-step1', async (request) => this.users.recoverStep1(request));
    this.server.route('POST', '/api/users/recover-step2', async (request) => this.users.recoverStep2(request));
    this.server.route('POST', '/api/users/logout', async () => this.users.logout());
    this.server.route('GET', '/api/users/me', async () => this.users.me());
    this.server.route('POST', '/api/users/get', async () => this.users.getAdmin());
    this.server.route('POST', '/api/users/enable', async (request) => this.users.enable(request));
    this.server.route('POST', '/api/users/disable', async (request) => this.users.disable(request));
    this.server.route('POST', '/api/users/promote', async (request) => this.users.promote(request));
    this.server.route('POST', '/api/users/demote', async (request) => this.users.demote(request));
    this.server.route('POST', '/api/users/create', async (request) => this.users.create(request));
    this.server.route('POST', '/api/users/delete', async (request) => this.users.delete(request));
    this.server.route('POST', '/api/users/slugify', async (request) => this.users.slugify(request));
    this.server.route('POST', '/api/users/change-avatar', async (request) => this.users.changeAvatar(request));
    this.server.route('POST', '/api/users/change-password', async (request) => this.users.changePassword(request));
    this.server.route('POST', '/api/users/backup', async (request) => await this.users.backup(request));
    this.server.route('POST', '/api/users/restore-data', async (request) => await this.users.restoreData(request));
    this.server.route('POST', '/api/users/restore-data-picker', async () => await this.users.restoreDataWithPicker());
    this.server.route('POST', '/api/users/reset-settings', async (request) => this.users.resetSettings(request));
    this.server.route('POST', '/api/users/change-name', async (request) => this.users.changeName(request));
    this.server.route('POST', '/api/users/reset-step1', async () => this.users.resetStep1());
    this.server.route('POST', '/api/users/reset-step2', async (request) => this.users.resetStep2(request));

    this.server.route('GET', '/api/extensions/discover', async () => this.extensions.discover());
    this.server.route('POST', '/api/extensions/discover', async () => this.extensions.discover());
    this.server.route('POST', '/api/extensions/install', async (request) => this.extensions.install(request));
    this.server.route('POST', '/api/extensions/update', async (request) => this.extensions.update(request));
    this.server.route('POST', '/api/extensions/branches', async (request) => this.extensions.branches(request));
    this.server.route('POST', '/api/extensions/switch', async (request) => this.extensions.switchBranch(request));
    this.server.route('POST', '/api/extensions/move', async (request) => this.extensions.move(request));
    this.server.route('POST', '/api/extensions/version', async (request) => this.extensions.version(request));
    this.server.route('POST', '/api/extensions/delete', async (request) => this.extensions.delete(request));

    this.registerTokenizerRoutes();
    this.registerModelProxyRoutes();
    this.registerVectorRoutes();
    this.server.route('POST', '/api/sd/comfy/workflows', async () => this.core.listComfyWorkflows());
    this.server.route('POST', '/api/sd/comfy/workflow', async (request) => this.core.getComfyWorkflow(request));

    this.server.fallback(async (request) => {
      if (request.method === 'POST' && request.path.startsWith('/api/images/list/')) {
        return this.media.listImages(request);
      }
      if (request.method === 'POST' && request.path.startsWith('/listimgfiles/')) {
        return this.media.listImages(request);
      }
      if (request.path.startsWith('/scripts/extensions/third-party/')) {
        return this.extensions.serveThirdPartyFile(request);
      }
      if (request.path.startsWith('/characters/') || request.path.startsWith('/User Avatars/') ||
        request.path.startsWith('/backgrounds/') || request.path.startsWith('/user/images/') ||
        request.path.startsWith('/user/files/') || request.path.startsWith('/assets/')) {
        return await this.media.getDataFile(request);
      }
      return this.staticFiles.serve(request);
    });
  }

  private prepareGitCaBundle(context: Context): string {
    const caBundlePath = joinPath(context.filesDir, '_certs', 'cacert.pem');
    try {
      this.store.writeBytes(caBundlePath, context.resourceManager.getRawFileContentSync('certs/cacert.pem'));
      return caBundlePath;
    } catch (_err) {
      return '';
    }
  }

  private syncShellThemeFromCurrentSettings(): void {
    const settings = this.store.readJsonRecord(joinPath(this.directories.defaultUser.root, 'settings.json'));
    this.syncShellThemeFromSettings(settings);
  }

  private syncShellThemeFromSettings(settings: JsonRecord): void {
    const powerUser = asRecord(settings['power_user']);
    const color = asString(powerUser['blur_tint_color']) || asString(powerUser['chat_tint_color']);
    if (color.length > 0) {
      this.shellTheme.updateBackgroundColor(color);
    }
  }

  private registerTokenizerRoutes(): void {
    const localTokenizers = ['gpt2', 'openai', 'llama', 'nerdstash', 'nerdstash_v2', 'mistral', 'yi', 'claude',
      'llama3', 'gemma', 'jamba', 'qwen2', 'command-r', 'command-a', 'nemo', 'deepseek'];
    this.server.route('POST', '/api/tokenizers/encode', async (request) => this.tokenizers.encode(request));
    for (const name of localTokenizers) {
      this.server.route('POST', `/api/tokenizers/${name}/encode`, async (request) => this.tokenizers.encode(request));
      this.server.route('POST', `/api/tokenizers/${name}/decode`, async (request) => this.tokenizers.decode(request));
    }
    this.server.route('POST', '/api/tokenizers/openai/count', async (request) => this.tokenizers.countOpenAi(request));
    this.server.route('POST', '/api/backends/chat-completions/bias', async (request) => this.tokenizers.bias(request));
    this.server.route('POST', '/api/tokenizers/remote/kobold/count',
      async (request) => await this.tokenizers.remoteKoboldCount(request));
    this.server.route('POST', '/api/tokenizers/remote/textgenerationwebui/encode',
      async (request) => await this.tokenizers.remoteTextGenEncode(request));
  }

  private registerModelProxyRoutes(): void {
    this.server.route('POST', '/api/backends/chat-completions/status',
      async (request) => await this.modelProxy.chatCompletionStatus(request));
    this.server.route('POST', '/api/backends/chat-completions/generate',
      async (request) => await this.modelProxy.chatCompletionsGenerate(request));
    this.server.route('POST', '/api/backends/chat-completions/cancel-stream',
      async (request) => await this.modelProxy.cancelChatCompletionStream(request));
    this.server.route('POST', '/api/backends/chat-completions/cancel-generation',
      async (request) => await this.modelProxy.cancelChatCompletionGeneration(request));
    this.server.route('POST', '/api/openai/generate', async (request) => await this.modelProxy.openAiGenerate(request));
    this.server.route('POST', '/api/backends/text-completions/status',
      async (request) => await this.modelProxy.textCompletionStatus(request));
    this.server.route('POST', '/api/backends/text-completions/generate',
      async (request) => await this.modelProxy.textCompletionGenerate(request));
    this.server.route('POST', '/api/novelai/status', async () => await this.modelProxy.novelStatus());
    this.server.route('POST', '/api/novelai/generate', async (request) => await this.modelProxy.novelGenerate(request));
    this.server.route('POST', '/api/horde/status', async () => await this.modelProxy.hordeStatus());
    this.server.route('POST', '/api/horde/text-models', async () => await this.modelProxy.hordeTextModels());
    this.server.route('POST', '/api/horde/text-workers', async () => await this.modelProxy.hordeTextWorkers());
    this.server.route('POST', '/api/horde/sd-models', async () => await this.modelProxy.hordeSdModels());
    this.server.route('POST', '/api/horde/generate-text',
      async (request) => await this.modelProxy.hordeGenerateText(request));
    this.server.route('POST', '/api/horde/task-status',
      async (request) => await this.modelProxy.hordeTaskStatus(request));
    this.server.route('POST', '/api/horde/cancel-task',
      async (request) => await this.modelProxy.hordeCancelTask(request));
    this.server.route('POST', '/api/horde/user-info', async () => await this.modelProxy.hordeUserInfo());
    this.server.route('POST', '/api/openai/models', async () => await this.modelProxy.openAiModelList('openai'));
    this.server.route('POST', '/api/openrouter/models', async () => await this.modelProxy.openAiModelList('openrouter'));
    this.server.route('GET', '/api/dev/llm-api-logs', async (request) => this.modelProxy.llmApiLogsIndex(request));
    this.server.route('POST', '/api/dev/llm-api-logs', async (request) => this.modelProxy.llmApiLogsIndex(request));
    this.server.route('GET', '/api/dev/llm-api-logs/preview',
      async (request) => this.modelProxy.llmApiLogPreview(request));
    this.server.route('POST', '/api/dev/llm-api-logs/preview',
      async (request) => this.modelProxy.llmApiLogPreview(request));
    this.server.route('GET', '/api/dev/llm-api-logs/raw', async (request) => this.modelProxy.llmApiLogRaw(request));
    this.server.route('POST', '/api/dev/llm-api-logs/raw', async (request) => this.modelProxy.llmApiLogRaw(request));
    this.server.route('GET', '/api/dev/llm-api-logs/settings',
      async (request) => this.modelProxy.llmApiLogsSettings(request));
    this.server.route('POST', '/api/dev/llm-api-logs/settings',
      async (request) => this.modelProxy.llmApiLogsSettings(request));
    this.server.route('GET', '/api/dev/llm-api-logs/keep',
      async (request) => this.modelProxy.llmApiLogsKeep(request));
    this.server.route('POST', '/api/dev/llm-api-logs/keep',
      async (request) => this.modelProxy.llmApiLogsKeep(request));
    this.server.route('GET', '/api/dev/llm-api-logs/stream-enabled',
      async (request) => this.modelProxy.llmApiLogsStreamEnabled(request));
    this.server.route('POST', '/api/dev/llm-api-logs/stream-enabled',
      async (request) => this.modelProxy.llmApiLogsStreamEnabled(request));
    this.server.route('GET', '/api/dev/llm-api-logs/stream',
      async (request) => this.modelProxy.llmApiLogsStream(request));
    this.server.route('POST', '/api/sd/ping', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/progress'));
    this.server.route('POST', '/api/sd/models', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/sd-models'));
    this.server.route('POST', '/api/sd/samplers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/samplers'));
    this.server.route('POST', '/api/sd/schedulers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/schedulers'));
    this.server.route('POST', '/api/sd/upscalers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/upscalers'));
    this.server.route('POST', '/api/sd/vaes', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/sd-vae'));
    this.server.route('POST', '/api/sd/generate',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/txt2img'));
  }

  private registerVectorRoutes(): void {
    this.server.route('POST', '/api/vector/insert', async (request) => await this.vectors.insert(request));
    this.server.route('POST', '/api/vector/list', async (request) => this.vectors.list(request));
    this.server.route('POST', '/api/vector/delete', async (request) => this.vectors.delete(request));
    this.server.route('POST', '/api/vector/query', async (request) => await this.vectors.query(request));
    this.server.route('POST', '/api/vector/query-multi', async (request) => await this.vectors.queryMulti(request));
    this.server.route('POST', '/api/vector/purge', async (request) => this.vectors.purge(request));
    this.server.route('POST', '/api/vector/purge-all', async () => this.vectors.purgeAll());
  }
}
