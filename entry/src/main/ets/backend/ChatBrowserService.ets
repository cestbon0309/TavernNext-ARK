import { hilog } from '@kit.PerformanceAnalysisKit';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { asArray, asBoolean, asNumber, asRecord, asString, bodyAsRecord } from './JsonUtils';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { ensureJsonlExtension, joinPath, sanitizeFileName, withoutExtension } from './PathUtils';
import { PngCardStore } from './PngCardStore';

type ChatBrowserOpenListener = () => void;

const CHAT_BROWSER_SETTINGS_FILE = 'chat-browser-settings.json';
const CHAT_BROWSER_CACHE_FILE = 'chat-browser-cache.json';
const DOMAIN = 0x544156;
const TAG = 'TavernChatBrowser';

class OkResponse {
  ok: boolean = true;
}

export class ChatBrowserItem {
  id: string = '';
  kind: string = '';
  fileName: string = '';
  chatName: string = '';
  avatar: string = '';
  group: string = '';
  title: string = '';
  subtitle: string = '';
  preview: string = '';
  lastTimestamp: string = '';
  mtimeMs: number = 0;
  sizeBytes: number = 0;
  fileSize: string = '';
  chatItems: number = 0;
  openable: boolean = false;
}

class ChatBrowserListResponse {
  items: ChatBrowserItem[] = [];
  cached: boolean = true;
  refreshedAt: number = 0;
}

export class ChatBrowserService {
  private store: FileStore;
  private dirs: DataDirectories;
  private userDirs: UserDirectories;
  private cardStore: PngCardStore;
  private settingsPath: string;
  private cachePath: string;
  private cachedItems: ChatBrowserItem[] = [];
  private cacheLoaded: boolean = false;
  private cacheRefreshedAt: number = 0;
  private listeners: ChatBrowserOpenListener[] = [];
  private refreshTimingEntries: JsonRecord[] = [];
  private lastListTiming: JsonRecord = emptyJsonRecord();

  constructor(store: FileStore, dirs: DataDirectories) {
    this.store = store;
    this.dirs = dirs;
    this.userDirs = dirs.defaultUser;
    this.cardStore = new PngCardStore(store);
    this.settingsPath = joinPath(dirs.storageRoot, CHAT_BROWSER_SETTINGS_FILE);
    this.cachePath = joinPath(dirs.storageRoot, CHAT_BROWSER_CACHE_FILE);
  }

  subscribeOpen(listener: ChatBrowserOpenListener): void {
    this.listeners.push(listener);
  }

  openBrowser(): HttpResponse {
    for (const listener of this.listeners) {
      listener();
    }
    return HttpResponse.json(new OkResponse());
  }

  isDarkMode(): boolean {
    const settings = this.store.readJsonRecord(this.settingsPath);
    return settings['darkMode'] !== false;
  }

  setDarkMode(darkMode: boolean): void {
    const settings = emptyJsonRecord();
    settings['darkMode'] = darkMode;
    this.store.writeJson(this.settingsPath, settings);
  }

  listResponse(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const forceRefresh = asBoolean(body['refresh']) || asBoolean(body['forceRefresh']) || asBoolean(body['force']);
    const response = new ChatBrowserListResponse();
    response.items = forceRefresh ? this.refreshCache() : this.cachedList();
    response.cached = !forceRefresh;
    response.refreshedAt = this.cacheRefreshedAt;
    return HttpResponse.json(response);
  }

  refreshResponse(): HttpResponse {
    const response = new ChatBrowserListResponse();
    response.items = this.refreshCache();
    response.cached = false;
    response.refreshedAt = this.cacheRefreshedAt;
    return HttpResponse.json(response);
  }

  deleteResponse(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    if (!this.deleteByPayload(body)) {
      const response = emptyJsonRecord();
      response['ok'] = false;
      response['error'] = 'not_found';
      return HttpResponse.json(response, 400);
    }
    this.refreshCache();
    return HttpResponse.json(new OkResponse());
  }

  cachedList(): ChatBrowserItem[] {
    this.ensureCacheLoaded();
    return this.cachedItems;
  }

  refreshTimingsJson(): JsonArray {
    const result: JsonArray = [];
    for (const entry of this.refreshTimingEntries) {
      result.push(entry);
    }
    return result;
  }

  refreshCache(): ChatBrowserItem[] {
    const refreshStartedAt = Date.now();
    const listStartedAt = Date.now();
    const items = this.listAll();
    const listDurationMs = Date.now() - listStartedAt;
    this.cachedItems = items;
    this.cacheLoaded = true;
    this.cacheRefreshedAt = Date.now();
    const writeStartedAt = Date.now();
    this.writeCache();
    const writeDurationMs = Date.now() - writeStartedAt;
    this.recordRefreshTiming(items.length, listDurationMs, writeDurationMs, Date.now() - refreshStartedAt);
    return items;
  }

