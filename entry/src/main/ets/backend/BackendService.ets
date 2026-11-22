import { common, Context } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { AppSettingsService, APP_SETTING_FORCE_HTTP1_1 } from './AppSettingsService';
import { BackgroundPrivacyService } from './BackgroundPrivacyService';
import { ChatBrowserService } from './ChatBrowserService';
import { CharacterBrowserService } from './CharacterBrowserService';
import { DataDirectories } from './DataDirectories';
import { CryptoUtils } from './CryptoUtils';
import { DiagnosticLogService } from './DiagnosticLogService';
import { DefaultContentSeeder } from './DefaultContentSeeder';
import { ExtensionsService } from './ExtensionsService';
import { FileEntry, FileStore } from './FileStore';
import { GitService } from './GitService';
import { HttpRequest, HttpResponse, JsonRecord } from './HttpTypes';
import { HttpRouter, LOCAL_BACKEND_ORIGIN } from './HttpRouter';
import { asArray, asBoolean, asNumber, asRecord, asString, bodyAsRecord, parseJsonRecord } from './JsonUtils';
import { LlmBackgroundTaskService } from './LlmBackgroundTaskService';
import { LocalBackend } from './LocalBackend';
import { MediaService } from './MediaService';
import { ModelProxyService } from './ModelProxyService';
import { ensurePngExtension, joinPath, sanitizeFileName, withoutExtension } from './PathUtils';
import { SecretsService } from './SecretsService';
import { ExportedFile, ShareExportService } from './ShareExportService';
import { ShellThemeService } from './ShellThemeService';
import { SillyTavernCore } from './SillyTavernCore';
import { StaticFileServer } from './StaticFileServer';
import { TokenizerService } from './TokenizerService';
import { UsersService } from './UsersService';
import { VectorService } from './VectorService';
import { WebSchemeTransport } from './WebSchemeTransport';

const DOMAIN = 0x5441;
const TAG = 'TavernBackendService';
const SETTINGS_SNAPSHOT_PREFIX = 'settings_default-user_';
const SETTINGS_SNAPSHOT_INTERVAL_MS = 24 * 60 * 60 * 1000;

class ChatStats {
  count: number = 0;
  preview: string = '';
}

export class BackendStatus {
  running: boolean;
  url: string;
  dataRoot: string;
  message: string;
  initDurationMs: number;
  startupDurationMs: number;

  constructor(running: boolean, url: string, dataRoot: string, message: string, initDurationMs: number = 0,
    startupDurationMs: number = 0) {
    this.running = running;
    this.url = url;
    this.dataRoot = dataRoot;
    this.message = message;
    this.initDurationMs = initDurationMs;
    this.startupDurationMs = startupDurationMs;
  }
}

export class BackendService {
  private static instance: BackendService | null = null;
  private router: HttpRouter;
  private webTransport: WebSchemeTransport;
  private started: boolean = false;
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
  private appSettings: AppSettingsService;
  private backgroundPrivacy: BackgroundPrivacyService;
  private chatBrowser: ChatBrowserService;
  private characterBrowser: CharacterBrowserService;
  private staticFiles: StaticFileServer;
  private lastMessage: string = 'Not started';
  private initDurationMs: number = 0;
  private startupDurationMs: number = 0;
  private frontendStartupReport: JsonRecord = {};
  private firstRunSettings: boolean = false;

