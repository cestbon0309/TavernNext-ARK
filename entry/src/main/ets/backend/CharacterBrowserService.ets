import { JsonArray, JsonRecord } from './HttpTypes';
import { asArray, asBoolean, asNumber, asRecord, asString } from './JsonUtils';
import { RemoteHttpClient, RemoteHttpResult } from './RemoteHttpClient';

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
    const extensions: JsonRecord = {};
    extensions['fav'] = favorite;
    const data: JsonRecord = {};
    data['extensions'] = extensions;
    const payload: JsonRecord = {};
    payload['avatar'] = avatar;
    payload['fav'] = favorite;
    payload['data'] = data;
    const result = await this.http.postJson(this.http.joinUrl(baseUrl, '/api/characters/merge-attributes'), payload);
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
}
