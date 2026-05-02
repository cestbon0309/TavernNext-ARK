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

class StatusResponse {
  ok: boolean = false;
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
  agent: string = 'SillyTavern:1.17.0:TavernNext-OHOS';
  pkgVersion: string = '1.17.0-ohos';
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

class ChatSearchResponse {
  file_name: string = '';
  file_size: string = '';
  message_count: number = 0;
  last_mes: string = '';
  preview_message: string = '';
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
  fileContents: string[] = [];
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

  statsGet(): HttpResponse {
    return HttpResponse.json(this.store.readJsonRecord(this.statsPath()));
  }

  statsUpdate(request: HttpRequest): HttpResponse {
    if (request.body === null || Array.isArray(request.body)) {
      return HttpResponse.empty(400);
    }
    const stats = request.body as JsonRecord;
    stats['timestamp'] = Date.now();
    this.store.writeJson(this.statsPath(), stats);
    return HttpResponse.empty(200);
  }

  statsRecreate(): HttpResponse {
    const stats = this.collectStats();
    stats['timestamp'] = Date.now();
    this.store.writeJson(this.statsPath(), stats);
    return HttpResponse.empty(200);
  }

  offlineStatus(): HttpResponse {
    return HttpResponse.json(new StatusResponse());
  }

  emptyArray(): HttpResponse {
    return HttpResponse.json([]);
  }

  saveQuickReply(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const name = sanitizeFileName(this.asString(body['name']));
    if (name.length === 0 || name === 'unnamed') {
      return HttpResponse.empty(400);
    }
    this.store.writeJson(joinPath(this.userDirs.quickreplies, ensureJsonExtension(name)), request.body ?? emptyJsonRecord());
    return HttpResponse.empty(200);
  }

  deleteQuickReply(request: HttpRequest): HttpResponse {
    const name = sanitizeFileName(this.asString(this.bodyAsRecord(request)['name']));
    if (name.length === 0 || name === 'unnamed') {
      return HttpResponse.empty(400);
    }
    this.store.deleteFile(joinPath(this.userDirs.quickreplies, ensureJsonExtension(name)));
    return HttpResponse.empty(200);
  }

  listComfyWorkflows(): HttpResponse {
    const workflows = this.store.listFilesByExtension(this.userDirs.comfyWorkflows, '.json')
      .filter((file: FileEntry): boolean => !file.name.startsWith('.'))
      .map((file: FileEntry): string => file.name);
    return HttpResponse.json(workflows);
  }

  getComfyWorkflow(request: HttpRequest): HttpResponse {
    const requested = sanitizeFileName(this.asString(this.bodyAsRecord(request)['file_name']));
    let path = requested.length > 0 && requested !== 'unnamed' ? joinPath(this.userDirs.comfyWorkflows, requested) : '';
    if (path.length === 0 || !this.store.exists(path)) {
      path = joinPath(this.userDirs.comfyWorkflows, 'Default_Comfy_Workflow.json');
    }
    return HttpResponse.json(this.store.readText(path, '{}'));
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

  editCharacterAvatar(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    const file = request.file('avatar');
    if (avatarUrl.length === 0) {
      return HttpResponse.text('Error: no avatar_url in request body', 400);
    }
    if (file === null) {
      return HttpResponse.text('Error: no file uploaded', 400);
    }

    const avatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const path = joinPath(this.userDirs.characters, avatarName);
    const card = this.cardStore.readCard(path);
    if (card === null) {
      return HttpResponse.text('Error: failed to read character data', 400);
    }

    const written = this.cardStore.writeCardWithBase(path, file.bytes, card);
    if (!written) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }
    this.invalidateAvatarThumbnail(avatarName);
    return HttpResponse.text('OK');
  }