  private constructor(context: Context) {
    const initStartedAt = Date.now();
    const tempRoot = joinPath(context.filesDir, '_tmp');
    this.store = new FileStore(tempRoot);
    this.store.deleteDirectory(tempRoot);
    this.crypto = new CryptoUtils();
    this.directories = new DataDirectories(context.filesDir, this.store);
    let stepStartedAt = Date.now();
    this.directories.initialize();
    this.logStartupStep('DataDirectories.initialize', stepStartedAt);
    stepStartedAt = Date.now();
    new DefaultContentSeeder(this.store, this.directories, context.resourceManager).seedDefaultUser();
    this.logStartupStep('DefaultContentSeeder.seedDefaultUser', stepStartedAt);
    stepStartedAt = Date.now();
    this.directories.ensureDefaultUserFiles();
    this.logStartupStep('DataDirectories.ensureDefaultUserFiles', stepStartedAt);
    stepStartedAt = Date.now();
    this.repairSettingsFile(context.resourceManager);
    this.logStartupStep('settingsFile.repair', stepStartedAt);
    this.appSettings = AppSettingsService.getInstance(context.filesDir);
    this.shellTheme = ShellThemeService.getInstance(context);
    stepStartedAt = Date.now();
    this.syncShellThemeFromCurrentSettings();
    this.logStartupStep('syncShellThemeFromCurrentSettings', stepStartedAt);
    this.shareExports = new ShareExportService(context as common.UIAbilityContext, this.store, this.directories.exportRoot);
    DiagnosticLogService.setShareExportService(this.shareExports);
    this.core = new SillyTavernCore(this.store, this.directories, this.shareExports, context.resourceManager,
      (settings: JsonRecord) => this.syncShellThemeFromSettings(settings));
    this.media = new MediaService(this.store, this.directories, this.crypto);
    this.secrets = new SecretsService(this.store, this.directories.defaultUser, this.crypto);
    stepStartedAt = Date.now();
    this.git = new GitService(this.store, this.prepareGitCaBundle(context));
    this.logStartupStep('GitService.prepareGitCaBundle', stepStartedAt);
    this.users = new UsersService(this.store, this.directories, this.crypto, this.shareExports,
      context as common.UIAbilityContext, this.git, context.resourceManager);
    this.extensions = new ExtensionsService(this.store, this.directories, context.resourceManager, this.git);
    this.backgroundPrivacy = new BackgroundPrivacyService(context.filesDir);
    this.llmBackgroundTasks = new LlmBackgroundTaskService(context as common.UIAbilityContext);
    this.modelProxy = new ModelProxyService(this.directories, this.secrets, this.llmBackgroundTasks);
    this.tokenizers = new TokenizerService();
    this.vectors = new VectorService(this.store, this.directories, this.secrets);
    this.chatBrowser = new ChatBrowserService(this.store, this.directories);
    this.characterBrowser = new CharacterBrowserService(this.store, this.directories,
      () => this.core.listCharactersAsync(), () => this.media.ensureCharacterBrowserThumbnailsAsync());
    this.staticFiles = new StaticFileServer(context.resourceManager, () => this.shellTheme.getBackgroundColor());
    this.router = new HttpRouter();
    this.webTransport = new WebSchemeTransport(this.router);
    LocalBackend.configure(
      (method: string, rawUrl: string, headers: Record<string, string>, body: Uint8Array): Promise<HttpResponse> =>
        this.router.dispatch(method, rawUrl, headers, body),
      (avatar: string): string => joinPath(this.directories.defaultUser.characters, sanitizeFileName(avatar)),
      (avatar: string): string => this.media.characterBrowserThumbnailPath(avatar));
    stepStartedAt = Date.now();
    this.registerRoutes();
    this.logStartupStep('registerRoutes', stepStartedAt);
    this.initDurationMs = Date.now() - initStartedAt;
    DiagnosticLogService.info(DOMAIN, TAG, 'Backend init finished in %{public}d ms', this.initDurationMs);
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

  getCharacterBrowser(): CharacterBrowserService {
    return this.characterBrowser;
  }
  getBackgroundPrivacy(): BackgroundPrivacyService {
    return this.backgroundPrivacy;
  }

  isFirstRunSettings(): boolean {
    return this.firstRunSettings;
  }


  prepareWebDownload(fileName: string, contentType: string): ExportedFile {
    return this.shareExports.webDownloadFileReference(fileName, contentType);
  }

  async shareWebDownload(file: ExportedFile): Promise<void> {
    await this.shareExports.share(file, file.fileName);
  }

  discardWebDownload(file: ExportedFile): void {
    this.shareExports.discard(file);
  }

  // Routes requests from this WebView to the backend. Call from the Web component's onControllerAttached.
  attachWebView(controller: webview.WebviewController): void {
    this.webTransport.attach(controller);
  }

  async start(): Promise<BackendStatus> {
    if (this.started) {
      return this.status();
    }
    this.started = true;
    this.startupDurationMs = this.initDurationMs;
    this.lastMessage = `ArkTS backend is ready. init=${this.initDurationMs}ms.`;
    DiagnosticLogService.info(DOMAIN, TAG, 'Backend startup finished: init=%{public}d ms', this.initDurationMs);
    setTimeout(() => {
      this.characterBrowser.initializeCacheAsync().catch((_err: Error) => {
        DiagnosticLogService.error(DOMAIN, TAG, 'Character browser cache warmup failed');
      });
    }, 500);
    return this.status();
  }

  status(): BackendStatus {
    return new BackendStatus(this.started, LOCAL_BACKEND_ORIGIN, this.directories.dataRoot, this.lastMessage,
      this.initDurationMs, this.startupDurationMs);
  }

  hasFrontendInitializedBetween(startedAtMs: number, deadlineMs: number): boolean {
    const initializedAtMs = asNumber(this.frontendStartupReport['initializedAtMs']);
    return initializedAtMs >= startedAtMs && initializedAtMs <= deadlineMs;
  }

  beginFrontendStartupMonitoring(): void {
    this.frontendStartupReport = {};
  }

  private async createCharacter(request: HttpRequest): Promise<HttpResponse> {
    try {
      const avatarImage = await this.media.processCharacterAvatarUpload(request);
      const response = this.core.createCharacter(request, avatarImage);
      if (response.statusCode === 200) {
        const internalPng = response.body.trim();
        if (internalPng.endsWith('.png')) {
          const body = bodyAsRecord(request);
          const chName = asString(body['ch_name']);
          this.chatBrowser.setCharacterName(internalPng, chName.length > 0 ? chName : withoutExtension(internalPng));
        }
        this.characterBrowser.scheduleRefresh();
      }
      return response;
    } catch (_err) {
      return HttpResponse.text('Is not a valid image', 400);
    }
  }

  private async editCharacter(request: HttpRequest): Promise<HttpResponse> {
    try {
      const avatarImage = await this.media.processCharacterAvatarUpload(request);
      const response = this.core.editCharacter(request, avatarImage);
      if (response.statusCode === 200) {
        const body = bodyAsRecord(request);
        const avatar = ensurePngExtension(sanitizeFileName(asString(body['avatar_url'])));
        const chName = asString(body['ch_name']) || asString(body['name']);
        this.chatBrowser.setCharacterName(avatar, chName.length > 0 ? chName : withoutExtension(avatar));
        this.characterBrowser.scheduleRefresh();
      }
      return response;
    } catch (_err) {
      return HttpResponse.text('Is not a valid image', 400);
    }
  }

  private async editCharacterAvatar(request: HttpRequest): Promise<HttpResponse> {
    try {
      const avatarImage = await this.media.processCharacterAvatarUpload(request);
      const response = this.core.editCharacterAvatar(request, avatarImage);
      if (response.statusCode === 200) {
        this.characterBrowser.scheduleRefresh();
      }
      return response;
    } catch (_err) {
      return HttpResponse.text('Is not a valid image', 400);
    }
  }

  private hookSaveChat(request: HttpRequest): HttpResponse {
    const response = this.core.saveChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const stats = this.chatStatsFromBody(body);
      this.chatBrowser.upsertCharacterChat(asString(body['avatar_url']), asString(body['file_name']), stats.count,
        stats.preview);
    }
    return response;
  }

