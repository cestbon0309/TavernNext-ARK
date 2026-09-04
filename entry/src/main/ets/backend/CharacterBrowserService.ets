import { DiagnosticLogService as hilog } from './DiagnosticLogService';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DataDirectories } from './DataDirectories';
import { FileStore } from './FileStore';
import { JsonArray, JsonRecord, emptyJsonRecord } from './HttpTypes';
import { asArray, asBoolean, asNumber, asRecord, asString } from './JsonUtils';
import { joinPath } from './PathUtils';
import { RemoteHttpClient, RemoteHttpResult } from './RemoteHttpClient';

const CHARACTER_BROWSER_CACHE_FILE = 'character-browser-cache.json';
const CHARACTER_IMPORT_MAX_BYTES = 32 * 1024 * 1024;
const DOMAIN = 0x5441;
const TAG = 'TavernCharacterBrowser';

type CharacterBrowserListProvider = () => Promise<Object[]>;
type CharacterBrowserThumbnailProvider = () => Promise<number>;
export type CharacterBrowserRefreshListener = (items: CharacterBrowserItem[]) => void;

export class CharacterBrowserItem {
  id: string = '';
  avatar: string = '';
  name: string = '';
  chat: string = '';
  favorite: boolean = false;
  tags: string[] = [];
  dateAddedMs: number = 0;
  dateLastChatMs: number = 0;
  chatSizeBytes: number = 0;
  dataSizeBytes: number = 0;
  description: string = '';
  personality: string = '';
  scenario: string = '';
  firstMessage: string = '';
  exampleMessages: string = '';
  creatorNotes: string = '';
  creator: string = '';
  version: string = '';
  talkativeness: number = 0.5;
  depthPrompt: string = '';
  depth: number = 4;
  depthRole: string = 'system';
  alternateGreetings: string[] = [];
  jsonData: string = '';
  data: JsonRecord = {};

  clone(): CharacterBrowserItem {
    const item = new CharacterBrowserItem();
    item.id = this.id;
    item.avatar = this.avatar;
    item.name = this.name;
    item.chat = this.chat;
    item.favorite = this.favorite;
    item.tags = [...this.tags];
    item.dateAddedMs = this.dateAddedMs;
    item.dateLastChatMs = this.dateLastChatMs;
    item.chatSizeBytes = this.chatSizeBytes;
    item.dataSizeBytes = this.dataSizeBytes;
    item.description = this.description;
    item.personality = this.personality;
    item.scenario = this.scenario;
    item.firstMessage = this.firstMessage;
    item.exampleMessages = this.exampleMessages;
    item.creatorNotes = this.creatorNotes;
    item.creator = this.creator;
    item.version = this.version;
    item.talkativeness = this.talkativeness;
    item.depthPrompt = this.depthPrompt;
    item.depth = this.depth;
    item.depthRole = this.depthRole;
    item.alternateGreetings = [...this.alternateGreetings];
    item.jsonData = this.jsonData;
    item.data = this.data;
    return item;
  }
}

export class CharacterBrowserChatItem {
  fileName: string = '';
  fileId: string = '';
  messageCount: number = 0;
  preview: string = '';
  lastMessage: string = '';
  fileSizeBytes: number = 0;
  lastChatMs: number = 0;
}

export class CharacterBrowserService {
  private http: RemoteHttpClient = new RemoteHttpClient();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private store: FileStore | null = null;
  private cachePath: string = '';
  private listProvider: CharacterBrowserListProvider | null = null;
  private thumbnailProvider: CharacterBrowserThumbnailProvider | null = null;
  private cachedItems: CharacterBrowserItem[] = [];
  private cacheLoaded: boolean = false;
  private cacheRefreshedAt: number = 0;
  private refreshListeners: CharacterBrowserRefreshListener[] = [];
  private refreshPromise: Promise<CharacterBrowserItem[]> | null = null;
  private cacheLoadPromise: Promise<CharacterBrowserItem[]> | null = null;
  private thumbnailPromise: Promise<number> | null = null;
  private refreshScheduled: boolean = false;
  private refreshPending: boolean = false;

  constructor(store?: FileStore, dirs?: DataDirectories, listProvider?: CharacterBrowserListProvider,
    thumbnailProvider?: CharacterBrowserThumbnailProvider) {
    if (store !== undefined && dirs !== undefined && listProvider !== undefined) {
      this.store = store;
      this.cachePath = joinPath(dirs.storageRoot, CHARACTER_BROWSER_CACHE_FILE);
      this.listProvider = listProvider;
      this.thumbnailProvider = thumbnailProvider ?? null;
    }
  }

