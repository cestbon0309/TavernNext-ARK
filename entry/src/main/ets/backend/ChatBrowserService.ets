import { hilog } from '@kit.PerformanceAnalysisKit';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { asArray, asBoolean, asNumber, asRecord, asString, bodyAsRecord } from './JsonUtils';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { ensureJsonlExtension, ensurePngExtension, joinPath, sanitizeFileName, withoutExtension } from './PathUtils';
import { PngCardStore } from './PngCardStore';

type ChatBrowserOpenListener = () => void;
export type ChatBrowserRefreshListener = (items: ChatBrowserItem[]) => void;

const CHAT_BROWSER_SETTINGS_FILE = 'chat-browser-settings.json';
const CHAT_BROWSER_CACHE_FILE = 'chat-browser-cache.json';
const CHAT_BROWSER_NAMES_FILE = 'character-names.json';
const CHAT_BROWSER_REBUILD_BATCH_SIZE = 20;
const DOMAIN = 0x5441;
const TAG = 'TavernChatBrowser';

class OkResponse {
  ok: boolean = true;
}

class ChatTextAnalysis {
  count: number = 0;
  preview: string = '';
}

class GroupBelonging {
  groupId: string = '';
  groupName: string = '';
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
  private characterNamesPath: string;
  private cachedItems: ChatBrowserItem[] = [];
  private cacheLoaded: boolean = false;
  private cacheRefreshedAt: number = 0;
  private characterNames: Map<string, string> = new Map<string, string>();
  private characterNamesLoaded: boolean = false;
  private listeners: ChatBrowserOpenListener[] = [];
  private refreshListeners: ChatBrowserRefreshListener[] = [];
  private rebuildInFlight: boolean = false;
  private refreshTimingEntries: JsonRecord[] = [];
  private lastListTiming: JsonRecord = emptyJsonRecord();

  constructor(store: FileStore, dirs: DataDirectories) {
    this.store = store;
    this.dirs = dirs;
    this.userDirs = dirs.defaultUser;
    this.cardStore = new PngCardStore(store);
    this.settingsPath = joinPath(dirs.storageRoot, CHAT_BROWSER_SETTINGS_FILE);
    this.cachePath = joinPath(dirs.storageRoot, CHAT_BROWSER_CACHE_FILE);
    this.characterNamesPath = joinPath(dirs.storageRoot, CHAT_BROWSER_NAMES_FILE);
  }

  subscribeOpen(listener: ChatBrowserOpenListener): void {
    this.listeners.push(listener);
  }

  subscribeRefresh(listener: ChatBrowserRefreshListener): void {
    this.refreshListeners.push(listener);
  }

  unsubscribeRefresh(listener: ChatBrowserRefreshListener): void {
    const index = this.refreshListeners.indexOf(listener);
    if (index >= 0) {
      this.refreshListeners.splice(index, 1);
    }
  }

  openBrowser(): HttpResponse {
    for (const listener of this.listeners) {
      listener();
    }
    return HttpResponse.json(new OkResponse());
  }