  listAll(): ChatBrowserItem[] {
    const totalStartedAt = Date.now();
    const items: ChatBrowserItem[] = [];
    const characterChatDirs: Record<string, boolean> = {};

    const characterStartedAt = Date.now();
    this.collectCharacterChats(items, characterChatDirs);
    const characterDurationMs = Date.now() - characterStartedAt;
    const characterItems = items.length;

    const orphanCharacterStartedAt = Date.now();
    this.collectOrphanCharacterChats(items, characterChatDirs);
    const orphanCharacterDurationMs = Date.now() - orphanCharacterStartedAt;
    const orphanCharacterItems = items.length - characterItems;

    const groupStartedAt = Date.now();
    this.collectGroupChats(items);
    const groupDurationMs = Date.now() - groupStartedAt;
    const groupItems = items.length - characterItems - orphanCharacterItems;

    const rootStartedAt = Date.now();
    this.collectRootChats(items);
    const rootDurationMs = Date.now() - rootStartedAt;
    const rootItems = items.length - characterItems - orphanCharacterItems - groupItems;

    const sortStartedAt = Date.now();
    items.sort((left: ChatBrowserItem, right: ChatBrowserItem): number => {
      if (left.mtimeMs !== right.mtimeMs) {
        return right.mtimeMs - left.mtimeMs;
      }
      return `${left.title} ${left.chatName}`.localeCompare(`${right.title} ${right.chatName}`);
    });
    const sortDurationMs = Date.now() - sortStartedAt;
    this.recordListTiming(items.length, characterItems, orphanCharacterItems, groupItems, rootItems, characterDurationMs,
      orphanCharacterDurationMs, groupDurationMs, rootDurationMs, sortDurationMs, Date.now() - totalStartedAt);
    return items;
  }

  deleteItem(item: ChatBrowserItem): boolean {
    const deleted = this.deleteByFields(item.kind, item.avatar, item.group, item.fileName);
    if (deleted) {
      this.removeCachedItem(item);
    }
    return deleted;
  }

  removeCachedItem(item: ChatBrowserItem): ChatBrowserItem[] {
    this.ensureCacheLoaded();
    this.cachedItems = this.cachedItems.filter((candidate: ChatBrowserItem): boolean => {
      return !this.isSameCachedItem(candidate, item);
    });
    this.cacheRefreshedAt = Date.now();
    this.writeCache();
    return this.cachedItems;
  }

  private ensureCacheLoaded(): void {
    if (this.cacheLoaded) {
      return;
    }
    const cache = this.store.readJsonRecord(this.cachePath);
    this.cacheRefreshedAt = asNumber(cache['refreshedAt']);
    const parsedItems = this.itemsFromJson(asArray(cache['items']));
    if (parsedItems.length > 0 || this.cacheRefreshedAt > 0) {
      this.cachedItems = parsedItems;
      this.cacheLoaded = true;
      return;
    }
    this.refreshCache();
  }

  private writeCache(): void {
    const cache = emptyJsonRecord();
    cache['version'] = 1;
    cache['refreshedAt'] = this.cacheRefreshedAt;
    cache['items'] = this.cachedItems;
    this.store.writeJson(this.cachePath, cache);
  }

  private recordListTiming(itemCount: number, characterItems: number, orphanCharacterItems: number, groupItems: number,
    rootItems: number, characterDurationMs: number, orphanCharacterDurationMs: number, groupDurationMs: number,
    rootDurationMs: number, sortDurationMs: number, totalDurationMs: number): void {
    const timing = emptyJsonRecord();
    timing['itemCount'] = itemCount;
    timing['characterItems'] = characterItems;
    timing['orphanCharacterItems'] = orphanCharacterItems;
    timing['groupItems'] = groupItems;
    timing['rootItems'] = rootItems;
    timing['characterDurationMs'] = characterDurationMs;
    timing['orphanCharacterDurationMs'] = orphanCharacterDurationMs;
    timing['groupDurationMs'] = groupDurationMs;
    timing['rootDurationMs'] = rootDurationMs;
    timing['sortDurationMs'] = sortDurationMs;
    timing['totalDurationMs'] = totalDurationMs;
    this.lastListTiming = timing;
  }