  editCharacterAttribute(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    const field = this.asString(body['field']);
    if (avatarUrl.length === 0 || field.length === 0) {
      return HttpResponse.text('Error: avatar_url and field are required', 400);
    }
    if (field === 'json_data') {
      return HttpResponse.text('Error: cannot edit json_data field.', 400);
    }

    const chName = this.asString(body['ch_name']);
    if (chName === '.' || (body['ch_name'] !== undefined && chName.length === 0)) {
      return HttpResponse.text('Error: invalid name.', 400);
    }

    const avatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const path = joinPath(this.userDirs.characters, avatarName);
    const card = this.cardStore.readCard(path);
    if (card === null) {
      return HttpResponse.empty(500);
    }

    const data = this.asObject(card['data']) as JsonRecord;
    if (card[field] === undefined && data[field] === undefined) {
      return HttpResponse.text('Error: invalid field.', 400);
    }

    const value = body['value'] ?? null;
    card[field] = value;
    data[field] = value;
    card['data'] = data;
    if (!this.cardStore.writeCard(path, card)) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }
    this.invalidateAvatarThumbnail(avatarName);
    return HttpResponse.text('OK');
  }

  mergeCharacterAttributes(request: HttpRequest): HttpResponse {
    const update = this.bodyAsRecord(request);
    const avatarUrl = this.asString(update['avatar']) || this.asString(update['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.text('Error: avatar is required', 400);
    }

    const avatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const path = joinPath(this.userDirs.characters, avatarName);
    const stored = this.cardStore.readCard(path);
    if (stored === null) {
      return HttpResponse.text('Error: invalid character file.', 400);
    }

    const merged = this.deepMergeRecord(this.withoutJsonData(stored), this.withoutJsonData(update));
    const validationError = this.validateCharacterCardForSave(merged);
    if (validationError.length > 0) {
      const response = emptyJsonRecord();
      response['message'] = `Validation failed for ${this.asString(merged['name'])}`;
      response['error'] = validationError;
      return HttpResponse.json(response, 400);
    }

    if (!this.cardStore.writeCard(path, merged)) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }
    this.invalidateAvatarThumbnail(avatarName);
    return HttpResponse.text('OK');
  }

  duplicateCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    if (avatarUrl.length === 0) {
      return HttpResponse.empty(400);
    }

    const avatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const source = joinPath(this.userDirs.characters, avatarName);
    if (!this.store.exists(source)) {
      return HttpResponse.empty(404);
    }

    const duplicateName = this.nextDuplicateAvatarName(avatarName);
    const target = joinPath(this.userDirs.characters, duplicateName);
    if (!this.store.copyFile(source, target)) {
      return HttpResponse.json(new ErrorFlagResponse());
    }