  isDarkMode(): boolean {
    const settings = this.store.readJsonRecord(this.settingsPath);
    return settings['darkMode'] === true;
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

  async refreshCacheAsync(): Promise<ChatBrowserItem[]> {
    if (this.rebuildInFlight) {
      return this.cachedList();
    }
    this.rebuildInFlight = true;
    const refreshStartedAt = Date.now();
    const listStartedAt = Date.now();
    try {
      const items = await this.listAllAsync();
      const listDurationMs = Date.now() - listStartedAt;
      this.cachedItems = items;
      this.cacheLoaded = true;
      this.cacheRefreshedAt = Date.now();
      const writeStartedAt = Date.now();
      this.writeCache();
      const writeDurationMs = Date.now() - writeStartedAt;
      this.recordRefreshTiming(items.length, listDurationMs, writeDurationMs, Date.now() - refreshStartedAt);
      this.notifyRefreshListeners(items);
      return items;
    } catch (_err) {
      hilog.error(DOMAIN, TAG, 'refreshCacheAsync failed');
      throw new Error('refreshCacheAsync failed');
    } finally {
      this.rebuildInFlight = false;
    }
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

  async listAllAsync(): Promise<ChatBrowserItem[]> {
    const totalStartedAt = Date.now();
    const items: ChatBrowserItem[] = [];
    const characterChatDirs: Record<string, boolean> = {};

    const characterStartedAt = Date.now();
    await this.collectCharacterChatsAsync(items, characterChatDirs);
    const characterDurationMs = Date.now() - characterStartedAt;
    const characterItems = items.length;

    const orphanCharacterStartedAt = Date.now();
    await this.collectOrphanCharacterChatsAsync(items, characterChatDirs);
    const orphanCharacterDurationMs = Date.now() - orphanCharacterStartedAt;
    const orphanCharacterItems = items.length - characterItems;

    const groupStartedAt = Date.now();
    await this.collectGroupChatsAsync(items);
    const groupDurationMs = Date.now() - groupStartedAt;
    const groupItems = items.length - characterItems - orphanCharacterItems;

    const rootStartedAt = Date.now();
    await this.collectRootChatsAsync(items);
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

  upsertCharacterChat(avatar: string, fileName: string, chatCount: number, previewMes: string): void {
    if (avatar.length === 0 || fileName.length === 0) {
      return;
    }
    this.ensureCacheLoaded();
    const safeAvatar = ensurePngExtension(sanitizeFileName(avatar));
    const safeFile = ensureJsonlExtension(sanitizeFileName(fileName));
    const file = this.store.stat(joinPath(this.userDirs.chats, withoutExtension(safeAvatar), safeFile), safeFile);
    const mtimeMs = file !== null ? file.mtimeMs : Date.now();
    const sizeBytes = file !== null ? file.size : 0;
    const name = this.characterName(safeAvatar);
    const item = new ChatBrowserItem();
    item.kind = 'character';
    item.fileName = safeFile;
    item.chatName = withoutExtension(safeFile);
    item.avatar = safeAvatar;
    item.group = '';
    item.title = name;
    item.subtitle = '角色聊天';
    item.preview = previewMes;
    item.mtimeMs = mtimeMs;
    item.sizeBytes = sizeBytes;
    item.fileSize = this.formatBytes(sizeBytes);
    item.chatItems = Math.max(0, chatCount - 1);
    item.lastTimestamp = new Date(Math.round(mtimeMs)).toISOString();
    item.openable = true;
    item.id = `character:${safeAvatar}::${safeFile}`;
    this.upsertCachedItem(item);
  }

  upsertGroupChat(chatId: string, chatCount: number, previewMes: string): void {
    if (chatId.length === 0) {
      return;
    }
    this.ensureCacheLoaded();
    const safeFile = ensureJsonlExtension(sanitizeFileName(chatId));
    const file = this.store.stat(joinPath(this.userDirs.groupChats, safeFile), safeFile);
    const mtimeMs = file !== null ? file.mtimeMs : Date.now();
    const sizeBytes = file !== null ? file.size : 0;
    const belonging = this.groupBelonging(withoutExtension(safeFile));
    const item = new ChatBrowserItem();
    item.kind = belonging !== null ? 'group' : 'orphan_group';
    item.fileName = safeFile;
    item.chatName = withoutExtension(safeFile);
    item.avatar = '';
    item.group = belonging !== null ? belonging.groupId : '';
    item.title = belonging !== null ? belonging.groupName : '未关联群聊';
    item.subtitle = belonging !== null ? '群聊' : '群聊文件未关联到群组';
    item.preview = previewMes;
    item.mtimeMs = mtimeMs;
    item.sizeBytes = sizeBytes;
    item.fileSize = this.formatBytes(sizeBytes);
    item.chatItems = Math.max(0, chatCount - 1);
    item.lastTimestamp = new Date(Math.round(mtimeMs)).toISOString();
    item.openable = belonging !== null;
    item.id = `${item.kind}:${item.group}:${safeFile}`;
    this.upsertCachedItem(item);
  }

  rescanChatItem(kind: string, avatar: string, group: string, fileName: string): void {
    this.ensureCacheLoaded();
    const safeFile = ensureJsonlExtension(sanitizeFileName(fileName));
    if (safeFile.length === 0 || safeFile === 'unnamed.jsonl') {
      return;
    }
    if (kind === 'character') {
      const safeAvatar = ensurePngExtension(sanitizeFileName(avatar));
      if (safeAvatar.length === 0 || safeAvatar === 'unnamed.png') {
        return;
      }
      const file = this.store.stat(joinPath(this.userDirs.chats, withoutExtension(safeAvatar), safeFile), safeFile);
      if (file === null || !file.isFile) {
        return;
      }
      this.upsertCachedItem(this.itemFromFile(file, 'character', safeAvatar, '', this.characterName(safeAvatar),
        '角色聊天', true));
      return;
    }
    if (kind === 'group') {
      const file = this.store.stat(joinPath(this.userDirs.groupChats, safeFile), safeFile);
      if (file === null || !file.isFile) {
        return;
      }
      this.upsertCachedItem(this.itemFromFile(file, 'group', '', group, this.groupName(group), '群聊', true));
      return;
    }
    if (kind === 'orphan_group') {
      const file = this.store.stat(joinPath(this.userDirs.groupChats, safeFile), safeFile);
      if (file === null || !file.isFile) {
        return;
      }
      this.upsertCachedItem(this.itemFromFile(file, 'orphan_group', '', '', '未关联群聊', '群聊文件未关联到群组', false));
      return;
    }
    const file = this.store.stat(joinPath(this.userDirs.chats, safeFile), safeFile);
    if (file === null || !file.isFile) {
      return;
    }
    this.upsertCachedItem(this.itemFromFile(file, 'root', '', '', '未关联聊天', '聊天文件未关联到角色', false));
  }

  renameChatItem(kind: string, avatar: string, group: string, originalFile: string, renamedFile: string): void {
    this.ensureCacheLoaded();
    const safeOriginal = ensureJsonlExtension(sanitizeFileName(originalFile));
    const safeRenamed = ensureJsonlExtension(sanitizeFileName(renamedFile));
    if (safeOriginal.length === 0 || safeRenamed.length === 0) {
      return;
    }
    let changed = false;
    this.cachedItems = this.cachedItems.map((candidate: ChatBrowserItem): ChatBrowserItem => {
      if (candidate.kind !== kind && !(kind === 'group' && candidate.kind === 'orphan_group') &&
        !(kind === 'orphan_group' && candidate.kind === 'group')) {
        return candidate;
      }
      if (candidate.fileName !== safeOriginal) {
        return candidate;
      }
      if (kind === 'character' && candidate.avatar !== avatar) {
        return candidate;
      }
      if ((kind === 'group' || kind === 'orphan_group') && group.length > 0 && candidate.group !== group) {
        return candidate;
      }
      const updated = this.copyItem(candidate);
      updated.fileName = safeRenamed;
      updated.chatName = withoutExtension(safeRenamed);
      updated.id = `${updated.kind}:${updated.avatar}:${updated.group}:${safeRenamed}`;
      changed = true;
      return updated;
    });
    if (changed) {
      this.cacheRefreshedAt = Date.now();
      this.writeCache();
    }
  }

  syncGroupChats(groupId: string, groupName: string, chatIds: JsonArray): void {
    if (groupId.length === 0) {
      return;
    }
    this.ensureCacheLoaded();
    const wanted: Record<string, boolean> = {};
    for (const raw of chatIds) {
      const base = withoutExtension(sanitizeFileName(`${raw}`));
      if (base.length > 0) {
        wanted[`${base}.jsonl`] = true;
      }
    }    let changed = false;
    this.cachedItems = this.cachedItems.map((candidate: ChatBrowserItem): ChatBrowserItem => {
      if (candidate.kind === 'group' && candidate.group === groupId) {
        if (wanted[candidate.fileName] !== true) {
          const updated = this.copyItem(candidate);
          updated.kind = 'orphan_group';
          updated.group = '';
          updated.title = '未关联群聊';
          updated.subtitle = '群聊文件未关联到群组';
          updated.openable = false;
          updated.id = `orphan_group:::${updated.fileName}`;
          changed = true;
          return updated;
        }
        if (candidate.title !== groupName) {
          const updated = this.copyItem(candidate);
          updated.title = groupName;
          changed = true;
          return updated;
        }
        return candidate;
      }
      if (candidate.kind === 'orphan_group' && wanted[candidate.fileName] === true) {
        const updated = this.copyItem(candidate);
        updated.kind = 'group';
        updated.group = groupId;
        updated.title = groupName;
        updated.subtitle = '群聊';
        updated.openable = true;
        updated.id = `group::${groupId}:${updated.fileName}`;
        changed = true;
        return updated;
      }
      return candidate;
    });
    for (const fileName of Object.keys(wanted)) {
      const exists = this.cachedItems.some((candidate: ChatBrowserItem): boolean => {
        return candidate.kind === 'group' && candidate.group === groupId && candidate.fileName === fileName;
      });
      if (!exists) {
        this.rescanChatItem('group', '', groupId, fileName);
      }
    }
    if (changed) {
      this.cacheRefreshedAt = Date.now();
      this.writeCache();
    }
  }

  removeGroupChats(groupId: string): void {
    this.ensureCacheLoaded();
    this.cachedItems = this.cachedItems.filter((candidate: ChatBrowserItem): boolean => {
      return !(candidate.kind === 'group' && candidate.group === groupId);
    });
    this.cacheRefreshedAt = Date.now();
    this.writeCache();
  }

  removeCharacterChats(avatar: string): ChatBrowserItem[] {
    this.ensureCacheLoaded();
    this.cachedItems = this.cachedItems.filter((candidate: ChatBrowserItem): boolean => {
      return !(candidate.kind === 'character' && candidate.avatar === avatar);
    });
    this.cacheRefreshedAt = Date.now();
    this.writeCache();
    return this.cachedItems;
  }

  renameCharacterChats(oldAvatar: string, newAvatar: string, newName: string): void {
    this.ensureCacheLoaded();
    this.setCharacterName(newAvatar, newName);
    this.characterNames.delete(oldAvatar);
    let changed = false;
    this.cachedItems = this.cachedItems.map((candidate: ChatBrowserItem): ChatBrowserItem => {
      if (candidate.kind === 'character' && candidate.avatar === oldAvatar) {
        const updated = this.copyItem(candidate);
        updated.avatar = newAvatar;
        updated.title = newName;
        updated.id = `${updated.kind}:${newAvatar}:${updated.group}:${updated.fileName}`;
        changed = true;
        return updated;
      }
      return candidate;
    });
    if (changed) {
      this.cacheRefreshedAt = Date.now();
      this.writeCache();
      this.writeCharacterNames();
    }
  }

  setCharacterName(avatar: string, name: string): void {
    if (avatar.length === 0 || name.length === 0) {
      return;
    }
    this.ensureCharacterNamesLoaded();
    if (this.characterNames.get(avatar) === name) {
      return;
    }
    this.characterNames.set(avatar, name);
    this.writeCharacterNames();
    this.ensureCacheLoaded();
    let changed = false;
    this.cachedItems = this.cachedItems.map((candidate: ChatBrowserItem): ChatBrowserItem => {
      if (candidate.kind === 'character' && candidate.avatar === avatar && candidate.title !== name) {
        const updated = this.copyItem(candidate);
        updated.title = name;
        changed = true;
        return updated;
      }
      return candidate;
    });
    if (changed) {
      this.cacheRefreshedAt = Date.now();
      this.writeCache();
    }
  }

  removeCharacterName(avatar: string): void {
    this.ensureCharacterNamesLoaded();
    if (!this.characterNames.has(avatar)) {
      return;
    }
    this.characterNames.delete(avatar);
    this.writeCharacterNames();
  }

  rescanCharacterChats(avatar: string): void {
    const safeAvatar = ensurePngExtension(sanitizeFileName(avatar));
    if (safeAvatar.length === 0) {
      return;
    }
    const dir = joinPath(this.userDirs.chats, withoutExtension(safeAvatar));
    const files = this.store.listFilesByExtension(dir, '.jsonl');
    for (const file of files) {
      this.rescanChatItem('character', safeAvatar, '', file.name);
    }
  }

  rescanCharacterName(avatar: string): void {
    if (avatar.length === 0) {
      return;
    }
    const resolved = this.resolveCharacterName(avatar);
    if (resolved.length === 0) {
      return;
    }
    this.ensureCharacterNamesLoaded();
    this.characterNames.set(avatar, resolved);
    this.writeCharacterNames();
  }

  orphanizeCharacterChats(avatar: string, dirName: string): void {
    this.ensureCacheLoaded();
    let changed = false;
    this.cachedItems = this.cachedItems.map((candidate: ChatBrowserItem): ChatBrowserItem => {
      if (candidate.kind === 'character' && candidate.avatar === avatar) {
        const updated = this.copyItem(candidate);
        updated.kind = 'orphan_character';
        updated.avatar = '';
        updated.title = dirName;
        updated.subtitle = '聊天目录未关联到角色';
        updated.openable = false;
        updated.id = `orphan_character:::${updated.fileName}`;
        changed = true;
        return updated;
      }
      return candidate;
    });
    if (changed) {
      this.cacheRefreshedAt = Date.now();
      this.writeCache();
    }
  }

  duplicateCharacterName(sourceAvatar: string, targetAvatar: string): void {
    this.ensureCharacterNamesLoaded();
    if (targetAvatar.length === 0 || sourceAvatar.length === 0) {
      return;
    }
    const name = this.characterNames.get(sourceAvatar) ?? withoutExtension(sourceAvatar);
    this.characterNames.set(targetAvatar, name);
    this.writeCharacterNames();
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
      if (parsedItems.length === 0) {
        this.refreshCacheAsync().catch(() => {
          hilog.error(DOMAIN, TAG, 'async rebuild failed after empty cache');
        });
      }
      return;
    }
    this.cacheLoaded = true;
    this.cachedItems = [];
    this.refreshCacheAsync().catch(() => {
      hilog.error(DOMAIN, TAG, 'async rebuild failed after missing cache');
    });
  }

  private writeCache(): void {
    const cache = emptyJsonRecord();
    cache['version'] = 1;
    cache['refreshedAt'] = this.cacheRefreshedAt;
    cache['items'] = this.cachedItems;
    this.store.writeJson(this.cachePath, cache);
  }

  private ensureCharacterNamesLoaded(): void {
    if (this.characterNamesLoaded) {
      return;
    }
    this.characterNamesLoaded = true;
    const data = this.store.readJsonRecord(this.characterNamesPath);
    const names = asRecord(data['names']);
    for (const key of Object.keys(names)) {
      const value = asString(names[key]);
      if (value.length > 0) {
        this.characterNames.set(key, value);
      }
    }
  }

  private writeCharacterNames(): void {
    const names: Record<string, string> = {};
    this.characterNames.forEach((name: string, avatar: string) => {
      names[avatar] = name;
    });
    const data = emptyJsonRecord();
    data['version'] = 1;
    data['names'] = names;
    this.store.writeJson(this.characterNamesPath, data);
  }

  private upsertCachedItem(item: ChatBrowserItem): void {
    const index = this.cachedItems.findIndex((candidate: ChatBrowserItem): boolean => {
      return this.isSameCachedItem(candidate, item);
    });
    if (index >= 0) {
      this.cachedItems[index] = item;
    } else {
      this.cachedItems.push(item);
    }
    this.cacheRefreshedAt = Date.now();
    this.writeCache();
  }

  private notifyRefreshListeners(items: ChatBrowserItem[]): void {
    for (const listener of this.refreshListeners) {
      listener(items);
    }
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

  private copyItem(item: ChatBrowserItem): ChatBrowserItem {
    const copy = new ChatBrowserItem();
    copy.id = item.id;
    copy.kind = item.kind;
    copy.fileName = item.fileName;
    copy.chatName = item.chatName;
    copy.avatar = item.avatar;
    copy.group = item.group;
    copy.title = item.title;
    copy.subtitle = item.subtitle;
    copy.preview = item.preview;
    copy.lastTimestamp = item.lastTimestamp;
    copy.mtimeMs = item.mtimeMs;
    copy.sizeBytes = item.sizeBytes;
    copy.fileSize = item.fileSize;
    copy.chatItems = item.chatItems;
    copy.openable = item.openable;
    return copy;
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
      const safeAvatar = ensurePngExtension(sanitizeFileName(avatar));
      if (safeAvatar.length === 0 || safeAvatar === 'unnamed.png') {
        return false;
      }
      const deleted = this.store.deleteFile(joinPath(this.userDirs.chats, withoutExtension(safeAvatar), safeFile));
      if (deleted) {
        this.removeChatItemByFields('character', safeAvatar, '', safeFile);
      }
      return deleted;
    }

    if (kind === 'group' || kind === 'orphan_group') {
      const deleted = this.store.deleteFile(joinPath(this.userDirs.groupChats, safeFile));
      if (deleted) {
        this.removeChatItemByFields(kind === 'group' ? 'group' : 'orphan_group', '', group, safeFile);
        if (group.length > 0) {
          this.removeGroupChatReference(group, withoutExtension(safeFile));
        }
      }
      return deleted;
    }

    if (kind === 'orphan_character') {
      const deleted = this.deleteOrphanCharacterChat(safeFile);
      if (deleted) {
        this.removeChatItemByFields('orphan_character', '', '', safeFile);
      }
      return deleted;
    }

    if (kind === 'root') {
      const deleted = this.store.deleteFile(joinPath(this.userDirs.chats, safeFile));
      if (deleted) {
        this.removeChatItemByFields('root', '', '', safeFile);
      }
      return deleted;
    }

    return false;
  }

  removeChatItemByFields(kind: string, avatar: string, group: string, fileName: string): void {
    this.ensureCacheLoaded();
    this.cachedItems = this.cachedItems.filter((candidate: ChatBrowserItem): boolean => {
      if (kind === 'character') {
        return !(candidate.kind === 'character' && candidate.avatar === avatar && candidate.fileName === fileName);
      }
      if (kind === 'group' || kind === 'orphan_group') {
        if (candidate.kind !== 'group' && candidate.kind !== 'orphan_group') {
          return true;
        }
        if (group.length > 0 && candidate.group !== group) {
          return true;
        }
        return candidate.fileName !== fileName;
      }
      return !(candidate.kind === kind && candidate.fileName === fileName);
    });
    this.cacheRefreshedAt = Date.now();
    this.writeCache();
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
      const displayName = this.characterName(avatar);
      const chatFiles = this.store.listFilesByExtension(chatDir, '.jsonl');
      for (const chatFile of chatFiles) {
        items.push(this.itemFromFile(chatFile, 'character', avatar, '', displayName, '角色聊天', true));
      }
    }
  }

  private async collectCharacterChatsAsync(items: ChatBrowserItem[],
    characterChatDirs: Record<string, boolean>): Promise<void> {
    const characterFiles = await this.listFilesByExtensionAsync(this.userDirs.characters, '.png');
    for (let index = 0; index < characterFiles.length; index++) {
      if (index > 0 && index % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
        await this.yieldToEventLoop();
      }
      const character = characterFiles[index];
      const avatar = character.name;
      const dirName = withoutExtension(avatar);
      characterChatDirs[dirName] = true;
      const chatDir = joinPath(this.userDirs.chats, dirName);
      if (!this.store.exists(chatDir)) {
        continue;
      }
      const displayName = await this.characterNameAsync(avatar);
      const chatFiles = await this.listFilesByExtensionAsync(chatDir, '.jsonl');
      for (let chatIndex = 0; chatIndex < chatFiles.length; chatIndex++) {
        if (chatIndex > 0 && (index * CHAT_BROWSER_REBUILD_BATCH_SIZE + chatIndex) % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
          await this.yieldToEventLoop();
        }
        const chatFile = chatFiles[chatIndex];
        items.push(await this.itemFromFileAsync(chatFile, 'character', avatar, '', displayName, '角色聊天', true));
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

  private async collectOrphanCharacterChatsAsync(items: ChatBrowserItem[],
    characterChatDirs: Record<string, boolean>): Promise<void> {
    const chatDirs = await this.store.listAsync(this.userDirs.chats);
    for (let index = 0; index < chatDirs.length; index++) {
      if (index > 0 && index % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
        await this.yieldToEventLoop();
      }
      const chatDir = chatDirs[index];
      if (!chatDir.isDirectory || characterChatDirs[chatDir.name] === true) {
        continue;
      }
      const chatFiles = await this.listFilesByExtensionAsync(chatDir.path, '.jsonl');
      for (const chatFile of chatFiles) {
        items.push(await this.itemFromFileAsync(chatFile, 'orphan_character', '', '', chatDir.name, '聊天目录未关联到角色',
          false));
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

  private async collectGroupChatsAsync(items: ChatBrowserItem[]): Promise<void> {
    const seen: Record<string, boolean> = {};
    const groupFiles = await this.listFilesByExtensionAsync(this.userDirs.groups, '.json');
    for (let index = 0; index < groupFiles.length; index++) {
      if (index > 0 && index % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
        await this.yieldToEventLoop();
      }
      const groupFile = groupFiles[index];
      const group = this.store.readJsonRecord(groupFile.path);
      const groupId = asString(group['id']) || withoutExtension(groupFile.name);
      const groupName = asString(group['name']) || groupId;
      const chats = asArray(group['chats']);
      for (const chat of chats) {
        const fileName = ensureJsonlExtension(sanitizeFileName(`${chat}`));
        const file = await this.store.statAsync(joinPath(this.userDirs.groupChats, fileName), fileName);
        if (file === null || !file.isFile) {
          continue;
        }
        seen[fileName] = true;
        items.push(await this.itemFromFileAsync(file, 'group', '', groupId, groupName, '群聊', true));
      }
    }

    const allGroupChats = await this.listFilesByExtensionAsync(this.userDirs.groupChats, '.jsonl');
    for (let index = 0; index < allGroupChats.length; index++) {
      if (index > 0 && index % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
        await this.yieldToEventLoop();
      }
      const chatFile = allGroupChats[index];
      if (seen[chatFile.name] === true) {
        continue;
      }
      items.push(await this.itemFromFileAsync(chatFile, 'orphan_group', '', '', '未关联群聊', '群聊文件未关联到群组', false));
    }
  }

  private collectRootChats(items: ChatBrowserItem[]): void {
    const chatFiles = this.store.listFilesByExtension(this.userDirs.chats, '.jsonl');
    for (const chatFile of chatFiles) {
      items.push(this.itemFromFile(chatFile, 'root', '', '', '未关联聊天', '聊天文件未关联到角色', false));
    }
  }

  private async collectRootChatsAsync(items: ChatBrowserItem[]): Promise<void> {
    const chatFiles = await this.listFilesByExtensionAsync(this.userDirs.chats, '.jsonl');
    for (let index = 0; index < chatFiles.length; index++) {
      if (index > 0 && index % CHAT_BROWSER_REBUILD_BATCH_SIZE === 0) {
        await this.yieldToEventLoop();
      }
      const chatFile = chatFiles[index];
      items.push(await this.itemFromFileAsync(chatFile, 'root', '', '', '未关联聊天', '聊天文件未关联到角色', false));
    }
  }

  private async listFilesByExtensionAsync(path: string, ext: string): Promise<FileEntry[]> {
    const targetExt = ext.toLowerCase();
    const entries = await this.store.listAsync(path);
    const files = entries.filter((entry: FileEntry): boolean => entry.isFile &&
      entry.name.toLowerCase().endsWith(targetExt));
    files.sort((a: FileEntry, b: FileEntry) => a.name.localeCompare(b.name));
    return files;
  }

  private async yieldToEventLoop(): Promise<void> {
    await new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }

  private itemFromFile(file: FileEntry, kind: string, avatar: string, group: string, title: string, subtitle: string,
    openable: boolean): ChatBrowserItem {
    const text = this.store.readText(file.path, '');
    return this.itemFromAnalysis(file, kind, avatar, group, title, subtitle, openable, this.analyzeChatText(text));
  }

  private async itemFromFileAsync(file: FileEntry, kind: string, avatar: string, group: string, title: string,
    subtitle: string, openable: boolean): Promise<ChatBrowserItem> {
    const text = await this.store.readTextAsync(file.path, '');
    return this.itemFromAnalysis(file, kind, avatar, group, title, subtitle, openable, this.analyzeChatText(text));
  }

  private itemFromAnalysis(file: FileEntry, kind: string, avatar: string, group: string, title: string,
    subtitle: string, openable: boolean, analysis: ChatTextAnalysis): ChatBrowserItem {
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
    item.chatItems = Math.max(0, analysis.count - 1);
    item.lastTimestamp = new Date(Math.round(file.mtimeMs)).toISOString();
    item.preview = analysis.preview.length > 0 ? analysis.preview : '[The chat is empty]';
    item.openable = openable;
    item.id = `${kind}:${avatar}:${group}:${file.name}`;
    return item;
  }

  private analyzeChatText(text: string): ChatTextAnalysis {
    const analysis = new ChatTextAnalysis();
    let lastRow: JsonRecord | null = null;
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      try {
        const parsed = JSON.parse(trimmed) as Object;
        if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          analysis.count++;
          lastRow = parsed as JsonRecord;
        }
      } catch (_err) {
      }
    }
    if (lastRow !== null) {
      analysis.preview = asString(lastRow['mes']) || '[The message is empty]';
    }
    return analysis;
  }

  private characterName(avatar: string): string {
    this.ensureCharacterNamesLoaded();
    if (avatar.length === 0) {
      return 'Unknown';
    }
    const cached = this.characterNames.get(avatar);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    const resolved = this.resolveCharacterName(avatar);
    if (resolved.length > 0) {
      this.characterNames.set(avatar, resolved);
      this.writeCharacterNames();
      return resolved;
    }
    return withoutExtension(avatar);
  }

  private async characterNameAsync(avatar: string): Promise<string> {
    this.ensureCharacterNamesLoaded();
    if (avatar.length === 0) {
      return 'Unknown';
    }
    const cached = this.characterNames.get(avatar);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    const resolved = await this.resolveCharacterNameAsync(avatar);
    if (resolved.length > 0) {
      this.characterNames.set(avatar, resolved);
      this.writeCharacterNames();
      return resolved;
    }
    return withoutExtension(avatar);
  }

  private resolveCharacterName(avatar: string): string {
    const path = joinPath(this.userDirs.characters, ensurePngExtension(avatar));
    const bytes = this.store.readBytes(path);
    if (bytes === null) {
      return '';
    }
    return this.nameFromCardBytes(bytes);
  }

  private async resolveCharacterNameAsync(avatar: string): Promise<string> {
    const path = joinPath(this.userDirs.characters, ensurePngExtension(avatar));
    const bytes = await this.store.readBytesAsync(path);
    if (bytes === null) {
      return '';
    }
    return this.nameFromCardBytes(bytes);
  }

  private nameFromCardBytes(bytes: Uint8Array): string {
    const card = this.cardStore.readCardFromBytes(bytes);
    if (card !== null) {
      const data = asRecord(card['data']);
      const name = asString(card['name']) || asString(data['name']);
      if (name.length > 0) {
        return name;
      }
    }
    return '';
  }

  private groupName(groupId: string): string {
    if (groupId.length === 0) {
      return '群聊';
    }
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      const storedId = asString(group['id']) || withoutExtension(groupFile.name);
      if (storedId === groupId) {
        return asString(group['name']) || groupId;
      }
    }
    return groupId;
  }

  private groupBelonging(chatId: string): GroupBelonging | null {
    const groupFiles = this.store.listFilesByExtension(this.userDirs.groups, '.json');
    for (const groupFile of groupFiles) {
      const group = this.store.readJsonRecord(groupFile.path);
      const chats = asArray(group['chats']);
      if (chats.includes(chatId)) {
        const belonging = new GroupBelonging();
        belonging.groupId = asString(group['id']) || withoutExtension(groupFile.name);
        belonging.groupName = asString(group['name']) || belonging.groupId;
        return belonging;
      }
    }
    return null;
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