  private recordRefreshTiming(itemCount: number, listDurationMs: number, writeDurationMs: number,
    totalDurationMs: number): void {
    const list = this.lastListTiming;
    const entry = emptyJsonRecord();
    entry['finishedAtMs'] = Date.now();
    entry['itemCount'] = itemCount;
    entry['listDurationMs'] = listDurationMs;
    entry['writeCacheDurationMs'] = writeDurationMs;
    entry['totalDurationMs'] = totalDurationMs;
    entry['list'] = list;
    this.refreshTimingEntries.push(entry);
    while (this.refreshTimingEntries.length > 80) {
      this.refreshTimingEntries.shift();
    }

    hilog.info(DOMAIN, TAG, 'refreshCache items=%{public}d total=%{public}d ms list=%{public}d ms write=%{public}d ms',
      itemCount, totalDurationMs, listDurationMs, writeDurationMs);
    hilog.info(DOMAIN, TAG,
      'listAll items=%{public}d total=%{public}d ms character=%{public}d ms orphanCharacter=%{public}d ms group=%{public}d ms root=%{public}d ms sort=%{public}d ms',
      itemCount, asNumber(list['totalDurationMs']), asNumber(list['characterDurationMs']),
      asNumber(list['orphanCharacterDurationMs']), asNumber(list['groupDurationMs']), asNumber(list['rootDurationMs']),
      asNumber(list['sortDurationMs']));
  }

  private itemsFromJson(values: JsonArray): ChatBrowserItem[] {
    const items: ChatBrowserItem[] = [];
    for (const value of values) {
      if (value === null || Array.isArray(value) || typeof value !== 'object') {
        continue;
      }
      items.push(this.itemFromJson(value as JsonRecord));
    }
    return items;
  }

  private itemFromJson(value: JsonRecord): ChatBrowserItem {
    const item = new ChatBrowserItem();
    item.id = asString(value['id']);
    item.kind = asString(value['kind']);
    item.fileName = asString(value['fileName']);
    item.chatName = asString(value['chatName']);
    item.avatar = asString(value['avatar']);
    item.group = asString(value['group']);
    item.title = asString(value['title']);
    item.subtitle = asString(value['subtitle']);
    item.preview = asString(value['preview']);
    item.lastTimestamp = asString(value['lastTimestamp']);
    item.mtimeMs = asNumber(value['mtimeMs']);
    item.sizeBytes = asNumber(value['sizeBytes']);
    item.fileSize = asString(value['fileSize']);
    item.chatItems = asNumber(value['chatItems']);
    item.openable = asBoolean(value['openable']);
    return item;
  }

  private isSameCachedItem(left: ChatBrowserItem, right: ChatBrowserItem): boolean {
    if (left.id.length > 0 && right.id.length > 0) {
      return left.id === right.id;
    }
    return left.kind === right.kind &&
      left.avatar === right.avatar &&
      left.group === right.group &&
      left.fileName === right.fileName &&
      left.chatName === right.chatName;
  }

  private deleteByPayload(body: JsonRecord): boolean {
    return this.deleteByFields(asString(body['kind']), asString(body['avatar']), asString(body['group']),
      asString(body['fileName']) || asString(body['file_name']) || asString(body['chatName']));
  }

  private deleteByFields(kind: string, avatar: string, group: string, fileName: string): boolean {
    const safeFile = ensureJsonlExtension(sanitizeFileName(fileName));
    if (safeFile.length === 0 || safeFile === 'unnamed.jsonl') {
      return false;
    }

    if (kind === 'character') {
      const safeAvatar = sanitizeFileName(avatar);
      if (safeAvatar.length === 0 || safeAvatar === 'unnamed') {
        return false;
      }
      return this.store.deleteFile(joinPath(this.userDirs.chats, withoutExtension(safeAvatar), safeFile));
    }

    if (kind === 'group' || kind === 'orphan_group') {
      const deleted = this.store.deleteFile(joinPath(this.userDirs.groupChats, safeFile));
      if (deleted && group.length > 0) {
        this.removeGroupChatReference(group, withoutExtension(safeFile));
      }
      return deleted;
    }

    if (kind === 'orphan_character') {
      return this.deleteOrphanCharacterChat(safeFile);
    }

    if (kind === 'root') {
      return this.store.deleteFile(joinPath(this.userDirs.chats, safeFile));
    }

    return false;
  }

  private deleteOrphanCharacterChat(fileName: string): boolean {
    const chatDirs = this.store.list(this.userDirs.chats);
    for (const chatDir of chatDirs) {
      if (!chatDir.isDirectory) {
        continue;
      }
      const path = joinPath(chatDir.path, fileName);
      if (this.store.exists(path)) {
        return this.store.deleteFile(path);
      }
    }
    return false;
  }

