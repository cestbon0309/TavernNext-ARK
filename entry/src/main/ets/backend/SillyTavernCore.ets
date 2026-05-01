import { util } from '@kit.ArkTS';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord, jsonMessage } from './HttpTypes';
import {
  ensureJsonExtension,
  ensureJsonlExtension,
  ensurePngExtension,
  joinPath,
  sanitizeFileName,
  withoutExtension,
} from './PathUtils';
import { PngCardStore } from './PngCardStore';
import { ShareExportService } from './ShareExportService';

type JsonValue = Object | string | number | boolean | null | JsonArray;

class HealthResponse {
  ok: boolean = true;
  app: string = 'TavernNext OHOS ArkTS backend';
  compatibility: string = 'SillyTavern minimal local-data API';
  dataRoot: string;

  constructor(dataRoot: string) {
    this.dataRoot = dataRoot;
  }
}

class CsrfResponse {
  token: string = 'disabled';
}

class OkResponse {
  ok: boolean = true;
}

class ResultResponse {
  result: string;

  constructor(result: string) {
    this.result = result;
  }
}

class ErrorFlagResponse {
  error: boolean = true;
}

class SettingsResponse {
  settings: string = '{}';
  koboldai_settings: JsonArray = [];
  koboldai_setting_names: string[] = [];
  novelai_settings: JsonArray = [];
  novelai_setting_names: string[] = [];
  openai_settings: JsonArray = [];
  openai_setting_names: string[] = [];
  textgenerationwebui_presets: JsonArray = [];
  textgenerationwebui_preset_names: string[] = [];
  world_names: string[] = [];
  themes: JsonArray = [];
  movingUIPresets: JsonArray = [];
  quickReplyPresets: JsonArray = [];
  instruct: JsonArray = [];
  context: JsonArray = [];
  sysprompt: JsonArray = [];
  reasoning: JsonArray = [];
  enable_extensions: boolean = true;
  enable_extensions_auto_update: boolean = false;
  enable_accounts: boolean = false;
  request_compression: Object = emptyJsonRecord();
}

class VersionResponse {
  agent: string = 'TavernNext-OHOS';
  pkgVersion: string = '1.0.0-ohos';
  gitRevision: string = '';
  gitBranch: string = 'arkts-port';
  commitDate: string = '';
  isLatest: boolean = true;
}

class BackgroundImageResponse {
  filename: string;
  isAnimated: boolean = false;

  constructor(filename: string) {
    this.filename = filename;
  }
}

class BackgroundsResponse {
  images: BackgroundImageResponse[] = [];
  config: Object = emptyJsonRecord();
}

class BackgroundFoldersResponse {
  folders: JsonArray = [];
  imageFolderMap: Object = emptyJsonRecord();
}

class ImageMetadataAllResponse {
  version: number = 1;
  images: Object = emptyJsonRecord();
  folders: JsonArray = [];
}

class CharacterResponse {
  shallow: boolean = false;
  name: string = '';
  avatar: string = '';
  chat: string = '';
  fav: boolean = false;
  date_added: number = 0;
  create_date: string = '';
  date_last_chat: number = 0;
  chat_size: number = 0;
  data_size: number = 0;
  tags: JsonArray = [];
  data: Object = emptyJsonRecord();
  json_data: string = '';
  spec: string = '';
  spec_version: string = '';
  description: string = '';
  personality: string = '';
  scenario: string = '';
  first_mes: string = '';
  mes_example: string = '';
}

class ChatSummaryResponse {
  file_name: string = '';
  file_id: string = '';
  chat_items: number = 0;
  mes: string = '';
  last_mes: string = '';
  file_size: number = 0;
  date_last_chat: number = 0;
}

class SimpleChatResponse {
  file_name: string = '';
  file_id: string = '';
}

class RecentChatResponse {
  file_id: string = '';
  file_name: string = '';
  file_size: string = '';
  chat_items: number = 0;
  mes: string = '[The chat is empty]';
  last_mes: string = '';
  avatar: string = '';
  group: string = '';
  match: boolean = true;
}

class WorldListResponse {
  file_id: string = '';
  name: string = '';
  extensions: Object = emptyJsonRecord();
}

class GroupResponse {
  id: string = '';
  name: string = '';
  members: JsonArray = [];
  avatar_url: string = '';
  allow_self_responses: boolean = false;
  activation_strategy: number = 0;
  generation_mode: number = 0;
  disabled_members: JsonArray = [];
  fav: boolean = false;
  chat_id: string = '';
  chats: JsonArray = [];
  auto_mode_delay: number = 5;
  generation_mode_join_prefix: string = '';
  generation_mode_join_suffix: string = '';
  date_added: number = 0;
  create_date: string = '';
  chat_size: number = 0;
  date_last_chat: number = 0;
}

class PresetDirectoryResult {
  fileContents: JsonArray = [];
  fileNames: string[] = [];
}

class ChatStats {
  chatSize: number = 0;
  dateLastChat: number = 0;
}

class RecentChatFile {
  filePath: string;
  fileName: string;
  mtimeMs: number;
  avatar: string;
  group: string;

  constructor(filePath: string, fileName: string, mtimeMs: number, avatar: string = '', group: string = '') {
    this.filePath = filePath;
    this.fileName = fileName;
    this.mtimeMs = mtimeMs;
    this.avatar = avatar;
    this.group = group;
  }
}

export class SillyTavernCore {
  private store: FileStore;
  private dirs: DataDirectories;
  private userDirs: UserDirectories;
  private cardStore: PngCardStore;
  private shareExports: ShareExportService;
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  constructor(store: FileStore, dirs: DataDirectories, shareExports: ShareExportService) {
    this.store = store;
    this.dirs = dirs;
    this.userDirs = dirs.defaultUser;
    this.cardStore = new PngCardStore(store);
    this.shareExports = shareExports;
  }