  ensureThumbnailsAsync(): Promise<number> {
    if (this.thumbnailProvider === null) {
      return Promise.resolve(0);
    }
    if (this.thumbnailPromise === null) {
      this.thumbnailPromise = this.thumbnailProvider().finally(() => {
        this.thumbnailPromise = null;
      });
    }
    return this.thumbnailPromise;
  }

  subscribeRefresh(listener: CharacterBrowserRefreshListener): void {
    if (!this.refreshListeners.includes(listener)) {
      this.refreshListeners.push(listener);
    }
  }

  unsubscribeRefresh(listener: CharacterBrowserRefreshListener): void {
    const index = this.refreshListeners.indexOf(listener);
    if (index >= 0) {
      this.refreshListeners.splice(index, 1);
    }
  }

  cachedList(): CharacterBrowserItem[] {
    return this.cachedItems;
  }

  hasCachedList(): boolean {
    return this.cacheLoaded && this.cacheRefreshedAt > 0;
  }

  updateFavoriteCache(avatar: string, favorite: boolean): void {
    const item = this.cachedItems.find((candidate: CharacterBrowserItem): boolean => {
      return candidate.avatar === avatar || candidate.id === avatar;
    });
    if (item === undefined) {
      return;
    }
    item.favorite = favorite;
    this.writeCacheAsync().catch((_err: Error) => {
      hilog.error(DOMAIN, TAG, 'favorite cache write failed');
    });
  }

  initializeCacheAsync(): Promise<CharacterBrowserItem[]> {
    if (this.cacheLoaded && this.cacheRefreshedAt > 0) {
      return Promise.resolve(this.cachedItems);
    }
    if (this.cacheLoadPromise === null) {
      this.cacheLoadPromise = this.loadCacheAsync().finally(() => {
        this.cacheLoadPromise = null;
      });
    }
    return this.cacheLoadPromise.then((items: CharacterBrowserItem[]): Promise<CharacterBrowserItem[]> => {
      if (this.cacheRefreshedAt > 0) {
        this.scheduleRefresh();
        return Promise.resolve(items);
      }
      return this.refreshCacheAsync();
    });
  }

  refreshCacheAsync(): Promise<CharacterBrowserItem[]> {
    if (this.refreshPromise !== null) {
      return this.refreshPromise;
    }
    this.refreshPromise = this.rebuildCacheAsync();
    return this.refreshPromise;
  }

  scheduleRefresh(): void {
    if (this.refreshPromise !== null) {
      this.refreshPending = true;
      return;
    }
    if (this.refreshScheduled) {
      return;
    }
    this.refreshScheduled = true;
    setTimeout(() => {
      this.refreshScheduled = false;
      if (this.refreshPromise !== null) {
        this.refreshPending = true;
        return;
      }
      this.refreshCacheAsync().catch((_err: Error) => {
        hilog.error(DOMAIN, TAG, 'scheduled cache refresh failed');
      });
    }, 0);
  }

  async list(baseUrl: string): Promise<CharacterBrowserItem[]> {
    const body: JsonRecord = {};
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/all'), body);
    if (!this.isSuccess(result)) {
      throw new Error(`characters/all ${result.statusCode}`);
    }
    const parsed = this.parseArray(result.text);
    return parsed.map((value: JsonRecord): CharacterBrowserItem => this.itemFromRecord(value, true));
  }