    const response = emptyJsonRecord();
    response['path'] = duplicateName;
    return HttpResponse.json(response);
  }

  renameCharacter(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    const requestedName = this.asString(body['new_name']);
    if (avatarUrl.length === 0 || requestedName.length === 0) {
      return HttpResponse.empty(400);
    }

    const oldAvatarName = ensurePngExtension(sanitizeFileName(avatarUrl));
    const oldInternalName = withoutExtension(oldAvatarName);
    const oldPath = joinPath(this.userDirs.characters, oldAvatarName);
    const oldBytes = this.store.readBytes(oldPath);
    if (oldBytes === null) {
      return HttpResponse.empty(404);
    }

    const card = this.cardStore.readCardFromBytes(oldBytes);
    if (card === null) {
      return HttpResponse.json(jsonMessage('failed_to_read_character'), 500);
    }

    const newName = sanitizeFileName(requestedName);
    const newInternalName = this.uniqueName(newName, this.userDirs.characters, '.png');
    const newAvatarName = `${newInternalName}.png`;
    const newPath = joinPath(this.userDirs.characters, newAvatarName);
    const normalized = this.normalizeCharacterCard(card);
    const data = this.asObject(normalized['data']) as JsonRecord;
    data['name'] = newName;
    normalized['data'] = data;
    normalized['name'] = newName;

    if (!this.cardStore.writeCardWithBase(newPath, oldBytes, normalized)) {
      return HttpResponse.json(jsonMessage('failed_to_write_character'), 500);
    }

    const oldChatsPath = joinPath(this.userDirs.chats, oldInternalName);
    const newChatsPath = joinPath(this.userDirs.chats, newInternalName);
    if (this.store.exists(oldChatsPath) && !this.store.exists(newChatsPath)) {
      if (this.store.copyDirectory(oldChatsPath, newChatsPath)) {
        this.store.deleteDirectory(oldChatsPath);
      }
    }
    this.store.deleteFile(oldPath);
    this.invalidateAvatarThumbnail(oldAvatarName);

    const response = emptyJsonRecord();
    response['avatar'] = newAvatarName;
    return HttpResponse.json(response);
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

  deleteChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    let chatFile = this.asString(body['chatfile']);
    if (avatarUrl.length === 0 || chatFile.length === 0) {
      return HttpResponse.empty(400);
    }
    chatFile = ensureJsonlExtension(sanitizeFileName(chatFile));
    const path = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)), chatFile);
    if (!this.store.deleteFile(path)) {
      return HttpResponse.empty(400);
    }
    return HttpResponse.json(new OkResponse());
  }

  renameChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const originalFile = sanitizeFileName(ensureJsonlExtension(this.asString(body['original_file'])));
    const renamedFile = sanitizeFileName(ensureJsonlExtension(this.asString(body['renamed_file'])));
    if (originalFile.length === 0 || renamedFile.length === 0) {
      return HttpResponse.empty(400);
    }

    const directory = body['is_group'] === true ? this.userDirs.groupChats :
      joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(this.asString(body['avatar_url']))));
    if (directory.length === 0) {
      return HttpResponse.empty(400);
    }

    const source = joinPath(directory, originalFile);
    const target = joinPath(directory, renamedFile);
    if (!this.store.exists(source) || this.store.exists(target)) {
      return HttpResponse.json(new ErrorFlagResponse(), 400);
    }
    if (!this.store.copyFile(source, target)) {
      return HttpResponse.json(new ErrorFlagResponse(), 500);
    }
    this.store.deleteFile(source);

    const response = emptyJsonRecord();
    response['ok'] = true;
    response['sanitizedFileName'] = withoutExtension(renamedFile);
    return HttpResponse.json(response);
  }

  importChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const avatarUrl = this.asString(body['avatar_url']);
    const fileType = this.asString(body['file_type']).toLowerCase();
    const file = request.file('avatar');
    if (avatarUrl.length === 0 || fileType.length === 0 || file === null) {
      return HttpResponse.empty(400);
    }

    const directory = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)));
    this.store.ensureDir(directory);
    const characterName = sanitizeFileName(this.asString(body['character_name']) || 'Character');
    const userName = sanitizeFileName(this.asString(body['user_name']) || 'User');
    const imported = this.importChatTexts(file.bytes, fileType, userName, characterName);
    if (imported.length === 0) {
      return HttpResponse.json(new ErrorFlagResponse());
    }

    const fileNames: string[] = [];
    for (const chatText of imported) {
      const fileName = this.uniqueChatImportFileName(directory, characterName);
      this.store.writeText(joinPath(directory, fileName), chatText);
      fileNames.push(fileName);
    }
    const response = emptyJsonRecord();
    response['res'] = true;
    response['fileNames'] = fileNames;
    return HttpResponse.json(response);
  }

  importGroupChat(request: HttpRequest): HttpResponse {
    const file = request.file('avatar');
    if (file === null) {
      return HttpResponse.empty(400);
    }

    const chatText = this.decoder.decodeToString(file.bytes);
    if (!this.looksLikeJsonlChat(chatText)) {
      return HttpResponse.json(new ErrorFlagResponse());
    }

    const chatId = this.uniqueName(this.humanizedDateTime(), this.userDirs.groupChats, '.jsonl');
    this.store.writeText(joinPath(this.userDirs.groupChats, `${chatId}.jsonl`), chatText);
    const response = emptyJsonRecord();
    response['res'] = chatId;
    return HttpResponse.json(response);
  }

  async exportChat(request: HttpRequest): Promise<HttpResponse> {
    const body = this.bodyAsRecord(request);
    const file = sanitizeFileName(ensureJsonlExtension(this.asString(body['file'])));
    const format = this.asString(body['format']).toLowerCase() || 'txt';
    if (file.length === 0) {
      return HttpResponse.empty(400);
    }

    const directory = body['is_group'] === true ? this.userDirs.groupChats :
      joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(this.asString(body['avatar_url']))));
    const sourcePath = joinPath(directory, file);
    const sourceText = this.store.readText(sourcePath, '');
    if (sourceText.length === 0 && !this.store.exists(sourcePath)) {
      return HttpResponse.json(jsonMessage('not_found', `Could not find JSONL file to export. Source chat file: ${sourcePath}.`),
        404);
    }

    const exportName = sanitizeFileName(this.asString(body['exportfilename'])) ||
      `${withoutExtension(file)}.${format === 'jsonl' ? 'jsonl' : 'txt'}`;
    const exportText = format === 'jsonl' ? sourceText : this.chatJsonlToText(sourceText);
    const extension = format === 'jsonl' ? '.jsonl' : '.txt';
    const exported = this.shareExports.writeExportFile('chats', exportName, this.encoder.encodeInto(exportText),
      ShareExportService.contentTypeForExtension(extension), ShareExportService.utdForExtension(extension));
    return this.shareExports.shareHttpResponse(exported, exportName);
  }

  searchChats(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const query = this.asString(body['query']).trim().toLowerCase();
    const groupId = this.asString(body['group_id']);
    const files: FileEntry[] = [];

    if (groupId.length > 0) {
      const group = this.findGroupById(groupId);
      const chats = this.asArray(group['chats']);
      for (const chat of chats) {
        const fileName = ensureJsonlExtension(sanitizeFileName(`${chat}`));
        const entry = this.store.stat(joinPath(this.userDirs.groupChats, fileName), fileName);
        if (entry !== null && entry.isFile) {
          files.push(entry);
        }
      }
    } else {
      const avatarUrl = this.asString(body['avatar_url']);
      if (avatarUrl.length === 0) {
        return HttpResponse.json([]);
      }
      const directory = joinPath(this.userDirs.chats, withoutExtension(sanitizeFileName(avatarUrl)));
      files.push(...this.store.listFilesByExtension(directory, '.jsonl'));
    }

    const results: ChatSearchResponse[] = [];
    for (const file of files) {
      const rows = this.readChatFile(file.path);
      const row = this.chatSearchInfo(file, rows);
      const match = query.length === 0 || this.chatMatchesQuery(withoutExtension(file.name), rows, query);
      if (match) {
        results.push(row);
      }
    }
    return HttpResponse.json(results);
  }

  getGroupChat(request: HttpRequest): HttpResponse {
    const id = sanitizeFileName(this.asString(this.bodyAsRecord(request)['id']));
    if (id.length === 0) {
      return HttpResponse.empty(400);
    }
    return HttpResponse.json(this.readChatFile(joinPath(this.userDirs.groupChats, ensureJsonlExtension(id))));
  }

  saveGroupChat(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const id = sanitizeFileName(this.asString(body['id']));
    const chat = body['chat'];
    if (id.length === 0 || !Array.isArray(chat)) {
      return HttpResponse.json(jsonMessage('id and chat[] are required'), 400);
    }
    const jsonl = chat.map((item: Object | string | number | boolean | null) => JSON.stringify(item)).join('\n');
    this.store.writeText(joinPath(this.userDirs.groupChats, ensureJsonlExtension(id)), jsonl);
    return HttpResponse.json(new OkResponse());
  }

  deleteGroupChat(request: HttpRequest): HttpResponse {
    const id = sanitizeFileName(this.asString(this.bodyAsRecord(request)['id']));
    if (id.length === 0) {
      return HttpResponse.empty(400);
    }
    if (!this.store.deleteFile(joinPath(this.userDirs.groupChats, ensureJsonlExtension(id)))) {
      return HttpResponse.empty(400);
    }
    return HttpResponse.json(new OkResponse());
  }

  groupChatInfo(request: HttpRequest): HttpResponse {
    const id = sanitizeFileName(this.asString(this.bodyAsRecord(request)['id']));
    if (id.length === 0) {
      return HttpResponse.empty(400);
    }
    const fileName = ensureJsonlExtension(id);
    const path = joinPath(this.userDirs.groupChats, fileName);
    const entry = this.store.stat(path, fileName);
    if (entry === null || !entry.isFile) {
      return HttpResponse.json(emptyJsonRecord());
    }
    return HttpResponse.json(this.chatInfo(entry, this.readChatFile(path)));
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

  private statsPath(): string {
    return joinPath(this.userDirs.root, 'stats.json');
  }

  private collectStats(): JsonRecord {
    const result = emptyJsonRecord();
    const characters = this.store.listFilesByExtension(this.userDirs.characters, '.png');
    for (const character of characters) {
      result[character.name] = this.calculateCharacterStats(joinPath(this.userDirs.chats, withoutExtension(character.name)));
    }
    return result;
  }

  private calculateCharacterStats(chatDir: string): JsonRecord {
    const stats = emptyJsonRecord();
    stats['total_gen_time'] = 0;
    stats['user_word_count'] = 0;
    stats['non_user_word_count'] = 0;
    stats['user_msg_count'] = 0;
    stats['non_user_msg_count'] = 0;
    stats['total_swipe_count'] = 0;
    stats['chat_size'] = 0;
    stats['date_last_chat'] = 0;
    stats['date_first_chat'] = new Date('9999-12-31T23:59:59.999Z').getTime();

    for (const file of this.store.list(chatDir)) {
      if (!file.isFile) {
        continue;
      }
      const rows = this.readChatRowsFromText(this.store.readText(file.path, ''));
      stats['chat_size'] = Number(stats['chat_size'] ?? 0) + file.size;
      stats['date_last_chat'] = Math.max(Number(stats['date_last_chat'] ?? 0), Math.floor(file.mtimeMs));
      for (const row of rows) {
        const message = row as JsonRecord;
        this.addMessageStats(stats, message);
      }
    }

    return stats;
  }

  private addMessageStats(stats: JsonRecord, message: JsonRecord): void {
    const text = this.asString(message['mes']);
    if (text.length > 0) {
      const words = this.countWords(text);
      if (message['is_user'] === true) {
        stats['user_word_count'] = Number(stats['user_word_count'] ?? 0) + words;
        stats['user_msg_count'] = Number(stats['user_msg_count'] ?? 0) + 1;
        const timestamp = this.parseTimestamp(this.asString(message['send_date']));
        if (timestamp > 0) {
          stats['date_first_chat'] = Math.min(Number(stats['date_first_chat'] ?? timestamp), timestamp);
        }
      } else {
        stats['non_user_word_count'] = Number(stats['non_user_word_count'] ?? 0) + words;
        stats['non_user_msg_count'] = Number(stats['non_user_msg_count'] ?? 0) + 1;
      }
    }

    const genStarted = this.asString(message['gen_started']);
    const genFinished = this.asString(message['gen_finished']);
    if (genStarted.length > 0 && genFinished.length > 0) {
      stats['total_gen_time'] = Number(stats['total_gen_time'] ?? 0) + Math.max(0,
        this.parseTimestamp(genFinished) - this.parseTimestamp(genStarted));
    }

    const swipes = this.asArray(message['swipes']);
    if (swipes.length > 1) {
      stats['total_swipe_count'] = Number(stats['total_swipe_count'] ?? 0) + swipes.length - 1;
      for (let index = 1; index < swipes.length; index += 1) {
        const words = this.countWords(this.asString(swipes[index] as JsonValue));
        if (message['is_user'] === true) {
          stats['user_word_count'] = Number(stats['user_word_count'] ?? 0) + words;
          stats['user_msg_count'] = Number(stats['user_msg_count'] ?? 0) + 1;
        } else {
          stats['non_user_word_count'] = Number(stats['non_user_word_count'] ?? 0) + words;
          stats['non_user_msg_count'] = Number(stats['non_user_msg_count'] ?? 0) + 1;
        }
      }
    }
  }

  private countWords(text: string): number {
    const matches = text.match(/\b\w+\b/g);
    return matches === null ? 0 : matches.length;
  }

  private parseTimestamp(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const value = new Date(text).getTime();
    return Number.isFinite(value) ? value : 0;
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
      const text = this.store.readText(file.path, '');
      if (text.length === 0 || !this.isValidJson(text)) {
        continue;
      }
      result.fileContents.push(text);
      result.fileNames.push(withoutExtension(file.name));
    }
    return result;
  }

  private isValidJson(text: string): boolean {
    try {
      JSON.parse(text);
      return true;
    } catch (_err) {
      return false;
    }
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

  private withoutJsonData(source: JsonRecord): JsonRecord {
    const target = emptyJsonRecord();
    Object.keys(source).forEach((key: string) => {
      if (key !== 'json_data') {
        target[key] = source[key];
      }
    });
    return target;
  }

  private deepMergeRecord(base: JsonRecord, update: JsonRecord): JsonRecord {
    const result = this.cloneRecord(base);
    Object.keys(update).forEach((key: string) => {
      if (key === 'json_data') {
        return;
      }
      const updateValue = update[key];
      const baseValue = result[key];
      if (this.isPlainRecord(baseValue) && this.isPlainRecord(updateValue)) {
        result[key] = this.deepMergeRecord(baseValue as JsonRecord, updateValue as JsonRecord);
      } else {
        result[key] = this.cloneJsonValue(updateValue);
      }
    });
    return result;
  }

  private cloneRecord(source: JsonRecord): JsonRecord {
    const result = emptyJsonRecord();
    Object.keys(source).forEach((key: string) => {
      result[key] = this.cloneJsonValue(source[key]);
    });
    return result;
  }

  private cloneJsonValue(value: JsonValue | JsonArray | undefined): JsonValue | JsonArray {
    if (Array.isArray(value)) {
      const arrayCopy: JsonArray = [];
      for (let index = 0; index < value.length; index += 1) {
        const item = value[index] as JsonValue;
        arrayCopy.push(this.cloneJsonValue(item) as JsonValue);
      }
      return arrayCopy;
    }
    if (this.isPlainRecord(value)) {
      return this.cloneRecord(value as JsonRecord);
    }
    return value ?? null;
  }

  private isPlainRecord(value: JsonValue | JsonArray | undefined): boolean {
    return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  private validateCharacterCardForSave(card: JsonRecord): string {
    const name = this.asString(card['name']);
    const data = this.asObject(card['data']) as JsonRecord;
    const dataName = this.asString(data['name']);
    if (name.length === 0 && dataName.length === 0) {
      return 'name is required';
    }
    if (card['spec'] !== undefined && this.asString(card['spec']).length === 0) {
      return 'spec is invalid';
    }
    if (card['data'] !== undefined && !this.isPlainRecord(card['data'])) {
      return 'data must be an object';
    }
    return '';
  }

  private nextDuplicateAvatarName(avatarName: string): string {
    const ext = this.extensionOf(avatarName) || '.png';
    const stem = withoutExtension(avatarName);
    const parts = stem.split('_');
    const last = parts.length > 0 ? parts[parts.length - 1] : '';
    let suffix = 1;
    let baseName = stem;
    if (parts.length > 1 && this.isDigits(last)) {
      suffix = Number(last) + 1;
      baseName = parts.slice(0, parts.length - 1).join('_');
    }

    let candidate = `${baseName}_${suffix}${ext}`;
    while (this.store.exists(joinPath(this.userDirs.characters, candidate))) {
      suffix += 1;
      candidate = `${baseName}_${suffix}${ext}`;
    }
    return sanitizeFileName(candidate);
  }

  private isDigits(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let index = 0; index < value.length; index += 1) {
      const code = value.charCodeAt(index);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private invalidateAvatarThumbnail(avatarName: string): void {
    this.store.deleteFile(joinPath(this.userDirs.thumbnailsAvatar, sanitizeFileName(avatarName)));
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

  private importChatTexts(bytes: Uint8Array, fileType: string, userName: string, characterName: string): string[] {
    const text = this.stripJsonBom(this.decoder.decodeToString(bytes));
    if (fileType === 'jsonl') {
      return this.looksLikeJsonlChat(text) ? [text] : [];
    }
    if (fileType !== 'json') {
      return [];
    }

    const parsed = this.parseJsonValue(text);
    if (parsed === null) {
      return [];
    }
    if (Array.isArray(parsed)) {
      const rows: Object[] = [];
      for (let index = 0; index < parsed.length; index += 1) {
        const item = parsed[index] as JsonValue;
        if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
          rows.push(item as Object);
        }
      }
      return rows.length > 0 ? [this.chatRowsToJsonl(rows)] : [];
    }
    if (typeof parsed !== 'object') {
      return [];
    }

    const record = parsed as JsonRecord;
    if (Array.isArray(record['data_visible'])) {
      return [this.importOobaChat(userName, characterName, record['data_visible'] as JsonArray)];
    }
    if (Array.isArray(record['messages'])) {
      return [this.importAgnaiChat(userName, characterName, record['messages'] as JsonArray)];
    }
    if (record['savedsettings'] !== undefined && Array.isArray(record['actions'])) {
      return [this.importKoboldLiteChat(record)];
    }
    return [];
  }

  private looksLikeJsonlChat(text: string): boolean {
    const rows = this.readChatRowsFromText(text);
    if (rows.length === 0) {
      return false;
    }
    const header = rows[0] as JsonRecord;
    return header['user_name'] !== undefined || header['name'] !== undefined || header['chat_metadata'] !== undefined;
  }

  private readChatRowsFromText(text: string): Object[] {
    const rows: Object[] = [];
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      try {
        const parsed = JSON.parse(trimmed) as Object;
        if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          rows.push(parsed);
        }
      } catch (_err) {
      }
    }
    return rows;
  }

  private chatRowsToJsonl(rows: Object[]): string {
    return rows.map((row: Object) => JSON.stringify(row)).join('\n');
  }

  private importOobaChat(userName: string, characterName: string, visibleRows: JsonArray): string {
    const rows: Object[] = [this.chatHeader()];
    for (const item of visibleRows) {
      if (!Array.isArray(item)) {
        continue;
      }
      const userMessage = this.asString(item[0] as JsonValue);
      const characterMessage = this.asString(item[1] as JsonValue);
      if (userMessage.length > 0) {
        rows.push(this.chatMessage(userName, true, userMessage));
      }
      if (characterMessage.length > 0) {
        rows.push(this.chatMessage(characterName, false, characterMessage));
      }
    }
    return this.chatRowsToJsonl(rows);
  }

  private importAgnaiChat(userName: string, characterName: string, messages: JsonArray): string {
    const rows: Object[] = [this.chatHeader()];
    for (const item of messages) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const isUser = message['userId'] !== undefined && this.asString(message['userId']).length > 0;
      rows.push(this.chatMessage(isUser ? userName : characterName, isUser, this.asString(message['msg'])));
    }
    return this.chatRowsToJsonl(rows);
  }

  private importKoboldLiteChat(record: JsonRecord): string {
    const savedSettings = this.asObject(record['savedsettings']) as JsonRecord;
    const userName = this.asString(savedSettings['chatname']) || 'User';
    const characterName = this.asString(savedSettings['chatopponent']).split('||$||')[0] || 'Character';
    const rows: Object[] = [this.chatHeader()];
    const prompt = this.asString(record['prompt']);
    if (prompt.length > 0) {
      rows.push(this.koboldLiteMessage(userName, characterName, prompt));
    }
    for (const action of this.asArray(record['actions'])) {
      const actionText = this.asString(action as JsonValue);
      if (actionText.length > 0) {
        rows.push(this.koboldLiteMessage(userName, characterName, actionText));
      }
    }
    return this.chatRowsToJsonl(rows);
  }

  private koboldLiteMessage(userName: string, characterName: string, text: string): Object {
    const inputToken = '{{[INPUT]}}';
    const outputToken = '{{[OUTPUT]}}';
    const isUser = text.includes(inputToken);
    const mes = text.replace(inputToken, '').replace(outputToken, '').trim();
    return this.chatMessage(isUser ? userName : characterName, isUser, mes);
  }

  private chatHeader(): JsonRecord {
    const header = emptyJsonRecord();
    header['chat_metadata'] = emptyJsonRecord();
    header['user_name'] = 'unused';
    header['character_name'] = 'unused';
    return header;
  }

  private chatMessage(name: string, isUser: boolean, message: string): JsonRecord {
    const row = emptyJsonRecord();
    row['name'] = name;
    row['is_user'] = isUser;
    row['send_date'] = new Date().toISOString();
    row['mes'] = message;
    row['extra'] = emptyJsonRecord();
    return row;
  }

  private uniqueChatImportFileName(directory: string, characterName: string): string {
    const baseName = `${characterName} - ${this.humanizedDateTime()} imported`;
    return `${this.uniqueName(baseName, directory, '.jsonl')}.jsonl`;
  }

  private humanizedDateTime(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} @${pad(date.getHours())}h ${pad(date.getMinutes())}m ${pad(date.getSeconds())}s`;
  }

  private parseJsonValue(text: string): JsonValue | JsonArray | null {
    try {
      return JSON.parse(text) as JsonValue | JsonArray;
    } catch (_err) {
      return null;
    }
  }

  private chatInfo(file: FileEntry, rows: Object[]): JsonRecord {
    const result = emptyJsonRecord();
    result['match'] = true;
    result['file_id'] = withoutExtension(file.name);
    result['file_name'] = file.name;
    result['file_size'] = this.formatBytes(file.size);
    result['chat_items'] = Math.max(0, rows.length - 1);
    result['mes'] = '[The chat is empty]';
    result['last_mes'] = new Date(Math.round(file.mtimeMs)).toISOString();

    if (rows.length > 0) {
      const last = rows[rows.length - 1] as JsonRecord;
      result['mes'] = this.asString(last['mes']) || '[The message is empty]';
      result['last_mes'] = this.asString(last['send_date']) || result['last_mes'];
    }
    return result;
  }

  private chatSearchInfo(file: FileEntry, rows: Object[]): ChatSearchResponse {
    const info = this.chatInfo(file, rows);
    const row = new ChatSearchResponse();
    row.file_name = withoutExtension(file.name);
    row.file_size = this.asString(info['file_size']);
    row.message_count = Number(info['chat_items'] ?? 0);
    row.last_mes = this.asString(info['last_mes']);
    row.preview_message = this.previewMessage(this.asString(info['mes']));
    return row;
  }

  private previewMessage(message: string): string {
    const maxLength = 400;
    if (message.length <= maxLength) {
      return message;
    }
    return `...${message.slice(message.length - maxLength)}`;
  }

  private chatMatchesQuery(fileId: string, rows: Object[], query: string): boolean {
    const fragments = query.split(/\s+/).filter((fragment: string) => fragment.length > 0);
    if (fragments.length === 0) {
      return true;
    }
    const texts: string[] = [fileId.toLowerCase()];
    for (const row of rows) {
      const record = row as JsonRecord;
      texts.push(this.asString(record['mes']).toLowerCase());
      texts.push(this.asString(record['name']).toLowerCase());
    }
    for (const fragment of fragments) {
      let found = false;
      for (const text of texts) {
        if (text.includes(fragment)) {
          found = true;
          break;
        }
      }
      if (!found) {
        return false;
      }
    }
    return true;
  }

  private chatJsonlToText(jsonl: string): string {
    const rows = this.readChatRowsFromText(jsonl);
    let output = '';
    for (const row of rows) {
      const record = row as JsonRecord;
      if (record['is_system'] === true) {
        continue;
      }
      const message = this.asString(record['mes']);
      if (message.length === 0) {
        continue;
      }
      const extra = this.asObject(record['extra']) as JsonRecord;
      const displayText = this.asString(extra['display_text']) || message;
      output += `${this.asString(record['name'])}: ${displayText.replace(/\r?\n/g, '\n')}\n\n`;
    }
    return output;
  }

  private findGroupById(id: string): JsonRecord {
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      if (this.asString(group['id']) === id) {
        return group;
      }
    }
    return emptyJsonRecord();
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