  private collectCharacterChats(items: ChatBrowserItem[], characterChatDirs: Record<string, boolean>): void {
    const characterFiles = this.store.listFilesByExtension(this.userDirs.characters, '.png');
    for (const character of characterFiles) {
      const avatar = character.name;
      const dirName = withoutExtension(avatar);
      characterChatDirs[dirName] = true;
      const chatDir = joinPath(this.userDirs.chats, dirName);
      if (!this.store.exists(chatDir)) {
        continue;
      }
      const displayName = this.characterName(character);
      const chatFiles = this.store.listFilesByExtension(chatDir, '.jsonl');
      for (const chatFile of chatFiles) {
        items.push(this.itemFromFile(chatFile, 'character', avatar, '', displayName, '角色聊天', true));
      }
    }
  }

  private collectOrphanCharacterChats(items: ChatBrowserItem[], characterChatDirs: Record<string, boolean>): void {
    const chatDirs = this.store.list(this.userDirs.chats);
    for (const chatDir of chatDirs) {
      if (!chatDir.isDirectory || characterChatDirs[chatDir.name] === true) {
        continue;
      }
      const chatFiles = this.store.listFilesByExtension(chatDir.path, '.jsonl');
      for (const chatFile of chatFiles) {
        items.push(this.itemFromFile(chatFile, 'orphan_character', '', '', chatDir.name, '聊天目录未关联到角色', false));
      }
    }
  }

  private collectGroupChats(items: ChatBrowserItem[]): void {
    const seen: Record<string, boolean> = {};
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      const groupId = asString(group['id']) || withoutExtension(groupFile.name);
      const groupName = asString(group['name']) || groupId;
      const chats = asArray(group['chats']);
      for (const chat of chats) {
        const fileName = ensureJsonlExtension(sanitizeFileName(`${chat}`));
        const file = this.store.stat(joinPath(this.userDirs.groupChats, fileName), fileName);
        if (file === null || !file.isFile) {
          continue;
        }
        seen[fileName] = true;
        items.push(this.itemFromFile(file, 'group', '', groupId, groupName, '群聊', true));
      }
    }

    const allGroupChats = this.store.listFilesByExtension(this.userDirs.groupChats, '.jsonl');
    for (const chatFile of allGroupChats) {
      if (seen[chatFile.name] === true) {
        continue;
      }
      items.push(this.itemFromFile(chatFile, 'orphan_group', '', '', '未关联群聊', '群聊文件未关联到群组', false));
    }
  }

  private collectRootChats(items: ChatBrowserItem[]): void {
    const chatFiles = this.store.listFilesByExtension(this.userDirs.chats, '.jsonl');
    for (const chatFile of chatFiles) {
      items.push(this.itemFromFile(chatFile, 'root', '', '', '未关联聊天', '聊天文件未关联到角色', false));
    }
  }

  private itemFromFile(file: FileEntry, kind: string, avatar: string, group: string, title: string, subtitle: string,
    openable: boolean): ChatBrowserItem {
    const rows = this.readChatRows(file.path);
    const item = new ChatBrowserItem();
    item.kind = kind;
    item.fileName = file.name;
    item.chatName = withoutExtension(file.name);
    item.avatar = avatar;
    item.group = group;
    item.title = title;
    item.subtitle = subtitle;
    item.mtimeMs = file.mtimeMs;
    item.sizeBytes = file.size;
    item.fileSize = this.formatBytes(file.size);
    item.chatItems = Math.max(0, rows.length - 1);
    item.lastTimestamp = new Date(Math.round(file.mtimeMs)).toISOString();
    item.preview = '[The chat is empty]';
    item.openable = openable;
    item.id = `${kind}:${avatar}:${group}:${file.name}`;

    if (rows.length > 0) {
      const last = rows[rows.length - 1];
      item.preview = asString(last['mes']) || '[The message is empty]';
      item.lastTimestamp = asString(last['send_date']) || item.lastTimestamp;
    }

    return item;
  }

  private characterName(character: FileEntry): string {
    const card = this.cardStore.readCard(character.path);
    if (card !== null) {
      const data = asRecord(card['data']);
      const name = asString(card['name']) || asString(data['name']);
      if (name.length > 0) {
        return name;
      }
    }
    return withoutExtension(character.name);
  }

  private readChatRows(path: string): JsonRecord[] {
    const rows: JsonRecord[] = [];
    const text = this.store.readText(path, '');
    if (text.length === 0) {
      return rows;
    }
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      try {
        const parsed = JSON.parse(trimmed) as Object;
        if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          rows.push(parsed as JsonRecord);
        }
      } catch (_err) {
      }
    }
    return rows;
  }

  private removeGroupChatReference(groupId: string, chatId: string): void {
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      const storedId = asString(group['id']) || withoutExtension(groupFile.name);
      if (storedId !== groupId) {
        continue;
      }
      const nextChats = asArray(group['chats'])
        .filter((item): boolean => withoutExtension(sanitizeFileName(`${item}`)) !== chatId);
      group['chats'] = nextChats;
      this.store.writeJson(groupFile.path, group);
      return;
    }
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
}