  async get(baseUrl: string, avatar: string): Promise<CharacterBrowserItem> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/get'), body);
    if (!this.isSuccess(result)) {
      throw new Error(`characters/get ${result.statusCode}`);
    }
    return this.itemFromRecord(this.parseRecord(result.text), false);
  }

  async create(baseUrl: string, name: string): Promise<boolean> {
    const body: JsonRecord = {};
    body['ch_name'] = name;
    body['description'] = '';
    body['personality'] = '';
    body['scenario'] = '';
    body['first_mes'] = '';
    body['mes_example'] = '';
    body['creator_notes'] = '';
    body['tags'] = [];
    body['alternate_greetings'] = [];
    body['talkativeness'] = 0.5;
    body['depth_prompt_depth'] = 4;
    body['depth_prompt_role'] = 'system';
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/create'), body);
    return this.isSuccess(result);
  }

  async importFromUri(baseUrl: string, uri: string): Promise<boolean> {
    const bytes = await this.readUriBytes(uri);
    if (bytes === null) {
      return false;
    }
    return this.importBytes(baseUrl, bytes, this.fileNameFromUri(uri), '');
  }

  async importFromUrl(baseUrl: string, url: string): Promise<boolean> {
    const result = await this.http.getBytes(url, {}, 120000, CHARACTER_IMPORT_MAX_BYTES);
    if (!this.isSuccess(result) || result.bytes === null) {
      return false;
    }
    const contentType = result.headers['content-type'] ?? '';
    return this.importBytes(baseUrl, result.bytes, this.fileNameFromUrl(url), contentType);
  }

  async save(baseUrl: string, item: CharacterBrowserItem): Promise<boolean> {
    const data = this.copyData(item.data);
    data['name'] = item.name;
    data['description'] = item.description;
    data['personality'] = item.personality;
    data['scenario'] = item.scenario;
    data['first_mes'] = item.firstMessage;
    data['mes_example'] = item.exampleMessages;
    data['creator_notes'] = item.creatorNotes;
    data['creator'] = item.creator;
    data['character_version'] = item.version;
    data['tags'] = [...item.tags];
    data['alternate_greetings'] = [...item.alternateGreetings];

    const extensions = asRecord(data['extensions']);
    extensions['talkativeness'] = item.talkativeness;
    extensions['fav'] = item.favorite;
    const depthPrompt = asRecord(extensions['depth_prompt']);
    depthPrompt['prompt'] = item.depthPrompt;
    depthPrompt['depth'] = item.depth;
    depthPrompt['role'] = item.depthRole;
    extensions['depth_prompt'] = depthPrompt;
    data['extensions'] = extensions;

    const payload: JsonRecord = {};
    payload['avatar'] = item.avatar;
    payload['avatar_url'] = item.avatar;
    payload['name'] = item.name;
    payload['description'] = item.description;
    payload['personality'] = item.personality;
    payload['scenario'] = item.scenario;
    payload['first_mes'] = item.firstMessage;
    payload['mes_example'] = item.exampleMessages;
    payload['creator_notes'] = item.creatorNotes;
    payload['creator'] = item.creator;
    payload['character_version'] = item.version;
    payload['tags'] = [...item.tags];
    payload['fav'] = item.favorite;
    payload['talkativeness'] = item.talkativeness;
    payload['data'] = data;

    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/merge-attributes'), payload);
    return this.isSuccess(result);
  }

  async setFavorite(baseUrl: string, avatar: string, favorite: boolean): Promise<boolean> {
    const payload: JsonRecord = {};
    payload['avatar'] = avatar;
    payload['favorite'] = favorite;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/ohos/characters/favorite'), payload);
    return this.isSuccess(result);
  }

  async rename(baseUrl: string, avatar: string, name: string): Promise<string> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    body['new_name'] = name;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/rename'), body);
    if (!this.isSuccess(result)) {
      throw new Error(`characters/rename ${result.statusCode}`);
    }
    return asString(this.parseRecord(result.text)['avatar']);
  }

  async duplicate(baseUrl: string, avatar: string): Promise<string> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/duplicate'), body);
    if (!this.isSuccess(result)) {
      throw new Error(`characters/duplicate ${result.statusCode}`);
    }
    return asString(this.parseRecord(result.text)['path']);
  }

  async delete(baseUrl: string, avatar: string, deleteChats: boolean): Promise<boolean> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    body['delete_chats'] = deleteChats;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/delete'), body);
    return this.isSuccess(result);
  }

  async chats(baseUrl: string, avatar: string): Promise<CharacterBrowserChatItem[]> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/chats'), body);
    if (!this.isSuccess(result)) {
      throw new Error(`characters/chats ${result.statusCode}`);
    }
    const parsed = this.parseArray(result.text);
    return parsed.map((value: JsonRecord): CharacterBrowserChatItem => {
      const item = new CharacterBrowserChatItem();
      item.fileName = asString(value['file_name']);
      item.fileId = asString(value['file_id']);
      item.messageCount = asNumber(value['chat_items']);
      item.preview = asString(value['mes']);
      item.lastMessage = asString(value['last_mes']);
      item.fileSizeBytes = asNumber(value['file_size']);
      item.lastChatMs = asNumber(value['date_last_chat']);
      return item;
    });
  }

  async export(baseUrl: string, avatar: string, format: string): Promise<boolean> {
    const body: JsonRecord = {};
    body['avatar_url'] = avatar;
    body['format'] = format;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/export'), body);
    if (!this.isSuccess(result)) {
      return false;
    }
    return asBoolean(this.parseRecord(result.text)['shared']);
  }

  private async importBytes(baseUrl: string, bytes: Uint8Array, fileName: string,
    contentType: string): Promise<boolean> {
    if (bytes.byteLength === 0 || bytes.byteLength > CHARACTER_IMPORT_MAX_BYTES) {
      return false;
    }
    const fileType = this.importFileType(fileName, contentType, bytes);
    if (fileType.length === 0) {
      return false;
    }
    const safeName = this.multipartFileName(fileName, fileType);
    const boundary = `TavernNextCharacter${Date.now()}`;
    const fieldPart = this.encoder.encodeInto(`--${boundary}\r\n` +
      'Content-Disposition: form-data; name="file_type"\r\n\r\n' +
      `${fileType}\r\n`);
    const filePart = this.encoder.encodeInto(`--${boundary}\r\n` +
      `Content-Disposition: form-data; name="avatar"; filename="${safeName}"\r\n` +
      `Content-Type: ${fileType === 'png' ? 'image/png' : 'application/json'}\r\n\r\n`);
    const suffix = this.encoder.encodeInto(`\r\n--${boundary}--\r\n`);
    const body = new Uint8Array(fieldPart.byteLength + filePart.byteLength + bytes.byteLength + suffix.byteLength);
    body.set(fieldPart, 0);
    body.set(filePart, fieldPart.byteLength);
    body.set(bytes, fieldPart.byteLength + filePart.byteLength);
    body.set(suffix, fieldPart.byteLength + filePart.byteLength + bytes.byteLength);
    const headers: Record<string, string> = {
      'Content-Type': `multipart/form-data; boundary=${boundary}`
    };
    const result = await this.http.postBytes(this.http.joinUrl(baseUrl, '/api/characters/import'), body, headers);
    return this.isSuccess(result) && asString(this.parseRecord(result.text)['file_name']).length > 0;
  }

  private async readUriBytes(uri: string): Promise<Uint8Array | null> {
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(file.fd);
      const size = Number(stat.size);
      if (size <= 0 || size > CHARACTER_IMPORT_MAX_BYTES) {
        return null;
      }
      const buffer = new ArrayBuffer(size);
      const readLength = await fileIo.read(file.fd, buffer, { offset: 0, length: size });
      return new Uint8Array(buffer).slice(0, readLength);
    } catch (_err) {
      return null;
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (_err) {
        }
      }
    }
  }

  private importFileType(fileName: string, contentType: string, bytes: Uint8Array): string {
    const normalizedName = fileName.toLowerCase();
    const normalizedType = contentType.toLowerCase();
    if (normalizedName.endsWith('.png') || normalizedType.includes('image/png') || this.isPng(bytes)) {
      return 'png';
    }
    if (normalizedName.endsWith('.json') || normalizedType.includes('application/json') ||
      normalizedType.includes('text/json') || this.isJson(bytes)) {
      return 'json';
    }
    return '';
  }

  private isPng(bytes: Uint8Array): boolean {
    return bytes.byteLength >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E &&
      bytes[3] === 0x47 && bytes[4] === 0x0D && bytes[5] === 0x0A && bytes[6] === 0x1A && bytes[7] === 0x0A;
  }

  private isJson(bytes: Uint8Array): boolean {
    let index = bytes.byteLength >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF ? 3 : 0;
    while (index < bytes.byteLength && (bytes[index] === 0x20 || bytes[index] === 0x09 || bytes[index] === 0x0A ||
      bytes[index] === 0x0D)) {
      index += 1;
    }
    return index < bytes.byteLength && bytes[index] === 0x7B;
  }

  private fileNameFromUri(uri: string): string {
    const normalized = uri.replace(/\\/g, '/');
    const slash = normalized.lastIndexOf('/');
    const rawName = slash >= 0 ? normalized.slice(slash + 1) : normalized;
    try {
      return decodeURIComponent(rawName);
    } catch (_err) {
      return rawName;
    }
  }

  private fileNameFromUrl(url: string): string {
    const query = url.indexOf('?');
    const fragment = url.indexOf('#');
    let end = url.length;
    if (query >= 0) {
      end = Math.min(end, query);
    }
    if (fragment >= 0) {
      end = Math.min(end, fragment);
    }
    return this.fileNameFromUri(url.slice(0, end));
  }

  private multipartFileName(fileName: string, fileType: string): string {
    let value = fileName.replace(/["\\\r\n]/g, '_').trim();
    if (value.length === 0 || (!value.toLowerCase().endsWith('.png') && !value.toLowerCase().endsWith('.json'))) {
      value = `character.${fileType}`;
    }
    return value;
  }

  private itemFromRecord(value: JsonRecord, shallow: boolean): CharacterBrowserItem {
    const item = new CharacterBrowserItem();
    item.avatar = asString(value['avatar']);
    item.id = item.avatar;
    item.name = asString(value['name']) || this.dataString(value, 'name') || this.fileStem(item.avatar);
    item.chat = asString(value['chat']);
    item.favorite = asBoolean(value['fav']);
    item.tags = this.stringArray(value['tags']);
    if (item.tags.length === 0) {
      item.tags = this.stringArray(this.dataValue(value, 'tags'));
    }
    item.dateAddedMs = asNumber(value['date_added']);
    item.dateLastChatMs = asNumber(value['date_last_chat']);
    item.chatSizeBytes = asNumber(value['chat_size']);
    item.dataSizeBytes = asNumber(value['data_size']);
    item.data = asRecord(value['data']);
    item.description = asString(value['description']) || this.dataString(value, 'description');
    item.personality = asString(value['personality']) || this.dataString(value, 'personality');
    item.scenario = asString(value['scenario']) || this.dataString(value, 'scenario');
    item.firstMessage = asString(value['first_mes']) || this.dataString(value, 'first_mes');
    item.exampleMessages = asString(value['mes_example']) || this.dataString(value, 'mes_example');
    item.creatorNotes = this.dataString(value, 'creator_notes');
    item.creator = this.dataString(value, 'creator');
    item.version = this.dataString(value, 'character_version');
    item.alternateGreetings = this.stringArray(this.dataValue(value, 'alternate_greetings'));
    const extensions = asRecord(this.dataValue(value, 'extensions'));
    item.talkativeness = asNumber(extensions['talkativeness'], 0.5);
    const depthPrompt = asRecord(extensions['depth_prompt']);
    item.depthPrompt = asString(depthPrompt['prompt']);
    item.depth = asNumber(depthPrompt['depth'], 4);
    item.depthRole = asString(depthPrompt['role']) || 'system';
    item.jsonData = asString(value['json_data']);
    if (shallow) {
      item.jsonData = '';
    }
    return item;
  }

  private dataValue(value: JsonRecord, key: string): JsonRecord | JsonArray | Object | string | number | boolean | null {
    const data = asRecord(value['data']);
    return data[key] ?? null;
  }

  private dataString(value: JsonRecord, key: string): string {
    return asString(this.dataValue(value, key));
  }

  private stringArray(value: JsonArray | Object | string | number | boolean | null | undefined): string[] {
    return asArray(value).filter((entry: Object | string | number | boolean | null): boolean => {
      return typeof entry === 'string' && entry.length > 0;
    }).map((entry: Object | string | number | boolean | null): string => `${entry}`);
  }

  private copyData(source: JsonRecord): JsonRecord {
    try {
      return JSON.parse(JSON.stringify(source)) as JsonRecord;
    } catch (_err) {
      return {};
    }
  }

  private parseRecord(text: string): JsonRecord {
    try {
      const value = JSON.parse(text) as Object;
      return value !== null && !Array.isArray(value) && typeof value === 'object' ? value as JsonRecord : {};
    } catch (_err) {
      return {};
    }
  }

  private parseArray(text: string): JsonRecord[] {
    try {
      const value = JSON.parse(text) as JsonArray;
      if (!Array.isArray(value)) {
        return [];
      }
      return value.filter((entry: Object | string | number | boolean | null): boolean => {
        return entry !== null && !Array.isArray(entry) && typeof entry === 'object';
      }).map((entry: Object | string | number | boolean | null): JsonRecord => entry as JsonRecord);
    } catch (_err) {
      return [];
    }
  }

  private isSuccess(result: RemoteHttpResult): boolean {
    return result.statusCode >= 200 && result.statusCode < 300;
  }

  private fileStem(value: string): string {
    const dot = value.lastIndexOf('.');
    return dot > 0 ? value.slice(0, dot) : value;
  }

  private async rebuildCacheAsync(): Promise<CharacterBrowserItem[]> {
    try {
      if (this.listProvider === null) {
        throw new Error('character list provider is unavailable');
      }
      const records = await this.listProvider();
      const items: CharacterBrowserItem[] = [];
      for (let index = 0; index < records.length; index++) {
        if (index > 0 && index % 20 === 0) {
          await this.yieldToEventLoop();
        }
        items.push(this.itemFromRecord(records[index] as JsonRecord, true));
      }
      this.cachedItems = items;
      this.cacheLoaded = true;
      this.cacheRefreshedAt = Date.now();
      this.notifyRefreshListeners(items);
      await this.writeCacheAsync();
      return items;
    } finally {
      this.refreshPromise = null;
      if (this.refreshPending) {
        this.refreshPending = false;
        this.scheduleRefresh();
      }
    }
  }

  private async loadCacheAsync(): Promise<CharacterBrowserItem[]> {
    this.cacheLoaded = true;
    if (this.store === null || this.cachePath.length === 0) {
      return [];
    }
    const text = await this.store.readTextAsync(this.cachePath, '');
    await this.yieldToEventLoop();
    const cache = this.parseRecord(text);
    this.cacheRefreshedAt = asNumber(cache['refreshedAt']);
    const values = asArray(cache['items']);
    const items: CharacterBrowserItem[] = [];
    for (let index = 0; index < values.length; index++) {
      if (index > 0 && index % 20 === 0) {
        await this.yieldToEventLoop();
      }
      const value = values[index];
      if (value !== null && !Array.isArray(value) && typeof value === 'object') {
        items.push(this.itemFromCacheRecord(value as JsonRecord));
      }
    }
    this.cachedItems = items;
    return items;
  }

  private itemFromCacheRecord(value: JsonRecord): CharacterBrowserItem {
    const item = new CharacterBrowserItem();
    item.id = asString(value['id']);
    item.avatar = asString(value['avatar']);
    item.name = asString(value['name']);
    item.chat = asString(value['chat']);
    item.favorite = asBoolean(value['favorite']);
    item.tags = this.stringArray(value['tags']);
    item.dateAddedMs = asNumber(value['dateAddedMs']);
    item.dateLastChatMs = asNumber(value['dateLastChatMs']);
    item.chatSizeBytes = asNumber(value['chatSizeBytes']);
    item.dataSizeBytes = asNumber(value['dataSizeBytes']);
    item.description = asString(value['description']);
    item.personality = asString(value['personality']);
    item.scenario = asString(value['scenario']);
    item.firstMessage = asString(value['firstMessage']);
    item.exampleMessages = asString(value['exampleMessages']);
    item.creatorNotes = asString(value['creatorNotes']);
    item.creator = asString(value['creator']);
    item.version = asString(value['version']);
    item.talkativeness = asNumber(value['talkativeness'], 0.5);
    item.depthPrompt = asString(value['depthPrompt']);
    item.depth = asNumber(value['depth'], 4);
    item.depthRole = asString(value['depthRole']) || 'system';
    item.alternateGreetings = this.stringArray(value['alternateGreetings']);
    item.jsonData = asString(value['jsonData']);
    item.data = asRecord(value['data']);
    return item;
  }

  private async writeCacheAsync(): Promise<void> {
    if (this.store === null || this.cachePath.length === 0) {
      return;
    }
    const cache = emptyJsonRecord();
    cache['version'] = 1;
    cache['refreshedAt'] = this.cacheRefreshedAt;
    const parts: string[] = [];
    for (let index = 0; index < this.cachedItems.length; index++) {
      if (index > 0 && index % 10 === 0) {
        await this.yieldToEventLoop();
      }
      parts.push(JSON.stringify(this.cachedItems[index]));
    }
    const prefix = `${JSON.stringify(cache).slice(0, -1)},"items":[`;
    await this.store.writeTextAsync(this.cachePath, `${prefix}${parts.join(',')}]}`);
  }

  private notifyRefreshListeners(items: CharacterBrowserItem[]): void {
    for (const listener of this.refreshListeners) {
      listener(items);
    }
  }

  private async yieldToEventLoop(): Promise<void> {
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), 0);
    });
  }
}