  health(): HttpResponse {
    return HttpResponse.json(new HealthResponse(this.dirs.dataRoot));
  }

  csrfToken(): HttpResponse {
    return HttpResponse.json(new CsrfResponse());
  }

  version(): HttpResponse {
    return HttpResponse.json(new VersionResponse());
  }

  ping(): HttpResponse {
    return HttpResponse.json(new OkResponse());
  }

  getSettings(): HttpResponse {
    const settingsPath = joinPath(this.userDirs.root, 'settings.json');
    const response = new SettingsResponse();
    response.settings = this.store.readText(settingsPath, '{}');
    const kobold = this.readPresetsFromDirectory(this.userDirs.koboldAISettings);
    response.koboldai_settings = kobold.fileContents;
    response.koboldai_setting_names = kobold.fileNames;
    const novel = this.readPresetsFromDirectory(this.userDirs.novelAISettings);
    response.novelai_settings = novel.fileContents;
    response.novelai_setting_names = novel.fileNames;
    const openai = this.readPresetsFromDirectory(this.userDirs.openAISettings);
    response.openai_settings = openai.fileContents;
    response.openai_setting_names = openai.fileNames;
    const textgen = this.readPresetsFromDirectory(this.userDirs.textGenSettings);
    response.textgenerationwebui_presets = textgen.fileContents;
    response.textgenerationwebui_preset_names = textgen.fileNames;
    response.world_names = this.store.listFilesByExtension(this.userDirs.worlds, '.json')
      .map((file: FileEntry) => withoutExtension(file.name));
    response.themes = this.readAndParseFromDirectory(this.userDirs.themes);
    response.movingUIPresets = this.readAndParseFromDirectory(this.userDirs.movingUI);
    response.quickReplyPresets = this.readAndParseFromDirectory(this.userDirs.quickreplies);
    response.instruct = this.readAndParseFromDirectory(this.userDirs.instruct);
    response.context = this.readAndParseFromDirectory(this.userDirs.context);
    response.sysprompt = this.readAndParseFromDirectory(this.userDirs.sysprompt);
    response.reasoning = this.readAndParseFromDirectory(this.userDirs.reasoning);
    const compression = emptyJsonRecord();
    compression['enabled'] = false;
    compression['minPayloadSize'] = 262144;
    compression['maxPayloadSize'] = 8388608;
    compression['timeout'] = 3000;
    response.request_compression = compression;
    return HttpResponse.json(response);
  }

  saveSettings(request: HttpRequest): HttpResponse {
    if (request.body === null) {
      return HttpResponse.json(jsonMessage('body must be JSON'), 400);
    }
    this.store.writeJson(joinPath(this.userDirs.root, 'settings.json'), request.body);
    return HttpResponse.json(new ResultResponse('ok'));
  }

  listCharacters(): HttpResponse {
    const entries = this.store.listFilesByExtension(this.userDirs.characters, '.png');
    const characters: Object[] = [];
    for (const entry of entries) {
      const card = this.cardStore.readCard(entry.path);
      if (card === null) {
        continue;
      }
      characters.push(this.toCharacterResponse(this.normalizeCharacterCard(card), entry.name, entry, true));
    }
    return HttpResponse.json(characters);
  }

  getDataFile(request: HttpRequest): HttpResponse {
    const file = this.asString(request.query['file']);
    const type = this.asString(request.query['type']);
    let path = '';

    if (request.path.startsWith('/characters/')) {
      path = joinPath(this.userDirs.characters, sanitizeFileName(request.path.slice('/characters/'.length)));
    } else if (request.path.startsWith('/User Avatars/')) {
      path = joinPath(this.userDirs.avatars, sanitizeFileName(request.path.slice('/User Avatars/'.length)));
    } else if (request.path.startsWith('/backgrounds/')) {
      path = joinPath(this.userDirs.backgrounds, sanitizeFileName(request.path.slice('/backgrounds/'.length)));
    } else if (request.path === '/thumbnail') {
      path = this.thumbnailSourcePath(type, file);
    }

    if (path.length === 0) {
      return HttpResponse.empty(404);
    }

    const bytes = this.store.readBytes(path);
    if (bytes === null) {
      return HttpResponse.empty(404);
    }
    return HttpResponse.bytes(bytes, 200, this.contentTypeForFile(path));
  }

  listBackgrounds(): HttpResponse {
    const result = new BackgroundsResponse();
    const config = emptyJsonRecord();
    config['width'] = 160;
    config['height'] = 90;
    result.config = config;

    const extensions = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'];
    for (const file of this.store.list(this.userDirs.backgrounds)) {
      if (!file.isFile || !extensions.includes(this.extensionOf(file.name))) {
        continue;
      }
      result.images.push(new BackgroundImageResponse(file.name));
    }
    return HttpResponse.json(result);
  }

  listBackgroundFolders(): HttpResponse {
    return HttpResponse.json(new BackgroundFoldersResponse());
  }

  imageMetadataAll(): HttpResponse {
    return HttpResponse.json(new ImageMetadataAllResponse());
  }

  listAvatars(): HttpResponse {
    const avatars: string[] = [];
    const extensions = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'];
    for (const file of this.store.list(this.userDirs.avatars)) {
      if (file.isFile && extensions.includes(this.extensionOf(file.name))) {
        avatars.push(file.name);
      }
    }
    return HttpResponse.json(avatars);
  }

  secretsSettings(): HttpResponse {
    const result = emptyJsonRecord();
    result['allowKeysExposure'] = false;
    return HttpResponse.json(result);
  }

  readSecretState(): HttpResponse {
    return HttpResponse.json(emptyJsonRecord());
  }