  private hookDeleteChat(request: HttpRequest): HttpResponse {
    const response = this.core.deleteChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      this.chatBrowser.removeChatItemByFields('character', ensurePngExtension(sanitizeFileName(
        asString(body['avatar_url']))), '', asString(body['chatfile']));
    }
    return response;
  }

  private hookRenameChat(request: HttpRequest): HttpResponse {
    const response = this.core.renameChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const isGroup = body['is_group'] === true;
      this.chatBrowser.renameChatItem(isGroup ? 'group' : 'character',
        ensurePngExtension(sanitizeFileName(asString(body['avatar_url']))), '',
        asString(body['original_file']), asString(body['renamed_file']));
    }
    return response;
  }

  private hookImportChat(request: HttpRequest): HttpResponse {
    const response = this.core.importChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      this.chatBrowser.rescanCharacterChats(asString(body['avatar_url']));
    }
    return response;
  }

  private hookSaveGroupChat(request: HttpRequest): HttpResponse {
    const response = this.core.saveGroupChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const stats = this.chatStatsFromBody(body);
      this.chatBrowser.upsertGroupChat(asString(body['id']), stats.count, stats.preview);
    }
    return response;
  }

  private hookDeleteGroupChat(request: HttpRequest): HttpResponse {
    const response = this.core.deleteGroupChat(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const id = asString(body['id']);
      this.chatBrowser.removeChatItemByFields('group', '', '', `${id}.jsonl`);
    }
    return response;
  }

  private hookImportGroupChat(request: HttpRequest): HttpResponse {
    const response = this.core.importGroupChat(request);
    if (response.statusCode === 200) {
      const chatId = parseJsonRecord(response.body)['res'];
      if (typeof chatId === 'string' && chatId.length > 0) {
        this.chatBrowser.rescanChatItem('orphan_group', '', '', chatId);
      }
    }
    return response;
  }

  private hookEditCharacterAttribute(request: HttpRequest): HttpResponse {
    const response = this.core.editCharacterAttribute(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const chName = asString(body['ch_name']);
      if (chName.length > 0) {
        this.chatBrowser.setCharacterName(ensurePngExtension(sanitizeFileName(asString(body['avatar_url']))), chName);
      }
      this.characterBrowser.scheduleRefresh();
    }
    return response;
  }

  private hookMergeCharacterAttributes(request: HttpRequest): HttpResponse {
    const response = this.core.mergeCharacterAttributes(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const avatar = asString(body['avatar']) || asString(body['avatar_url']);
      const data = asRecord(body['data']);
      const name = asString(body['name']) || asString(data['name']);
      if (avatar.length > 0 && name.length > 0) {
        this.chatBrowser.setCharacterName(ensurePngExtension(sanitizeFileName(avatar)), name);
      }
      const extensions = asRecord(data['extensions']);
      const favoriteOnly = body['fav'] !== undefined &&
        Object.keys(body).every((key: string): boolean => key === 'avatar' || key === 'avatar_url' ||
          key === 'fav' || key === 'data') &&
        Object.keys(data).every((key: string): boolean => key === 'extensions') &&
        Object.keys(extensions).every((key: string): boolean => key === 'fav');
      if (favoriteOnly) {
        this.characterBrowser.updateFavoriteCache(ensurePngExtension(sanitizeFileName(avatar)), asBoolean(body['fav']));
      } else {
        this.characterBrowser.scheduleRefresh();
      }
    }
    return response;
  }

  private async setCharacterFavoriteAsync(request: HttpRequest): Promise<HttpResponse> {
    const response = await this.core.setCharacterFavoriteAsync(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const avatar = ensurePngExtension(sanitizeFileName(asString(body['avatar'])));
      this.characterBrowser.updateFavoriteCache(avatar, asBoolean(body['favorite']));
    }
    return response;
  }

  private hookDuplicateCharacter(request: HttpRequest): HttpResponse {
    const response = this.core.duplicateCharacter(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const target = asString(parseJsonRecord(response.body)['path']);
      const source = ensurePngExtension(sanitizeFileName(asString(body['avatar_url'])));
      if (target.length > 0 && source.length > 0) {
        this.chatBrowser.duplicateCharacterName(source, target);
      }
      this.characterBrowser.scheduleRefresh();
    }
    return response;
  }

  private hookRenameCharacter(request: HttpRequest): HttpResponse {
    const response = this.core.renameCharacter(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const newAvatar = asString(parseJsonRecord(response.body)['avatar']);
      const oldAvatar = ensurePngExtension(sanitizeFileName(asString(body['avatar_url'])));
      const newName = asString(body['new_name']);
      if (newAvatar.length > 0 && oldAvatar.length > 0 && newName.length > 0) {
        this.chatBrowser.renameCharacterChats(oldAvatar, newAvatar, newName);
      }
      this.characterBrowser.scheduleRefresh();
    }
    return response;
  }

  private hookDeleteCharacter(request: HttpRequest): HttpResponse {
    const response = this.core.deleteCharacter(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      const avatar = ensurePngExtension(sanitizeFileName(asString(body['avatar_url'])));
      this.chatBrowser.removeCharacterName(avatar);
      if (body['delete_chats'] === true) {
        this.chatBrowser.removeCharacterChats(avatar);
      } else {
        this.chatBrowser.orphanizeCharacterChats(avatar, withoutExtension(avatar));
      }
      this.characterBrowser.scheduleRefresh();
    }
    return response;
  }

  private hookImportCharacter(request: HttpRequest): HttpResponse {
    const response = this.core.importCharacter(request);
    if (response.statusCode === 200) {
      const file_name = parseJsonRecord(response.body)['file_name'];
      if (typeof file_name === 'string' && file_name.length > 0) {
        this.chatBrowser.rescanCharacterName(`${file_name}.png`);
      }
      this.characterBrowser.scheduleRefresh();
    }
    return response;
  }

  private hookCreateGroup(request: HttpRequest): HttpResponse {
    const response = this.core.createGroup(request);
    if (response.statusCode === 200) {
      const group = parseJsonRecord(response.body);
      this.chatBrowser.syncGroupChats(asString(group['id']), asString(group['name']), asArray(group['chats']));
    }
    return response;
  }

  private hookEditGroup(request: HttpRequest): HttpResponse {
    const response = this.core.editGroup(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      this.chatBrowser.syncGroupChats(asString(body['id']), asString(body['name']), asArray(body['chats']));
    }
    return response;
  }

  private hookDeleteGroup(request: HttpRequest): HttpResponse {
    const response = this.core.deleteGroup(request);
    if (response.statusCode === 200) {
      const body = bodyAsRecord(request);
      this.chatBrowser.removeGroupChats(asString(body['id']));
    }
    return response;
  }

  private chatStatsFromBody(body: JsonRecord): ChatStats {
    const stats = new ChatStats();
    const chat = asArray(body['chat']);
    stats.count = chat.length;
    if (stats.count > 0) {
      const last = chat[stats.count - 1];
      if (last !== null && typeof last === 'object' && !Array.isArray(last)) {
        stats.preview = asString((last as JsonRecord)['mes']);
      }
    }
    return stats;
  }

  private registerRoutes(): void {
    this.router.route('GET', '/', async (request) => this.staticFiles.serve(request));
    this.router.route('GET', '/health', async () => this.core.health());
    this.router.route('GET', '/api/ohos/backend/status', async () => HttpResponse.json(this.statusJson()));
    this.router.route('GET', '/api/ohos/startup/report', async () => HttpResponse.json(this.startupReportJson()));
    this.router.route('POST', '/api/ohos/startup/frontend', async (request) => this.receiveFrontendStartupReport(request));
    this.router.route('POST', '/api/ohos/diagnostics/frontend', async (request) => {
      return this.receiveFrontendDiagnosticLog(request);
    });
    this.router.route('GET', '/csrf-token', async () => this.core.csrfToken());
    this.router.route('GET', '/version', async () => this.core.version());
    this.router.route('GET', '/thumbnail', async (request) => await this.media.getDataFile(request));
    this.router.route('GET', '/api/ohos/characters/thumbnail',
      async (request) => this.media.characterBrowserThumbnail(request));
    this.router.route('POST', '/api/ohos/shell-theme/background',
      async (request) => this.shellTheme.reportBackground(request));
    this.router.route('POST', '/api/ohos/chats/browser/open', async () => this.chatBrowser.openBrowser());
    this.router.route('POST', '/api/ohos/chats/browser/list', async (request) => this.chatBrowser.listResponse(request));
    this.router.route('POST', '/api/ohos/chats/browser/refresh', async () => this.chatBrowser.refreshResponse());
    this.router.route('POST', '/api/ohos/chats/browser/delete',
      async (request) => this.chatBrowser.deleteResponse(request));
    this.router.route('GET', '/api/ohos/notifications/preferences',
      async () => HttpResponse.json(this.llmBackgroundTasks.notificationPreferencesJson()));
    this.router.route('POST', '/api/ohos/notifications/preferences',
      async (request) => HttpResponse.json(await this.llmBackgroundTasks.updateNotifyOnCompleted(
        asBoolean(asRecord(request.body as Object | undefined)['enabled']))));
    this.router.route('POST', '/api/ohos/generation/prepare',
      async () => HttpResponse.json(await this.llmBackgroundTasks.beginGenerationPreparation()));
    this.router.route('POST', '/api/ohos/generation/prepare/finish',
      async (request) => HttpResponse.json(await this.llmBackgroundTasks.finishGenerationPreparation(
        asNumber(bodyAsRecord(request)['leaseId']))));
    this.router.route('GET', '/api/ohos/background-privacy/settings',
      async () => HttpResponse.json(this.backgroundPrivacy.settingsJson()));
    this.router.route('POST', '/api/ohos/background-privacy/settings',
      async (request) => HttpResponse.json(this.backgroundPrivacy.updateEnabled(
        asBoolean(bodyAsRecord(request)['enabled'], this.backgroundPrivacy.isEnabled()))));
    this.router.route('GET', '/api/ohos/settings', async () => HttpResponse.json(this.appSettings.settingsJson()));
    this.router.route('POST', '/api/ohos/settings', async (request) => {
      const body = bodyAsRecord(request);
      const forceHttp1_1 = body['forceHttp1_1'];
      if (typeof forceHttp1_1 === 'boolean') {
        this.appSettings.setBoolean(APP_SETTING_FORCE_HTTP1_1, forceHttp1_1);
      }
      return HttpResponse.json(this.appSettings.settingsJson());
    });


    this.router.route('POST', '/api/ping', async () => this.core.ping());

    this.router.route('POST', '/api/stats/get', async () => this.core.statsGet());
    this.router.route('POST', '/api/stats/update', async (request) => this.core.statsUpdate(request));
    this.router.route('POST', '/api/stats/recreate', async () => this.core.statsRecreate());

    this.router.route('POST', '/api/settings/get', async () => this.core.getSettings());
    this.router.route('POST', '/api/settings/save', async (request) => this.core.saveSettings(request));
    this.router.route('POST', '/api/settings/get-snapshots', async () => this.core.settingsSnapshots());
    this.router.route('POST', '/api/settings/load-snapshot', async (request) => this.core.loadSettingsSnapshot(request));
    this.router.route('POST', '/api/settings/make-snapshot', async () => this.core.makeSettingsSnapshot());
    this.router.route('POST', '/api/settings/restore-snapshot',
      async (request) => this.core.restoreSettingsSnapshot(request));
    this.router.route('POST', '/api/presets/save', async (request) => this.core.savePreset(request));
    this.router.route('POST', '/api/presets/delete', async (request) => this.core.deletePreset(request));
    this.router.route('POST', '/api/presets/restore', async (request) => this.core.restorePreset(request));
    this.router.route('POST', '/api/themes/save', async (request) => this.core.saveTheme(request));
    this.router.route('POST', '/api/themes/delete', async (request) => this.core.deleteTheme(request));
    this.router.route('POST', '/api/moving-ui/save', async (request) => this.core.saveMovingUi(request));
    this.router.route('POST', '/savetheme', async (request) => this.core.saveTheme(request));
    this.router.route('POST', '/savemovingui', async (request) => this.core.saveMovingUi(request));

    this.router.route('POST', '/api/characters/all', async () => this.core.listCharacters());
    this.router.route('POST', '/api/characters/get', async (request) => this.core.getCharacter(request));
    this.router.route('POST', '/api/characters/create', async (request) => await this.createCharacter(request));
    this.router.route('POST', '/api/characters/edit', async (request) => await this.editCharacter(request));
    this.router.route('POST', '/api/characters/edit-avatar', async (request) => await this.editCharacterAvatar(request));
    this.router.route('POST', '/api/characters/edit-attribute',
      async (request) => this.hookEditCharacterAttribute(request));
    this.router.route('POST', '/api/characters/merge-attributes',
      async (request) => this.hookMergeCharacterAttributes(request));
    this.router.route('POST', '/api/ohos/characters/favorite',
      async (request) => await this.setCharacterFavoriteAsync(request));
    this.router.route('POST', '/api/characters/duplicate', async (request) => this.hookDuplicateCharacter(request));
    this.router.route('POST', '/api/characters/rename', async (request) => this.hookRenameCharacter(request));
    this.router.route('POST', '/api/characters/delete', async (request) => this.hookDeleteCharacter(request));
    this.router.route('POST', '/api/characters/chats', async (request) => this.core.listCharacterChats(request));
    this.router.route('POST', '/api/characters/import', async (request) => this.hookImportCharacter(request));
    this.router.route('POST', '/api/characters/export', async (request) => await this.core.exportCharacter(request));

    this.router.route('POST', '/api/chats/get', async (request) => this.core.getChat(request));
    this.router.route('POST', '/api/chats/save', async (request) => this.hookSaveChat(request));
    this.router.route('POST', '/api/chats/delete', async (request) => this.hookDeleteChat(request));
    this.router.route('POST', '/api/chats/rename', async (request) => this.hookRenameChat(request));
    this.router.route('POST', '/api/chats/import', async (request) => this.hookImportChat(request));
    this.router.route('POST', '/api/chats/export', async (request) => await this.core.exportChat(request));
    this.router.route('POST', '/api/chats/search', async (request) => this.core.searchChats(request));
    this.router.route('POST', '/api/chats/group/get', async (request) => this.core.getGroupChat(request));
    this.router.route('POST', '/api/chats/group/save', async (request) => this.hookSaveGroupChat(request));
    this.router.route('POST', '/api/chats/group/delete', async (request) => this.hookDeleteGroupChat(request));
    this.router.route('POST', '/api/chats/group/import', async (request) => this.hookImportGroupChat(request));
    this.router.route('POST', '/api/chats/group/info', async (request) => this.core.groupChatInfo(request));
    this.router.route('POST', '/api/chats/recent', async (request) => this.core.recentChats(request));
    this.router.route('POST', '/api/backups/chat/get', async () => this.core.chatBackups());
    this.router.route('POST', '/api/backups/chat/download', async (request) => this.core.downloadChatBackup(request));
    this.router.route('POST', '/api/backups/chat/delete', async (request) => this.core.deleteChatBackup(request));

    this.router.route('POST', '/api/worldinfo/list', async () => this.core.listWorlds());
    this.router.route('POST', '/api/worldinfo/get', async (request) => this.core.getWorld(request));
    this.router.route('POST', '/api/worldinfo/edit', async (request) => this.core.editWorld(request));
    this.router.route('POST', '/api/worldinfo/import', async (request) => this.core.importWorld(request));
    this.router.route('POST', '/api/worldinfo/export', async (request) => await this.core.exportWorld(request));
    this.router.route('POST', '/api/worldinfo/delete', async (request) => this.core.deleteWorld(request));
    this.router.route('POST', '/importworldinfo', async (request) => this.core.importWorld(request));

    this.router.route('POST', '/api/groups/all', async () => this.core.listGroups());
    this.router.route('POST', '/api/groups/create', async (request) => this.hookCreateGroup(request));
    this.router.route('POST', '/api/groups/edit', async (request) => this.hookEditGroup(request));
    this.router.route('POST', '/api/groups/delete', async (request) => this.hookDeleteGroup(request));

    this.router.route('POST', '/api/backgrounds/all', async () => await this.media.listBackgrounds());
    this.router.route('POST', '/api/backgrounds/folders', async () => this.media.listBackgroundFolders());
    this.router.route('POST', '/api/backgrounds/delete', async (request) => this.media.deleteBackground(request));
    this.router.route('POST', '/api/backgrounds/rename', async (request) => await this.media.renameBackground(request));
    this.router.route('POST', '/api/backgrounds/upload', async (request) => await this.media.uploadBackground(request));
    this.router.route('POST', '/getbackgrounds', async () => await this.media.listBackgrounds());
    this.router.route('POST', '/delbackground', async (request) => this.media.deleteBackground(request));
    this.router.route('POST', '/renamebackground', async (request) => await this.media.renameBackground(request));
    this.router.route('POST', '/downloadbackground', async (request) => await this.media.uploadBackground(request));

    this.router.route('POST', '/api/avatars/get', async () => this.media.listAvatars());
    this.router.route('POST', '/api/avatars/delete', async (request) => this.media.deleteAvatar(request));
    this.router.route('POST', '/api/avatars/upload', async (request) => await this.media.uploadAvatar(request));
    this.router.route('POST', '/getuseravatars', async () => this.media.listAvatars());
    this.router.route('POST', '/deleteuseravatar', async (request) => this.media.deleteAvatar(request));
    this.router.route('POST', '/uploaduseravatar', async (request) => await this.media.uploadAvatar(request));

    this.router.route('POST', '/api/images/upload', async (request) => await this.media.uploadImage(request));
    this.router.route('POST', '/api/images/list', async (request) => this.media.listImages(request));
    this.router.route('POST', '/api/images/folders', async () => this.media.imageFolders());
    this.router.route('POST', '/api/images/delete', async (request) => this.media.deleteImage(request));
    this.router.route('POST', '/uploadimage', async (request) => await this.media.uploadImage(request));
    this.router.route('POST', '/listimgfiles', async (request) => this.media.listImages(request));

    this.router.route('POST', '/api/files/sanitize-filename',
      async (request) => this.media.sanitizeUploadedFileName(request));
    this.router.route('POST', '/api/files/upload', async (request) => this.media.uploadFile(request));
    this.router.route('POST', '/api/files/delete', async (request) => this.media.deleteFile(request));
    this.router.route('POST', '/api/files/verify', async (request) => this.media.verifyFiles(request));
    this.router.route('POST', '/api/assets/get', async () => this.media.assetsGet());
    this.router.route('POST', '/api/assets/download', async (request) => await this.media.assetsDownload(request));
    this.router.route('POST', '/api/assets/delete', async (request) => this.media.assetsDelete(request));
    this.router.route('POST', '/api/assets/character', async (request) => this.media.assetsCharacter(request));
    this.router.route('POST', '/api/content/importURL', async (request) => await this.media.contentImportUrl(request));
    this.router.route('POST', '/api/content/importUUID', async (request) => await this.media.contentImportUuid(request));
    this.router.route('POST', '/api/content/import', async (request) => await this.media.contentImportUrl(request));
    this.router.route('POST', '/api/content-manager/importURL',
      async (request) => await this.media.contentImportUrl(request));
    this.router.route('POST', '/api/content-manager/importUUID',
      async (request) => await this.media.contentImportUuid(request));

    this.router.route('GET', '/api/sprites/get', async (request) => this.media.spritesGet(request));
    this.router.route('POST', '/api/sprites/delete', async (request) => this.media.spritesDelete(request));
    this.router.route('POST', '/api/sprites/upload', async (request) => this.media.spritesUpload(request));
    this.router.route('POST', '/api/sprites/upload-zip', async (request) => await this.media.spritesUploadZip(request));

    this.router.route('POST', '/api/image-metadata/all', async (request) => this.media.imageMetadataAll(request));
    this.router.route('POST', '/api/image-metadata', async (request) => await this.media.imageMetadata(request));
    this.router.route('POST', '/api/image-metadata/folders/get',
      async () => this.media.imageMetadataFoldersGet());
    this.router.route('POST', '/api/image-metadata/folders/create',
      async (request) => this.media.imageMetadataFoldersCreate(request));
    this.router.route('POST', '/api/image-metadata/folders/update',
      async (request) => this.media.imageMetadataFoldersUpdate(request));
    this.router.route('POST', '/api/image-metadata/folders/delete',
      async (request) => this.media.imageMetadataFoldersDelete(request));
    this.router.route('POST', '/api/image-metadata/folders/set-thumbnails',
      async (request) => this.media.imageMetadataFoldersSetThumbnails(request));
    this.router.route('POST', '/api/image-metadata/folders/assign',
      async (request) => this.media.imageMetadataFoldersAssign(request));
    this.router.route('POST', '/api/image-metadata/folders/unassign',
      async (request) => this.media.imageMetadataFoldersUnassign(request));
    this.router.route('POST', '/api/image-metadata/cleanup', async () => this.media.imageMetadataCleanup());
    this.router.route('POST', '/api/quick-reply/save', async (request) => this.core.saveQuickReply(request));
    this.router.route('POST', '/api/quick-reply/delete', async (request) => this.core.deleteQuickReply(request));
    this.router.route('POST', '/api/quick-replies/save', async (request) => this.core.saveQuickReply(request));
    this.router.route('POST', '/api/quick-replies/delete', async (request) => this.core.deleteQuickReply(request));
    this.router.route('POST', '/savequickreply', async (request) => this.core.saveQuickReply(request));
    this.router.route('POST', '/deletequickreply', async (request) => this.core.deleteQuickReply(request));

    this.router.route('POST', '/api/secrets/settings', async () => this.secrets.settings());
    this.router.route('POST', '/api/secrets/write', async (request) => this.secrets.write(request));
    this.router.route('POST', '/api/secrets/read', async () => this.secrets.read());
    this.router.route('POST', '/api/secrets/view', async () => this.secrets.view());
    this.router.route('POST', '/api/secrets/find', async (request) => this.secrets.find(request));
    this.router.route('POST', '/api/secrets/delete', async (request) => this.secrets.delete(request));
    this.router.route('POST', '/api/secrets/rotate', async (request) => this.secrets.rotate(request));
    this.router.route('POST', '/api/secrets/rename', async (request) => this.secrets.rename(request));

    this.router.route('POST', '/api/users/list', async () => this.users.listPublic());
    this.router.route('POST', '/api/users/login', async (request) => this.users.login(request));
    this.router.route('POST', '/api/users/recover-step1', async (request) => this.users.recoverStep1(request));
    this.router.route('POST', '/api/users/recover-step2', async (request) => this.users.recoverStep2(request));
    this.router.route('POST', '/api/users/logout', async () => this.users.logout());
    this.router.route('GET', '/api/users/me', async () => this.users.me());
    this.router.route('POST', '/api/users/get', async () => this.users.getAdmin());
    this.router.route('POST', '/api/users/enable', async (request) => this.users.enable(request));
    this.router.route('POST', '/api/users/disable', async (request) => this.users.disable(request));
    this.router.route('POST', '/api/users/promote', async (request) => this.users.promote(request));
    this.router.route('POST', '/api/users/demote', async (request) => this.users.demote(request));
    this.router.route('POST', '/api/users/create', async (request) => this.users.create(request));
    this.router.route('POST', '/api/users/delete', async (request) => this.users.delete(request));
    this.router.route('POST', '/api/users/slugify', async (request) => this.users.slugify(request));
    this.router.route('POST', '/api/users/change-avatar', async (request) => this.users.changeAvatar(request));
    this.router.route('POST', '/api/users/change-password', async (request) => this.users.changePassword(request));
    this.router.route('POST', '/api/users/backup', async (request) => await this.users.backup(request));
    this.router.route('POST', '/api/users/restore-data', async (request) => await this.users.restoreData(request));
    this.router.route('POST', '/api/users/restore-data-picker',
      async (request) => await this.users.restoreDataWithPicker(request));
    this.router.route('POST', '/api/users/reset-settings', async (request) => this.users.resetSettings(request));
    this.router.route('POST', '/api/users/change-name', async (request) => this.users.changeName(request));
    this.router.route('POST', '/api/users/reset-step1', async () => this.users.resetStep1());
    this.router.route('POST', '/api/users/reset-step2', async (request) => this.users.resetStep2(request));

    this.router.route('GET', '/api/extensions/discover', async () => this.extensions.discover());
    this.router.route('POST', '/api/extensions/discover', async () => this.extensions.discover());
    this.router.route('POST', '/api/extensions/install', async (request) => this.extensions.install(request));
    this.router.route('POST', '/api/extensions/update', async (request) => this.extensions.update(request));
    this.router.route('POST', '/api/extensions/branches', async (request) => this.extensions.branches(request));
    this.router.route('POST', '/api/extensions/switch', async (request) => this.extensions.switchBranch(request));
    this.router.route('POST', '/api/extensions/move', async (request) => this.extensions.move(request));
    this.router.route('POST', '/api/extensions/version', async (request) => this.extensions.version(request));
    this.router.route('POST', '/api/extensions/delete', async (request) => this.extensions.delete(request));
    this.router.route('POST', '/api/extensions/repair-git',
      async () => await this.users.repairExtensionGitRepositories());

    this.registerTokenizerRoutes();
    this.registerModelProxyRoutes();
    this.registerVectorRoutes();
    this.router.route('POST', '/api/sd/comfy/workflows', async () => this.core.listComfyWorkflows());
    this.router.route('POST', '/api/sd/comfy/workflow', async (request) => this.core.getComfyWorkflow(request));

    this.router.fallback(async (request) => {
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

  private repairSettingsFile(manager: resourceManager.ResourceManager): void {
    const settingsPath = joinPath(this.directories.defaultUser.root, 'settings.json');
    if (!this.store.exists(settingsPath)) {
      return;
    }
    const text = this.store.readText(settingsPath, '');
    if (this.isValidSettingsText(text)) {
      this.firstRunSettings = this.isFirstRunSettingsText(text);
      this.maybeCreateAutomaticSettingsSnapshot(text);
      return;
    }

    DiagnosticLogService.error(DOMAIN, TAG,
      'settings.json is not valid JSON, attempting automatic recovery');
    const backups = this.directories.defaultUser.backups;
    const preservedPath = joinPath(backups, `settings_corrupt_default-user_${this.compactTimestamp()}.json`);
    if (!this.store.moveFile(settingsPath, preservedPath)) {
      this.store.copyFile(settingsPath, preservedPath);
      this.store.deleteFile(settingsPath);
    }

    if (this.restoreNewestValidSettingsSnapshot(settingsPath, backups)) {
      this.firstRunSettings = this.isFirstRunSettingsText(this.store.readText(settingsPath, ''));
      DiagnosticLogService.info(DOMAIN, TAG, 'settings.json recovered from the newest valid snapshot');
      return;
    }
    const bundledDefaults = this.readBundledDefaultSettings(manager);
    if (this.isValidSettingsText(bundledDefaults)) {
      this.store.writeText(settingsPath, bundledDefaults);
      this.firstRunSettings = this.isFirstRunSettingsText(bundledDefaults);
      DiagnosticLogService.info(DOMAIN, TAG,
        'settings.json recovered from bundled default settings because no valid snapshot exists');
      return;
    }
    this.store.writeText(settingsPath, '{}');
    DiagnosticLogService.error(DOMAIN, TAG,
      'settings.json recovery finished without bundled defaults, empty settings will be used');
  }

  private readBundledDefaultSettings(manager: resourceManager.ResourceManager): string {
    try {
      const bytes = manager.getRawFileContentSync('default/content/settings.json');
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (_err) {
      return '';
    }
  }

  private restoreNewestValidSettingsSnapshot(settingsPath: string, backups: string): boolean {
    const candidates = this.store.list(backups)
      .filter((entry: FileEntry): boolean => entry.isFile && entry.name.startsWith(SETTINGS_SNAPSHOT_PREFIX) &&
        entry.name.endsWith('.json'))
      .sort((left: FileEntry, right: FileEntry): number => right.mtimeMs - left.mtimeMs);
    for (const candidate of candidates) {
      const text = this.store.readText(candidate.path, '');
      if (this.isValidSettingsText(text)) {
        this.store.writeText(settingsPath, text);
        return true;
      }
    }
    return false;
  }

  private maybeCreateAutomaticSettingsSnapshot(text: string): void {
    const trimmed = text.trim();
    if (trimmed.length === 0 || trimmed === '{}') {
      return;
    }
    const backups = this.directories.defaultUser.backups;
    let newestMs = 0;
    for (const entry of this.store.list(backups)) {
      if (entry.isFile && entry.name.startsWith(SETTINGS_SNAPSHOT_PREFIX) && entry.name.endsWith('.json') &&
        entry.mtimeMs > newestMs) {
        newestMs = entry.mtimeMs;
      }
    }
    if (newestMs > 0 && Date.now() - newestMs < SETTINGS_SNAPSHOT_INTERVAL_MS) {
      return;
    }
    const target = joinPath(backups, `${SETTINGS_SNAPSHOT_PREFIX}${this.compactTimestamp()}.json`);
    this.store.writeText(target, text);
    this.pruneSettingsSnapshots(50);
    DiagnosticLogService.info(DOMAIN, TAG, 'Created automatic settings snapshot');
  }

  private pruneSettingsSnapshots(limit: number): void {
    const files = this.store.list(this.directories.defaultUser.backups)
      .filter((entry: FileEntry): boolean => entry.isFile && entry.name.startsWith(SETTINGS_SNAPSHOT_PREFIX) &&
        entry.name.endsWith('.json'))
      .sort((left: FileEntry, right: FileEntry): number => left.mtimeMs - right.mtimeMs);
    while (files.length > limit) {
      const oldest = files.shift();
      if (oldest === undefined) {
        break;
      }
      this.store.deleteFile(oldest.path);
    }
  }

  private isValidSettingsText(text: string): boolean {
    if (text.trim().length === 0) {
      return false;
    }
    try {
      const parsed = JSON.parse(text) as Object;
      return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);
    } catch (_err) {
      return false;
    }
  }

  private isFirstRunSettingsText(text: string): boolean {
    try {
      const parsed = JSON.parse(text) as JsonRecord;
      return parsed['firstRun'] === true;
    } catch (_err) {
      return false;
    }
  }

  private compactTimestamp(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
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
    this.router.route('POST', '/api/tokenizers/encode', async (request) => this.tokenizers.encode(request));
    for (const name of localTokenizers) {
      this.router.route('POST', `/api/tokenizers/${name}/encode`, async (request) => this.tokenizers.encode(request));
      this.router.route('POST', `/api/tokenizers/${name}/decode`, async (request) => this.tokenizers.decode(request));
    }
    this.router.route('POST', '/api/tokenizers/openai/count', async (request) => this.tokenizers.countOpenAi(request));
    this.router.route('POST', '/api/backends/chat-completions/bias', async (request) => this.tokenizers.bias(request));
    this.router.route('POST', '/api/tokenizers/remote/kobold/count',
      async (request) => await this.tokenizers.remoteKoboldCount(request));
    this.router.route('POST', '/api/tokenizers/remote/textgenerationwebui/encode',
      async (request) => await this.tokenizers.remoteTextGenEncode(request));
  }

  private registerModelProxyRoutes(): void {
    this.router.route('POST', '/api/backends/chat-completions/status',
      async (request) => await this.modelProxy.chatCompletionStatus(request));
    this.router.route('POST', '/api/backends/chat-completions/generate',
      async (request) => await this.modelProxy.chatCompletionsGenerate(request));
    this.router.route('POST', '/api/backends/chat-completions/generate-batch-stream',
      async (request) => await this.modelProxy.chatCompletionsGenerateBatchStream(request));
    this.router.route('POST', '/api/backends/chat-completions/cancel-stream',
      async (request) => await this.modelProxy.cancelChatCompletionStream(request));
    this.router.route('POST', '/api/backends/chat-completions/cancel-generation',
      async (request) => await this.modelProxy.cancelChatCompletionGeneration(request));
    this.router.route('POST', '/api/openai/generate', async (request) => await this.modelProxy.openAiGenerate(request));
    this.router.route('POST', '/api/backends/text-completions/status',
      async (request) => await this.modelProxy.textCompletionStatus(request));
    this.router.route('POST', '/api/backends/text-completions/generate',
      async (request) => await this.modelProxy.textCompletionGenerate(request));
    this.router.route('POST', '/api/novelai/status', async () => await this.modelProxy.novelStatus());
    this.router.route('POST', '/api/novelai/generate', async (request) => await this.modelProxy.novelGenerate(request));
    this.router.route('POST', '/api/horde/status', async () => await this.modelProxy.hordeStatus());
    this.router.route('POST', '/api/horde/text-models', async () => await this.modelProxy.hordeTextModels());
    this.router.route('POST', '/api/horde/text-workers', async () => await this.modelProxy.hordeTextWorkers());
    this.router.route('POST', '/api/horde/sd-models', async () => await this.modelProxy.hordeSdModels());
    this.router.route('POST', '/api/horde/generate-text',
      async (request) => await this.modelProxy.hordeGenerateText(request));
    this.router.route('POST', '/api/horde/task-status',
      async (request) => await this.modelProxy.hordeTaskStatus(request));
    this.router.route('POST', '/api/horde/cancel-task',
      async (request) => await this.modelProxy.hordeCancelTask(request));
    this.router.route('POST', '/api/horde/user-info', async () => await this.modelProxy.hordeUserInfo());
    this.router.route('POST', '/api/openai/models', async () => await this.modelProxy.openAiModelList('openai'));
    this.router.route('POST', '/api/openrouter/models', async () => await this.modelProxy.openAiModelList('openrouter'));
    this.router.route('GET', '/api/dev/llm-api-logs', async (request) => this.modelProxy.llmApiLogsIndex(request));
    this.router.route('POST', '/api/dev/llm-api-logs', async (request) => this.modelProxy.llmApiLogsIndex(request));
    this.router.route('GET', '/api/dev/llm-api-logs/preview',
      async (request) => this.modelProxy.llmApiLogPreview(request));
    this.router.route('POST', '/api/dev/llm-api-logs/preview',
      async (request) => this.modelProxy.llmApiLogPreview(request));
    this.router.route('GET', '/api/dev/llm-api-logs/raw', async (request) => this.modelProxy.llmApiLogRaw(request));
    this.router.route('POST', '/api/dev/llm-api-logs/raw', async (request) => this.modelProxy.llmApiLogRaw(request));
    this.router.route('GET', '/api/dev/llm-api-logs/settings',
      async (request) => this.modelProxy.llmApiLogsSettings(request));
    this.router.route('POST', '/api/dev/llm-api-logs/settings',
      async (request) => this.modelProxy.llmApiLogsSettings(request));
    this.router.route('GET', '/api/dev/llm-api-logs/keep',
      async (request) => this.modelProxy.llmApiLogsKeep(request));
    this.router.route('POST', '/api/dev/llm-api-logs/keep',
      async (request) => this.modelProxy.llmApiLogsKeep(request));
    this.router.route('GET', '/api/dev/llm-api-logs/stream-enabled',
      async (request) => this.modelProxy.llmApiLogsStreamEnabled(request));
    this.router.route('POST', '/api/dev/llm-api-logs/stream-enabled',
      async (request) => this.modelProxy.llmApiLogsStreamEnabled(request));
    this.router.route('GET', '/api/dev/llm-api-logs/stream',
      async (request) => this.modelProxy.llmApiLogsStream(request));
    this.router.route('POST', '/api/sd/ping', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/progress'));
    this.router.route('POST', '/api/sd/models', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/sd-models'));
    this.router.route('POST', '/api/sd/samplers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/samplers'));
    this.router.route('POST', '/api/sd/schedulers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/schedulers'));
    this.router.route('POST', '/api/sd/upscalers',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/upscalers'));
    this.router.route('POST', '/api/sd/vaes', async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/sd-vae'));
    this.router.route('POST', '/api/sd/generate',
      async (request) => await this.modelProxy.sdProxy(request, '/sdapi/v1/txt2img'));
  }

  private registerVectorRoutes(): void {
    this.router.route('POST', '/api/vector/insert', async (request) => await this.vectors.insert(request));
    this.router.route('POST', '/api/vector/list', async (request) => this.vectors.list(request));
    this.router.route('POST', '/api/vector/delete', async (request) => this.vectors.delete(request));
    this.router.route('POST', '/api/vector/query', async (request) => await this.vectors.query(request));
    this.router.route('POST', '/api/vector/query-multi', async (request) => await this.vectors.queryMulti(request));
    this.router.route('POST', '/api/vector/purge', async (request) => this.vectors.purge(request));
    this.router.route('POST', '/api/vector/purge-all', async () => this.vectors.purgeAll());
  }

  private statusJson(): JsonRecord {
    const status = this.status();
    const value: JsonRecord = {};
    value['running'] = status.running;
    value['url'] = status.url;
    value['dataRoot'] = status.dataRoot;
    value['message'] = status.message;
    value['initDurationMs'] = status.initDurationMs;
    value['startupDurationMs'] = status.startupDurationMs;
    value['chatBrowserRefreshTimings'] = this.chatBrowser.refreshTimingsJson();
    return value;
  }

  private receiveFrontendStartupReport(request: HttpRequest): HttpResponse {
    const body = asRecord(request.body as Object | undefined);
    const report: JsonRecord = {};
    report['reportedAtMs'] = Date.now();
    report['initializedAtMs'] = asNumber(body['initializedAtMs']);
    report['totalDurationMs'] = asNumber(body['totalDurationMs']);
    report['steps'] = asArray(body['steps']);
    this.frontendStartupReport = report;
    if (asNumber(report['initializedAtMs']) > 0) {
      DiagnosticLogService.getInstance().markFrontendInitialized();
    }
    return HttpResponse.json(this.startupReportJson());
  }

  private receiveFrontendDiagnosticLog(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const level = asString(body['level']);
    const message = asString(body['message']);
    if (message.length > 0) {
      DiagnosticLogService.getInstance().appendWebLog(level, message);
    }
    return HttpResponse.empty();
  }

  private startupReportJson(): JsonRecord {
    const value: JsonRecord = {};
    value['backend'] = this.statusJson();
    value['httpRequests'] = this.router.requestTimingsJson();
    value['frontend'] = this.frontendStartupReport;
    return value;
  }

  private logStartupStep(label: string, startedAt: number): void {
    DiagnosticLogService.info(DOMAIN, TAG, '%{public}s took %{public}d ms', label, Date.now() - startedAt);
  }
}