  discoverExtensions(): HttpResponse {
    return HttpResponse.json([]);
  }

  getCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }

    const pngName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const path = joinPath(this.userDirs.characters, pngName);
    if (!this.store.exists(path)) {
      return HttpResponse.empty(404);
    }

    const card = this.cardStore.readCard(path);
    if (card === null) {
      return HttpResponse.json(jsonMessage('failed_to_read_character'), 400);
    }
    const entry = this.statEntry(pngName, path);
    return HttpResponse.json(this.toCharacterResponse(this.normalizeCharacterCard(card), pngName, entry, false));
  }

  createCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const chName = sanitizeFileName(this.asString(body['ch_name']) || 'New Character');
    const rawFileName = this.asString(body['file_name']);
    const internalName = rawFileName.length > 0 ? withoutExtension(sanitizeFileName(rawFileName)) : this.uniqueName(chName,
      this.userDirs.characters, '.png');
    const card = this.buildCharacterCard(body, chName);
    if (!this.cardStore.writeCard(joinPath(this.userDirs.characters, `${internalName}.png`), card)) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }
    this.store.ensureDir(joinPath(this.userDirs.chats, internalName));
    return HttpResponse.text(`${internalName}.png`);
  }

  editCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    const internalName = withoutExtension(sanitizeFileName(avatarUrl));
    const chName = this.asString(body['ch_name']) || this.asString(body['name']) || internalName;
    const card = this.buildCharacterCard(body, chName);
    const path = joinPath(this.userDirs.characters, `${internalName}.png`);
    if (!this.cardStore.writeCard(path, card)) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }
    return HttpResponse.json(new OkResponse());
  }

  deleteCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    const internalName = withoutExtension(sanitizeFileName(avatarUrl));
    const deleted = this.store.deleteFile(joinPath(this.userDirs.characters, `${internalName}.png`));
    if (!deleted) {
      return HttpResponse.empty(400);
    }
    if (body['delete_chats'] === true) {
      this.store.deleteDirectory(joinPath(this.userDirs.chats, internalName));
    }
    return HttpResponse.json(new OkResponse());
  }

  importCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const fileType = this.asString(body['file_type']).toLowerCase();
    const file = request.file('avatar');
    if (file === null || fileType.length === 0) {
      return HttpResponse.empty(400);
    }

    try {
      let card: JsonRecord | null = null;
      let baseImage: Uint8Array | null = null;
      if (fileType === 'json') {
        card = this.importCardFromJsonBytes(file.bytes);
      } else if (fileType === 'png') {
        card = this.importCardFromPngBytes(file.bytes);
        baseImage = file.bytes;
      } else {
        return HttpResponse.json(jsonMessage('unsupported_format', fileType), 400);
      }

      if (card === null) {
        return HttpResponse.json(new ErrorFlagResponse());
      }

      const internalName = this.importedCharacterInternalName(card, body);
      const path = joinPath(this.userDirs.characters, `${internalName}.png`);
      const written = baseImage === null ? this.cardStore.writeCard(path, card) :
        this.cardStore.writeCardWithBase(path, baseImage, card);
      if (!written) {
        return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
      }
      this.store.ensureDir(joinPath(this.userDirs.chats, internalName));

      const response = emptyJsonRecord();
      response['file_name'] = internalName;
      return HttpResponse.json(response);
    } catch (_err) {
      return HttpResponse.json(new ErrorFlagResponse());
    }
  }

  async exportCharacter(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const format = this.asString(body['format']).toLowerCase();
    const avatarUrl = this.asString(body['avatar_url']);
    if (format.length === 0 || avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }

    const avatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const path = joinPath(this.userDirs.characters, avatarName);
    const sourceBytes = this.store.readBytes(path);
    if (sourceBytes === null) {
      return HttpResponse.empty(404);
    }

    const card = this.cardStore.readCardFromBytes(sourceBytes);
    if (card === null) {
      return HttpResponse.empty(400);
    }

    const safeCard = this.unsetPrivateFields(this.normalizeCharacterCard(card));
    const internalName = withoutExtension(avatarName);
    if (format === 'json') {
      const fileName = `${internalName}.json`;
      const bytes = this.encoder.encodeInto(JSON.stringify(safeCard, null, 4));
      const exported = this.shareExports.writeExportFile('characters', fileName, bytes,
        ShareExportService.contentTypeForExtension('.json'), ShareExportService.utdForExtension('.json'));
      return this.shareExports.shareHttpResponse(exported, fileName);
    }
    if (format === 'png') {
      const bytes = this.cardStore.writeCardToBytes(sourceBytes, safeCard);
      if (bytes === null) {
        return HttpResponse.empty(400);
      }
      const fileName = `${internalName}.png`;
      const exported = this.shareExports.writeExportFile('characters', fileName, bytes,
        ShareExportService.contentTypeForExtension('.png'), ShareExportService.utdForExtension('.png'));
      return this.shareExports.shareHttpResponse(exported, fileName);
    }
    return HttpResponse.empty(400);
  }

  listCharacterChats(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    const dir = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)));
    if (!this.store.exists(dir)) {
      return HttpResponse.json(new ErrorFlagResponse());
    }
    const files = this.store.listFilesByExtension(dir, '.jsonl');
    if (body['simple'] === true) {
      const simpleRows: SimpleChatResponse[] = [];
      for (const file of files) {
        const row = new SimpleChatResponse();
        row.file_name = file.name;
        row.file_id = withoutExtension(file.name);
        simpleRows.push(row);
      }
      return HttpResponse.json(simpleRows);
    }

    const rows: ChatSummaryResponse[] = [];
    for (const file of files) {
      const row = new ChatSummaryResponse();
      row.file_name = file.name;
      row.file_id = withoutExtension(file.name);
      row.chat_items = this.readChatFile(file.path).length;
      row.mes = this.getLastChatMessage(file.path);
      row.last_mes = row.mes;
      row.file_size = file.size;
      row.date_last_chat = file.mtimeMs;
      rows.push(row);
    }
    return HttpResponse.json(rows);
  }

  getChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }
    const dir = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)));
    this.store.ensureDir(dir);

    const fileName = this.asString(body['file_name']);
    if (fileName.length === 0) {
      return HttpResponse.json(emptyJsonRecord());
    }
    return HttpResponse.json(this.readChatFile(joinPath(dir, sanitizeFileName(ensureJsonlExtension(fileName)))));
  }

  saveChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    const fileName = this.asString(body['file_name']);
    const chat = body['chat'];
    if (avatarUrl.length === 0 || fileName.length === 0 || !Array.isArray(chat)) {
      return HttpResponse.json(jsonMessage('avatar_url, file_name and chat[] are required'), 400);
    }
    const dir = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)));
    this.store.ensureDir(dir);
    const jsonl = chat.map((item: Object | string | number | boolean | null) => JSON.stringify(item)).join('\n');
    this.store.writeText(joinPath(dir, sanitizeFileName(ensureJsonlExtension(fileName))), jsonl);
    return HttpResponse.json(new OkResponse());
  }

  recentChats(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const max = Math.max(0, Number(body['max'] ?? Number.MAX_SAFE_INTEGER));
    const pinned = this.asArray(body['pinned']);
    const files: RecentChatFile[] = [];

    this.collectCharacterRecentChats(files);
    this.collectGroupRecentChats(files);
    this.collectRootRecentChats(files);

    files.sort((a: RecentChatFile, b: RecentChatFile): number => {
      const aPinned = this.isPinnedRecentChat(a, pinned);
      const bPinned = this.isPinnedRecentChat(b, pinned);
      if (aPinned && !bPinned) {
        return -1;
      }
      if (!aPinned && bPinned) {
        return 1;
      }
      return b.mtimeMs - a.mtimeMs;
    });

    const limit = max + pinned.length;
    const selected = Number.isFinite(limit) ? files.slice(0, limit) : files;
    const rows: RecentChatResponse[] = [];
    for (const file of selected) {
      const row = this.recentChatInfo(file);
      if (row.file_name.length > 0) {
        rows.push(row);
      }
    }
    return HttpResponse.json(rows);
  }

  listWorlds(): HttpResponse {
    const worlds: WorldListResponse[] = [];
    const files = this.store.listFilesByExtension(this.userDirs.worlds, '.json');
    for (const file of files) {
      const parsed = this.store.readJsonRecord(file.path);
      const row = new WorldListResponse();
      row.file_id = withoutExtension(file.name);
      row.name = this.asString(parsed['name']) || withoutExtension(file.name);
      row.extensions = this.asObject(parsed['extensions']);
      worlds.push(row);
    }
    return HttpResponse.json(worlds);
  }

  getWorld(request: HttpRequest): HttpResponse {
    const name = sanitizeFileName(this.asString(this.bodyAsRecord(request)['name']));
    if (name.length === 0) {
      return HttpResponse.empty(400);
    }
    const path = joinPath(this.userDirs.worlds, ensureJsonExtension(name));
    if (!this.store.exists(path)) {
      return HttpResponse.json(this.emptyWorld());
    }
    return HttpResponse.json(this.store.readJsonObject(path, this.emptyWorld()));
  }

  editWorld(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const name = sanitizeFileName(this.asString(body['name']));
    const data = body['data'];
    if (name.length === 0 || data === null || typeof data !== 'object' || Array.isArray(data)) {
      return HttpResponse.text('World file must have a name and data object', 400);
    }
    const dataRecord = data as JsonRecord;
    if (dataRecord['entries'] === undefined) {
      return HttpResponse.text('Is not a valid world info file', 400);
    }
    this.store.writeJson(joinPath(this.userDirs.worlds, ensureJsonExtension(name)), data as Object);
    return HttpResponse.json(new OkResponse());
  }

  deleteWorld(request: HttpRequest): HttpResponse {
    const name = sanitizeFileName(this.asString(this.bodyAsRecord(request)['name']));
    if (name.length === 0) {
      return HttpResponse.empty(400);
    }
    this.store.deleteFile(joinPath(this.userDirs.worlds, ensureJsonExtension(name)));
    return HttpResponse.json(new OkResponse());
  }

  listGroups(): HttpResponse {
    const files = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    const groupChats = this.store.listFilesByExtension(this.userDirs.groupChats, '.jsonl');
    const groups: GroupResponse[] = [];
    for (const file of files) {
      const stored = this.store.readJsonRecord(file.path);
      const group = this.groupFromRecord(stored);
      const chats = this.asArray(stored['chats']);
      for (const chat of groupChats) {
        if (chats.includes(withoutExtension(chat.name))) {
          group.chat_size += chat.size;
          group.date_last_chat = Math.max(group.date_last_chat, chat.mtimeMs);
        }
      }
      group.date_added = file.ctimeMs;
      group.create_date = new Date(file.ctimeMs).toISOString();
      groups.push(group);
    }
    return HttpResponse.json(groups);
  }

  createGroup(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const id = `${Date.now()}`;
    const group = new GroupResponse();
    group.id = id;
    group.name = this.asString(body['name']) || 'New Group';
    group.members = this.asArray(body['members']);
    group.avatar_url = this.asString(body['avatar_url']);
    group.allow_self_responses = body['allow_self_responses'] === true;
    group.activation_strategy = Number(body['activation_strategy'] ?? 0);
    group.generation_mode = Number(body['generation_mode'] ?? 0);
    group.disabled_members = this.asArray(body['disabled_members']);
    group.fav = body['fav'] === true;
    group.chat_id = this.asString(body['chat_id']) || id;
    group.chats = this.asArray(body['chats']);
    if (group.chats.length === 0) {
      group.chats.push(id);
    }
    group.auto_mode_delay = Number(body['auto_mode_delay'] ?? 5);
    group.generation_mode_join_prefix = this.asString(body['generation_mode_join_prefix']);
    group.generation_mode_join_suffix = this.asString(body['generation_mode_join_suffix']);
    this.store.writeJson(joinPath(this.userDirs.groups, `${id}.json`), group);
    return HttpResponse.json(group);
  }

  editGroup(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const id = sanitizeFileName(this.asString(body['id']));
    if (id.length === 0) {
      return HttpResponse.empty(400);
    }
    this.store.writeJson(joinPath(this.userDirs.groups, `${id}.json`), request.body ?? emptyJsonRecord());
    return HttpResponse.json(new OkResponse());
  }

  deleteGroup(request: HttpRequest): HttpResponse {
    const id = sanitizeFileName(this.asString(this.bodyAsRecord(request)['id']));
    if (id.length === 0) {
      return HttpResponse.empty(400);
    }
    const path = joinPath(this.userDirs.groups, `${id}.json`);
    const group = this.store.readJsonRecord(path);
    const chats = this.asArray(group['chats']);
    for (const chat of chats) {
      this.store.deleteFile(joinPath(this.userDirs.groupChats, sanitizeFileName(ensureJsonlExtension(`${chat}`))));
    }
    this.store.deleteFile(path);
    return HttpResponse.json(new OkResponse());
  }

  notImplemented(name: string): HttpResponse {
    return HttpResponse.json(jsonMessage('not_implemented',
      `${name} is outside the first ArkTS local-data milestone.`), 501);
  }

  tokenEstimate(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const text = this.asString(body['text']);
    const tokens = Math.ceil(this.utf8ByteLength(text) / 3.35);
    const result = emptyJsonRecord();
    result['ids'] = [];
    result['count'] = tokens;
    result['token_count'] = tokens;
    result['chunks'] = [];
    return HttpResponse.json(result);
  }

  private bodyAsRecord(request: HttpRequest): JsonRecord {
    if (request.body === null || Array.isArray(request.body)) {
      return emptyJsonRecord();
    }
    return request.body as JsonRecord;
  }

  private asString(value: JsonValue | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    return `${value}`;
  }

  private asObject(value: JsonValue | undefined): Object {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      return emptyJsonRecord();
    }
    return value as Object;
  }

  private asArray(value: JsonValue | undefined): JsonArray {
    if (!Array.isArray(value)) {
      return [];
    }
    return value;
  }

  private emptyWorld(): JsonRecord {
    const value = emptyJsonRecord();
    value['entries'] = emptyJsonRecord();
    return value;
  }

  private readPresetsFromDirectory(directory: string): PresetDirectoryResult {
    const result = new PresetDirectoryResult();
    const files = this.store.listFilesByExtension(directory, '.json');
    for (const file of files) {
      const value = this.store.readJsonObject(file.path, emptyJsonRecord());
      result.fileContents.push(value);
      result.fileNames.push(withoutExtension(file.name));
    }
    return result;
  }

  private readAndParseFromDirectory(directory: string): JsonArray {
    const result: JsonArray = [];
    const files = this.store.listFilesByExtension(directory, '.json');
    for (const file of files) {
      result.push(this.store.readJsonObject(file.path, emptyJsonRecord()));
    }
    return result;
  }

  private buildCharacterCard(body: JsonRecord, name: string): JsonRecord {
    const card = this.parseJsonRecord(this.asString(body['json_data']));
    const tags = this.asArray(body['tags']);
    if (tags.length === 0) {
      const rawTags = this.asString(body['tags']).split(',');
      for (const rawTag of rawTags) {
        const tag = rawTag.trim();
        if (tag.length > 0) {
          tags.push(tag);
        }
      }
    }

    const now = new Date().toISOString();
    const data = this.asObject(card['data']) as JsonRecord;
    const extensions = this.asObject(data['extensions']) as JsonRecord;
    const depthPrompt = this.asObject(extensions['depth_prompt']) as JsonRecord;
    depthPrompt['prompt'] = this.asString(body['depth_prompt_prompt']);
    depthPrompt['depth'] = Number(body['depth_prompt_depth'] ?? 4);
    depthPrompt['role'] = this.asString(body['depth_prompt_role']) || 'system';

    extensions['talkativeness'] = Number(body['talkativeness'] ?? 0.5);
    extensions['fav'] = body['fav'] === true || body['fav'] === 'true';
    extensions['world'] = this.asString(body['world']);
    extensions['depth_prompt'] = depthPrompt;

    data['name'] = name;
    data['description'] = this.asString(body['description']);
    data['personality'] = this.asString(body['personality']);
    data['scenario'] = this.asString(body['scenario']);
    data['first_mes'] = this.asString(body['first_mes']);
    data['mes_example'] = this.asString(body['mes_example']);
    data['creator_notes'] = this.asString(body['creator_notes']);
    data['system_prompt'] = this.asString(body['system_prompt']);
    data['post_history_instructions'] = this.asString(body['post_history_instructions']);
    data['tags'] = tags;
    data['creator'] = this.asString(body['creator']);
    data['character_version'] = this.asString(body['character_version']);
    data['alternate_greetings'] = this.asArray(body['alternate_greetings']);
    data['extensions'] = extensions;

    card['spec'] = 'chara_card_v2';
    card['spec_version'] = '2.0';
    card['name'] = name;
    card['description'] = data['description'];
    card['personality'] = data['personality'];
    card['scenario'] = data['scenario'];
    card['first_mes'] = data['first_mes'];
    card['mes_example'] = data['mes_example'];
    card['creatorcomment'] = data['creator_notes'];
    card['avatar'] = 'none';
    card['chat'] = this.asString(body['chat']) || this.asString(card['chat']) || `${name} - ${now}`;
    card['talkativeness'] = Number(body['talkativeness'] ?? 0.5);
    card['fav'] = body['fav'] === true || body['fav'] === 'true';
    card['tags'] = tags;
    card['create_date'] = this.asString(body['create_date']) || now;
    card['data'] = data;
    return card;
  }

  private normalizeCharacterCard(card: JsonRecord): JsonRecord {
    if (card['spec'] === undefined) {
      return this.convertLegacyCharacterCard(card);
    }

    const data = this.asObject(card['data']) as JsonRecord;
    if (data['name'] !== undefined) {
      card['name'] = data['name'];
    }
    if (data['description'] !== undefined) {
      card['description'] = data['description'];
    }
    if (data['personality'] !== undefined) {
      card['personality'] = data['personality'];
    }
    if (data['scenario'] !== undefined) {
      card['scenario'] = data['scenario'];
    }
    if (data['first_mes'] !== undefined) {
      card['first_mes'] = data['first_mes'];
    }
    if (data['mes_example'] !== undefined) {
      card['mes_example'] = data['mes_example'];
    }
    const extensions = this.asObject(data['extensions']) as JsonRecord;
    card['talkativeness'] = extensions['talkativeness'] ?? card['talkativeness'] ?? 0.5;
    card['fav'] = extensions['fav'] === true || card['fav'] === true;
    card['tags'] = this.asArray(data['tags']).length > 0 ? this.asArray(data['tags']) : this.asArray(card['tags']);
    card['chat'] = this.asString(card['chat']) || `${this.asString(card['name'])} - ${new Date().toISOString()}`;
    card['data'] = data;
    return card;
  }

  private convertLegacyCharacterCard(card: JsonRecord): JsonRecord {
    const body = emptyJsonRecord();
    body['ch_name'] = this.asString(card['name']);
    body['description'] = this.asString(card['description']);
    body['personality'] = this.asString(card['personality']);
    body['scenario'] = this.asString(card['scenario']);
    body['first_mes'] = this.asString(card['first_mes']);
    body['mes_example'] = this.asString(card['mes_example']);
    body['creator_notes'] = this.asString(card['creatorcomment']);
    body['talkativeness'] = Number(card['talkativeness'] ?? 0.5);
    body['fav'] = card['fav'] === true;
    body['tags'] = this.asArray(card['tags']);
    body['creator'] = this.asString(card['creator']);
    body['depth_prompt_prompt'] = this.asString(card['depth_prompt_prompt']);
    body['depth_prompt_depth'] = Number(card['depth_prompt_depth'] ?? 4);
    body['depth_prompt_role'] = this.asString(card['depth_prompt_role']);
    const converted = this.buildCharacterCard(body, this.asString(card['name']));
    converted['chat'] = this.asString(card['chat']) || converted['chat'];
    converted['create_date'] = this.asString(card['create_date']);
    return converted;
  }

  private importCardFromJsonBytes(bytes: Uint8Array): JsonRecord | null {
    const parsed = this.parseJsonRecord(this.decoder.decodeToString(bytes));
    if (Object.keys(parsed).length === 0) {
      return null;
    }
    return this.normalizeImportedCharacterCard(parsed);
  }

  private importCardFromPngBytes(bytes: Uint8Array): JsonRecord | null {
    const parsed = this.cardStore.readCardFromBytes(bytes);
    if (parsed === null) {
      return null;
    }
    return this.normalizeImportedCharacterCard(parsed);
  }

  private normalizeImportedCharacterCard(rawCard: JsonRecord): JsonRecord | null {
    let card: JsonRecord;
    if (rawCard['spec'] !== undefined) {
      card = this.normalizeCharacterCard(rawCard);
    } else if (rawCard['name'] !== undefined) {
      card = this.convertLegacyCharacterCard(rawCard);
    } else if (rawCard['char_name'] !== undefined) {
      card = this.convertPygmalionCharacterCard(rawCard);
    } else {
      return null;
    }

    card = this.unsetPrivateFields(card);
    card['create_date'] = new Date().toISOString();

    const data = this.asObject(card['data']) as JsonRecord;
    const displayName = this.asString(data['name']) || this.asString(card['name']) || 'New Character';
    const safeName = sanitizeFileName(displayName);
    data['name'] = safeName;
    card['name'] = safeName;
    card['data'] = data;
    return card;
  }

  private convertPygmalionCharacterCard(card: JsonRecord): JsonRecord {
    const body = emptyJsonRecord();
    body['ch_name'] = this.asString(card['char_name']);
    body['description'] = this.asString(card['char_persona']);
    body['personality'] = '';
    body['scenario'] = this.asString(card['world_scenario']);
    body['first_mes'] = this.asString(card['char_greeting']);
    body['mes_example'] = this.asString(card['example_dialogue']);
    body['creator_notes'] = this.asString(card['creatorcomment']) ||
      this.stripDefaultCreatorNotes(this.asString(card['creator_notes']));
    body['talkativeness'] = Number(card['talkativeness'] ?? 0.5);
    body['fav'] = card['fav'] === true;
    body['tags'] = this.asArray(card['tags']);
    body['creator'] = this.asString(card['creator']);
    const converted = this.buildCharacterCard(body, this.asString(card['char_name']));
    converted['chat'] = `${this.asString(card['char_name'])} - ${new Date().toISOString()}`;
    return converted;
  }

  private unsetPrivateFields(card: JsonRecord): JsonRecord {
    const safeCard = emptyJsonRecord();
    Object.keys(card).forEach((key: string) => {
      if (key !== 'chat') {
        safeCard[key] = card[key];
      }
    });
    safeCard['fav'] = false;
    const data = this.asObject(safeCard['data']) as JsonRecord;
    const extensions = this.asObject(data['extensions']) as JsonRecord;
    extensions['fav'] = false;
    data['extensions'] = extensions;
    safeCard['data'] = data;
    return safeCard;
  }

  private importedCharacterInternalName(card: JsonRecord, body: JsonRecord): string {
    const preserved = withoutExtension(sanitizeFileName(this.asString(body['preserved_name'])));
    if (preserved.length > 0 && preserved !== 'unnamed') {
      return preserved;
    }
    const data = this.asObject(card['data']) as JsonRecord;
    const name = this.asString(data['name']) || this.asString(card['name']) || 'New Character';
    return this.uniqueName(name, this.userDirs.characters, '.png');
  }

  private stripDefaultCreatorNotes(value: string): string {
    return value.replace("Creator's notes go here.", '');
  }

  private toCharacterResponse(card: Object, avatarName: string, entry: FileEntry, shallow: boolean): CharacterResponse {
    const record = card as JsonRecord;
    const data = this.asObject(record['data']) as JsonRecord;
    const extensions = this.asObject(data['extensions']) as JsonRecord;
    const stats = this.calculateChatStats(joinPath(this.userDirs.chats, withoutExtension(avatarName)));

    const result = new CharacterResponse();
    result.shallow = shallow;
    result.name = this.asString(record['name']) || this.asString(data['name']) || withoutExtension(avatarName);
    result.avatar = avatarName;
    result.chat = this.asString(record['chat']);
    result.fav = record['fav'] === true || extensions['fav'] === true;
    result.date_added = entry.ctimeMs;
    result.create_date = this.asString(record['create_date']) || new Date(entry.ctimeMs).toISOString();
    result.date_last_chat = stats.dateLastChat;
    result.chat_size = stats.chatSize;
    result.data_size = this.calculateDataSize(data);
    result.tags = this.asArray(record['tags']);

    if (shallow) {
      const shallowExtensions = emptyJsonRecord();
      shallowExtensions['fav'] = extensions['fav'] === true;
      shallowExtensions['world'] = this.asString(extensions['world']);

      const shallowData = emptyJsonRecord();
      shallowData['name'] = this.asString(data['name']);
      shallowData['character_version'] = this.asString(data['character_version']);
      shallowData['creator'] = this.asString(data['creator']);
      shallowData['creator_notes'] = this.asString(data['creator_notes']);
      shallowData['tags'] = this.asArray(data['tags']);
      shallowData['extensions'] = shallowExtensions;
      result.data = shallowData;
    } else {
      result.data = data;
      result.json_data = JSON.stringify(card);
      result.spec = this.asString(record['spec']) || 'chara_card_v2';
      result.spec_version = this.asString(record['spec_version']) || '2.0';
      result.description = this.asString(record['description']) || this.asString(data['description']);
      result.personality = this.asString(record['personality']) || this.asString(data['personality']);
      result.scenario = this.asString(record['scenario']) || this.asString(data['scenario']);
      result.first_mes = this.asString(record['first_mes']) || this.asString(data['first_mes']);
      result.mes_example = this.asString(record['mes_example']) || this.asString(data['mes_example']);
    }
    return result;
  }

  private groupFromRecord(stored: JsonRecord): GroupResponse {
    const group = new GroupResponse();
    group.id = this.asString(stored['id']);
    group.name = this.asString(stored['name']);
    group.members = this.asArray(stored['members']);
    group.avatar_url = this.asString(stored['avatar_url']);
    group.allow_self_responses = stored['allow_self_responses'] === true;
    group.activation_strategy = Number(stored['activation_strategy'] ?? 0);
    group.generation_mode = Number(stored['generation_mode'] ?? 0);
    group.disabled_members = this.asArray(stored['disabled_members']);
    group.fav = stored['fav'] === true;
    group.chat_id = this.asString(stored['chat_id']);
    group.chats = this.asArray(stored['chats']);
    group.auto_mode_delay = Number(stored['auto_mode_delay'] ?? 5);
    group.generation_mode_join_prefix = this.asString(stored['generation_mode_join_prefix']);
    group.generation_mode_join_suffix = this.asString(stored['generation_mode_join_suffix']);
    return group;
  }

  private calculateChatStats(path: string): ChatStats {
    const stats = new ChatStats();
    if (!this.store.exists(path)) {
      return stats;
    }
    const entries = this.store.list(path);
    for (const entry of entries) {
      if (!entry.isFile) {
        continue;
      }
      stats.chatSize += entry.size;
      stats.dateLastChat = Math.max(stats.dateLastChat, entry.mtimeMs);
    }
    return stats;
  }

  private calculateDataSize(data: JsonRecord): number {
    let size = 0;
    Object.keys(data).forEach((key: string) => {
      const value = data[key];
      size += this.asString(value).length;
    });
    return size;
  }

  private parseJsonRecord(text: string): JsonRecord {
    const normalized = this.stripJsonBom(text);
    if (normalized.length === 0) {
      return emptyJsonRecord();
    }
    try {
      const parsed = JSON.parse(normalized) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        return emptyJsonRecord();
      }
      return parsed as JsonRecord;
    } catch (_err) {
      return emptyJsonRecord();
    }
  }

  private stripJsonBom(text: string): string {
    if (text.length > 0 && text.charCodeAt(0) === 0xfeff) {
      return text.slice(1);
    }
    return text;
  }

  private statEntry(name: string, path: string): FileEntry {
    const candidates = this.store.list(this.userDirs.characters).filter((entry: FileEntry) => entry.path === path);
    if (candidates.length > 0) {
      return candidates[0];
    }
    return new FileEntry(name, path, true, false, 0, Date.now(), Date.now());
  }

  private thumbnailSourcePath(type: string, file: string): string {
    const safeFile = sanitizeFileName(file);
    switch (type) {
      case 'avatar':
        return joinPath(this.userDirs.characters, safeFile);
      case 'persona':
        return joinPath(this.userDirs.avatars, safeFile);
      case 'bg':
        return joinPath(this.userDirs.backgrounds, safeFile);
      default:
        return '';
    }
  }

  private contentTypeForFile(path: string): string {
    switch (this.extensionOf(path)) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.svg':
        return 'image/svg+xml';
      default:
        return 'application/octet-stream';
    }
  }

  private extensionOf(name: string): string {
    const index = name.lastIndexOf('.');
    if (index < 0) {
      return '';
    }
    return name.slice(index).toLowerCase();
  }

  private utf8ByteLength(value: string): number {
    let length = 0;
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code < 0x80) {
        length += 1;
      } else if (code < 0x800) {
        length += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        length += 4;
        index += 1;
      } else {
        length += 3;
      }
    }
    return length;
  }

  private readChatFile(path: string): Object[] {
    const text = this.store.readText(path, '');
    if (text.length === 0) {
      return [];
    }
    const rows: Object[] = [];
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      try {
        rows.push(JSON.parse(trimmed) as Object);
      } catch (_err) {
      }
    }
    return rows;
  }

  private getLastChatMessage(path: string): string {
    const rows = this.readChatFile(path);
    if (rows.length === 0) {
      return '';
    }
    const last = rows[rows.length - 1] as JsonRecord;
    return this.asString(last['mes']);
  }

  private collectCharacterRecentChats(files: RecentChatFile[]): void {
    const characterFiles = this.store.listFilesByExtension(this.userDirs.characters, '.png');
    for (const character of characterFiles) {
      const chatDir = joinPath(this.userDirs.chats, withoutExtension(character.name));
      if (!this.store.exists(chatDir)) {
        continue;
      }
      const chatFiles = this.store.listFilesByExtension(chatDir, '.jsonl');
      for (const chatFile of chatFiles) {
        files.push(new RecentChatFile(chatFile.path, chatFile.name, chatFile.mtimeMs, character.name));
      }
    }
  }

  private collectGroupRecentChats(files: RecentChatFile[]): void {
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      const groupId = this.asString(group['id']) || withoutExtension(groupFile.name);
      const chats = this.asArray(group['chats']);
      for (const chat of chats) {
        const fileName = ensureJsonlExtension(sanitizeFileName(`${chat}`));
        const filePath = joinPath(this.userDirs.groupChats, fileName);
        const stat = this.store.stat(filePath, fileName);
        if (stat !== null && stat.isFile) {
          files.push(new RecentChatFile(filePath, fileName, stat.mtimeMs, '', groupId));
        }
      }
    }
  }

  private collectRootRecentChats(files: RecentChatFile[]): void {
    const chatFiles = this.store.listFilesByExtension(this.userDirs.chats, '.jsonl');
    for (const chatFile of chatFiles) {
      files.push(new RecentChatFile(chatFile.path, chatFile.name, chatFile.mtimeMs));
    }
  }

  private isPinnedRecentChat(file: RecentChatFile, pinned: JsonArray): boolean {
    for (const item of pinned) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const pinnedRecord = item as JsonRecord;
      if (this.asString(pinnedRecord['file_name']) !== file.fileName) {
        continue;
      }
      if (file.avatar.length > 0 && this.asString(pinnedRecord['avatar']) === file.avatar) {
        return true;
      }
      if (file.group.length > 0 && this.asString(pinnedRecord['group']) === file.group) {
        return true;
      }
      if (file.avatar.length === 0 && file.group.length === 0) {
        return true;
      }
    }
    return false;
  }

  private recentChatInfo(file: RecentChatFile): RecentChatResponse {
    const stat = this.store.stat(file.filePath, file.fileName);
    if (stat === null || !stat.isFile) {
      return new RecentChatResponse();
    }

    const row = new RecentChatResponse();
    row.file_id = withoutExtension(file.fileName);
    row.file_name = file.fileName;
    row.file_size = this.formatBytes(stat.size);
    row.last_mes = new Date(Math.round(stat.mtimeMs)).toISOString();
    row.avatar = file.avatar;
    row.group = file.group;

    if (stat.size === 0) {
      return row;
    }

    const rows = this.readChatFile(file.filePath);
    if (rows.length === 0) {
      return new RecentChatResponse();
    }

    const last = rows[rows.length - 1] as JsonRecord;
    if (this.asString(last['name']).length === 0 && this.asString(last['character_name']).length === 0 &&
      last['chat_metadata'] === undefined) {
      return new RecentChatResponse();
    }

    row.chat_items = Math.max(0, rows.length - 1);
    row.mes = this.asString(last['mes']) || '[The message is empty]';
    row.last_mes = this.asString(last['send_date']) || row.last_mes;
    return row;
  }

  private formatBytes(numBytes: number): string {
    if (numBytes < 1024) {
      return `${numBytes} B`;
    }
    const units = ['KB', 'MB', 'GB', 'TB'];
    let value = numBytes / 1024;
    let unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value = value / 1024;
      unitIndex += 1;
    }
    return `${value.toFixed(1)} ${units[unitIndex]}`;
  }

  private uniqueName(baseName: string, directory: string, extension: string): string {
    let candidate = sanitizeFileName(baseName);
    let index = 1;
    while (this.store.exists(joinPath(directory, `${candidate}${extension}`))) {
      candidate = `${sanitizeFileName(baseName)}${index}`;
      index += 1;
    }
    return candidate;
  }
}
