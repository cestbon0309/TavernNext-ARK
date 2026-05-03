import { util } from '@kit.ArkTS';
import { DataDirectories } from '../DataDirectories';
import { FileEntry, FileStore } from '../FileStore';
import { HttpRequest, HttpResponse, HttpStreamSend, JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { asNumber, parseJsonRecord } from '../JsonUtils';
import { joinPath } from '../PathUtils';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { asArrayValue, asRecordValue, asStringValue, messageContentToText } from './JsonHelpers';

const DEFAULT_KEEP = 5;

type LoggerJsonValue = Object | string | number | boolean | null | JsonArray | undefined;

export class LlmApiLogContext {
  id: number = 0;
  timestampMs: number = 0;
  startedMs: number = 0;
  source: ChatCompletionSource = 'openai';
  model: string = '';
  endpoint: string = '';
  stream: boolean = false;
  requestRaw: string = '';
  requestReadable: string = '';
}

class LlmApiLogIndexEntry {
  id: number = 0;
  timestampMs: number = 0;
  level: string = 'INFO';
  ok: boolean = true;
  source: string = '';
  model: string | null = null;
  endpoint: string = '';
  durationMs: number = 0;
  stream: boolean = false;
}

class LlmApiLogMeta extends LlmApiLogIndexEntry {
  errorMessage: string | null = null;
  requestReadable: string = '';
  responseReadable: string = '';
  requestRawKind: string = 'json';
  responseRawKind: string | null = null;
}

class LlmApiLogSubscriber {
  id: number;
  send: HttpStreamSend;
  active: boolean = true;

  constructor(id: number, send: HttpStreamSend) {
    this.id = id;
    this.send = send;
  }
}

export class LlmApiStreamLogSink {
  private logger: LlmApiLogger;
  private context: LlmApiLogContext;
  private raw: string = '';
  private readable: StreamReadableCollector;
  private completed: boolean = false;
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  constructor(logger: LlmApiLogger, context: LlmApiLogContext) {
    this.logger = logger;
    this.context = context;
    this.readable = new StreamReadableCollector(context.source, context.endpoint);
  }

  wrapSend(send: HttpStreamSend): HttpStreamSend {
    return async (chunk: string | Uint8Array): Promise<void> => {
      await send(chunk);
      this.recordChunk(chunk);
    };
  }

  wrapReadableSend(send: HttpStreamSend): HttpStreamSend {
    return async (chunk: string | Uint8Array): Promise<void> => {
      await send(chunk);
      this.recordReadableChunk(chunk);
    };
  }

  recordEvent(event: string): void {
    if (event.trim().length === 0) {
      return;
    }
    this.raw += `data: ${event}\n\n`;
  }

  finishOk(): void {
    if (this.completed) {
      return;
    }
    this.completed = true;
    this.logger.finishStream(this.context, true, '', this.raw, this.readable.intoString());
  }

  finishError(errorMessage: string): void {
    if (this.completed) {
      return;
    }
    this.completed = true;
    this.logger.finishStream(this.context, false, errorMessage, this.raw, this.readable.intoString());
  }

  private recordChunk(chunk: string | Uint8Array): void {
    const text = typeof chunk === 'string' ? chunk : this.bytesToString(chunk);
    if (text.length === 0) {
      return;
    }
    this.raw += text;
    this.readable.pushText(text);
  }

  private recordReadableChunk(chunk: string | Uint8Array): void {
    const text = typeof chunk === 'string' ? chunk : this.bytesToString(chunk);
    if (text.length > 0) {
      this.readable.pushText(text);
    }
  }

  private bytesToString(bytes: Uint8Array): string {
    return this.decoder.decodeToString(bytes);
  }
}

export class LlmApiLogger {
  private store: FileStore;
  private dirs: DataDirectories;
  private nextId: number = 1;
  private keep: number = DEFAULT_KEEP;
  private streamEnabled: boolean = false;
  private nextSubscriberId: number = 1;
  private subscribers: LlmApiLogSubscriber[] = [];

  constructor(store: FileStore, dirs: DataDirectories) {
    this.store = store;
    this.dirs = dirs;
    this.loadSettings();
    this.ensureNextId();
  }

  begin(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string, payload: JsonRecord,
    stream: boolean): LlmApiLogContext {
    const context = new LlmApiLogContext();
    context.id = this.allocateId();
    context.timestampMs = Date.now();
    context.startedMs = context.timestampMs;
    context.source = source;
    context.model = asStringValue(payload['model']).trim();
    context.endpoint = this.formatEndpoint(config.baseUrl, endpointPath);
    context.stream = stream;
    context.requestRaw = this.prettyJson(payload);
    context.requestReadable = this.formatRequestReadable(source, endpointPath, payload);
    return context;
  }

  finishJson(context: LlmApiLogContext, ok: boolean, response: JsonRecord | null, rawText: string,
    errorMessage: string): void {
    const responseRaw = rawText.length > 0 ? rawText : (response === null ? '' : this.prettyJson(response));
    const responseReadable = ok && response !== null ? this.formatResponseReadable(response) : errorMessage;
    const meta = this.metaFromContext(context, ok, errorMessage, responseReadable, 'json');
    this.writeEntry(meta, context.requestRaw, responseRaw);
  }

  finishStream(context: LlmApiLogContext, ok: boolean, errorMessage: string, responseRaw: string,
    responseReadable: string): void {
    const fallback = ok ? responseReadable : errorMessage;
    const meta = this.metaFromContext(context, ok, errorMessage, fallback, 'sse');
    this.writeEntry(meta, context.requestRaw, responseRaw);
  }

  createStreamSink(context: LlmApiLogContext): LlmApiStreamLogSink {
    this.store.writeText(this.requestPath(context.id), context.requestRaw);
    return new LlmApiStreamLogSink(this, context);
  }

  index(request: HttpRequest): HttpResponse {
    const limit = this.limitFromRequest(request, DEFAULT_KEEP);
    const entries = this.readIndex();
    const start = Math.max(0, entries.length - limit);
    return HttpResponse.json(entries.slice(start));
  }

  preview(request: HttpRequest): HttpResponse {
    const id = this.idFromRequest(request);
    if (id <= 0) {
      return HttpResponse.empty(400);
    }
    const meta = this.store.readJsonRecord(this.metaPath(id));
    if (Object.keys(meta).length === 0) {
      return HttpResponse.empty(404);
    }
    return HttpResponse.json(meta);
  }

  raw(request: HttpRequest): HttpResponse {
    const id = this.idFromRequest(request);
    if (id <= 0) {
      return HttpResponse.empty(400);
    }
    const response = emptyJsonRecord();
    response['id'] = id;
    response['requestRaw'] = this.store.readText(this.requestPath(id), '');
    response['responseRaw'] = this.store.readText(this.responseJsonPath(id), '');
    response['responseRawKind'] = 'json';
    if (response['responseRaw'] === '') {
      response['responseRaw'] = this.store.readText(this.responseSsePath(id), '');
      response['responseRawKind'] = response['responseRaw'] === '' ? null : 'sse';
    }
    return HttpResponse.json(response);
  }

  settings(request: HttpRequest): HttpResponse {
    if (request.method === 'POST') {
      const body = request.body;
      if (body !== null && !Array.isArray(body) && typeof body === 'object') {
        const record = body as JsonRecord;
        const keep = asNumber(record['keep'], this.keep);
        if (Number.isFinite(keep) && keep > 0) {
          this.keep = Math.min(100, Math.floor(keep));
        }
        if (typeof record['streamEnabled'] === 'boolean') {
          this.streamEnabled = record['streamEnabled'] as boolean;
        }
        if (typeof record['enabled'] === 'boolean') {
          this.streamEnabled = record['enabled'] as boolean;
        }
        this.saveSettings();
        this.writeIndexAndPrune(this.readIndex());
      }
    }
    return HttpResponse.json(this.settingsRecord());
  }

  keepSettings(request: HttpRequest): HttpResponse {
    if (request.method === 'POST') {
      const body = request.body;
      if (body !== null && !Array.isArray(body) && typeof body === 'object') {
        const keep = asNumber((body as JsonRecord)['keep'], this.keep);
        if (Number.isFinite(keep) && keep > 0) {
          this.keep = Math.min(100, Math.floor(keep));
          this.saveSettings();
          this.writeIndexAndPrune(this.readIndex());
        }
      }
    }
    const response = emptyJsonRecord();
    response['keep'] = this.keep;
    return HttpResponse.json(response);
  }

  streamEnabledSettings(request: HttpRequest): HttpResponse {
    if (request.method === 'POST') {
      const body = request.body;
      if (body !== null && !Array.isArray(body) && typeof body === 'object') {
        const record = body as JsonRecord;
        if (typeof record['enabled'] === 'boolean') {
          this.streamEnabled = record['enabled'] as boolean;
          this.saveSettings();
        }
      }
    }
    const response = emptyJsonRecord();
    response['enabled'] = this.streamEnabled;
    return HttpResponse.json(response);
  }

  stream(request: HttpRequest): HttpResponse {
    return HttpResponse.stream('text/event-stream; charset=utf-8', async (send: HttpStreamSend): Promise<void> => {
      let active = true;
      await send(': connected\n\n');
      if (this.streamEnabled) {
        const entries = this.readIndex();
        for (const entry of entries) {
          await send(`event: llm-api-log\ndata: ${JSON.stringify(entry)}\n\n`);
        }
      }
      const subscriber = new LlmApiLogSubscriber(this.nextSubscriberId, send);
      this.nextSubscriberId += 1;
      this.subscribers.push(subscriber);
      while (active && subscriber.active) {
        try {
          await send(': heartbeat\n\n');
        } catch (_err) {
          active = false;
          subscriber.active = false;
        }
        if (active && subscriber.active) {
          await this.delay(15000);
        }
      }
      this.subscribers = this.subscribers.filter((item: LlmApiLogSubscriber): boolean => item.id !== subscriber.id);
    });
  }

  private writeEntry(meta: LlmApiLogMeta, requestRaw: string, responseRaw: string): void {
    this.store.writeJson(this.metaPath(meta.id), meta);
    if (requestRaw.length > 0 && !this.store.exists(this.requestPath(meta.id))) {
      this.store.writeText(this.requestPath(meta.id), requestRaw);
    }
    if (meta.responseRawKind === 'json') {
      this.store.writeText(this.responseJsonPath(meta.id), responseRaw);
    } else if (meta.responseRawKind === 'sse') {
      this.store.writeText(this.responseSsePath(meta.id), responseRaw);
    }
    const entry = this.indexEntry(meta);
    const next = this.readIndex();
    next.push(entry);
    this.writeIndexAndPrune(next);
    this.publish(entry);
  }

  private metaFromContext(context: LlmApiLogContext, ok: boolean, errorMessage: string, responseReadable: string,
    responseRawKind: string | null): LlmApiLogMeta {
    const meta = new LlmApiLogMeta();
    meta.id = context.id;
    meta.timestampMs = context.timestampMs;
    meta.level = ok ? 'INFO' : 'ERROR';
    meta.ok = ok;
    meta.source = context.source;
    meta.model = context.model.length > 0 ? context.model : null;
    meta.endpoint = context.endpoint;
    meta.durationMs = Math.max(0, Math.floor(Date.now() - context.startedMs));
    meta.stream = context.stream;
    meta.errorMessage = errorMessage.length > 0 ? errorMessage : null;
    meta.requestReadable = context.requestReadable;
    meta.responseReadable = responseReadable.length > 0 ? responseReadable : '<response unavailable>';
    meta.requestRawKind = 'json';
    meta.responseRawKind = responseRawKind;
    return meta;
  }

  private indexEntry(meta: LlmApiLogMeta): LlmApiLogIndexEntry {
    const entry = new LlmApiLogIndexEntry();
    entry.id = meta.id;
    entry.timestampMs = meta.timestampMs;
    entry.level = meta.level;
    entry.ok = meta.ok;
    entry.source = meta.source;
    entry.model = meta.model;
    entry.endpoint = meta.endpoint;
    entry.durationMs = meta.durationMs;
    entry.stream = meta.stream;
    return entry;
  }

  private writeIndexAndPrune(entries: LlmApiLogIndexEntry[]): void {
    const keep = this.keep;
    const sorted = entries.sort((left: LlmApiLogIndexEntry, right: LlmApiLogIndexEntry): number => left.id - right.id);
    const survivors = sorted.slice(Math.max(0, sorted.length - keep));
    const survivorIds = new Set<number>();
    for (const entry of survivors) {
      survivorIds.add(entry.id);
    }
    for (const entry of sorted) {
      if (!survivorIds.has(entry.id)) {
        this.deleteEntryFiles(entry.id);
      }
    }
    this.store.writeJson(this.indexPath(), survivors);
  }

  private publish(entry: LlmApiLogIndexEntry): void {
    if (!this.streamEnabled || this.subscribers.length === 0) {
      return;
    }
    const survivors: LlmApiLogSubscriber[] = [];
    for (const subscriber of this.subscribers) {
      if (!subscriber.active) {
        continue;
      }
      survivors.push(subscriber);
      subscriber.send(`event: llm-api-log\ndata: ${JSON.stringify(entry)}\n\n`).catch((_err: Error) => {
        subscriber.active = false;
      });
    }
    this.subscribers = survivors.filter((subscriber: LlmApiLogSubscriber): boolean => subscriber.active);
  }

  private loadSettings(): void {
    const settings = this.store.readJsonRecord(this.settingsPath());
    const keep = asNumber(settings['keep'], DEFAULT_KEEP);
    this.keep = Number.isFinite(keep) && keep > 0 ? Math.min(100, Math.floor(keep)) : DEFAULT_KEEP;
    this.streamEnabled = settings['streamEnabled'] === true;
  }

  private saveSettings(): void {
    this.store.writeJson(this.settingsPath(), this.settingsRecord());
  }

  private async delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private settingsRecord(): JsonRecord {
    const response = emptyJsonRecord();
    response['keep'] = this.keep;
    response['streamEnabled'] = this.streamEnabled;
    return response;
  }

  private readIndex(): LlmApiLogIndexEntry[] {
    const record = this.store.readJsonObject(this.indexPath(), []) as Object;
    if (!Array.isArray(record)) {
      return [];
    }
    const entries: LlmApiLogIndexEntry[] = [];
    for (const item of record as JsonArray) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const source = item as JsonRecord;
      const entry = new LlmApiLogIndexEntry();
      entry.id = asNumber(source['id']);
      entry.timestampMs = asNumber(source['timestampMs']);
      entry.level = asStringValue(source['level']) || 'INFO';
      entry.ok = source['ok'] !== false;
      entry.source = asStringValue(source['source']);
      const model = source['model'];
      entry.model = typeof model === 'string' && model.length > 0 ? model : null;
      entry.endpoint = asStringValue(source['endpoint']);
      entry.durationMs = asNumber(source['durationMs']);
      entry.stream = source['stream'] === true;
      if (entry.id > 0) {
        entries.push(entry);
      }
    }
    return entries;
  }

  private ensureNextId(): void {
    const entries = this.readIndex();
    for (const entry of entries) {
      this.nextId = Math.max(this.nextId, entry.id + 1);
    }
    const files = this.store.list(this.dirs.llmApiLogRoot);
    for (const file of files) {
      const id = this.idFromFile(file);
      if (id > 0) {
        this.nextId = Math.max(this.nextId, id + 1);
      }
    }
  }

  private allocateId(): number {
    const id = this.nextId;
    this.nextId += 1;
    return id;
  }

  private idFromFile(file: FileEntry): number {
    const name = file.name;
    if (!name.startsWith('llm-api-')) {
      return 0;
    }
    const rest = name.slice('llm-api-'.length);
    const dot = rest.indexOf('.');
    if (dot <= 0) {
      return 0;
    }
    const value = Number(rest.slice(0, dot));
    return Number.isFinite(value) ? Math.floor(value) : 0;
  }

  private limitFromRequest(request: HttpRequest, fallback: number): number {
    const queryLimit = Number(request.query['limit'] ?? '');
    if (Number.isFinite(queryLimit) && queryLimit > 0) {
      return Math.min(100, Math.floor(queryLimit));
    }
    const body = request.body;
    if (body !== null && !Array.isArray(body) && typeof body === 'object') {
      const value = Number((body as JsonRecord)['limit']);
      if (Number.isFinite(value) && value > 0) {
        return Math.min(100, Math.floor(value));
      }
    }
    return fallback;
  }

  private idFromRequest(request: HttpRequest): number {
    const queryId = Number(request.query['id'] ?? '');
    if (Number.isFinite(queryId) && queryId > 0) {
      return Math.floor(queryId);
    }
    const body = request.body;
    if (body !== null && !Array.isArray(body) && typeof body === 'object') {
      const value = Number((body as JsonRecord)['id']);
      return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
    }
    return 0;
  }

  private deleteEntryFiles(id: number): void {
    this.store.deleteFile(this.metaPath(id));
    this.store.deleteFile(this.requestPath(id));
    this.store.deleteFile(this.responseJsonPath(id));
    this.store.deleteFile(this.responseSsePath(id));
  }

  private formatEndpoint(baseUrl: string, endpointPath: string): string {
    const base = baseUrl.trim().replace(/\/+$/, '');
    const path = endpointPath.trim();
    if (base.length === 0) {
      return path;
    }
    if (path.length === 0) {
      return base;
    }
    return path.startsWith('/') ? `${base}${path}` : `${base}/${path}`;
  }

  private prettyJson(value: Object): string {
    try {
      return JSON.stringify(value, null, 2);
    } catch (_err) {
      return JSON.stringify(emptyJsonRecord());
    }
  }

  private formatRequestReadable(source: ChatCompletionSource, endpointPath: string, payload: JsonRecord): string {
    if (source === 'makersuite' || source === 'vertexai') {
      return this.formatGeminiContents(payload);
    }
    if (source === 'claude' || endpointPath === '/messages') {
      return this.formatClaudeMessages(payload);
    }
    if (payload['input'] !== undefined) {
      return this.formatInputItems(payload['input'], asStringValue(payload['system_instruction']));
    }
    return this.formatOpenAiMessages(payload);
  }

  private formatOpenAiMessages(payload: JsonRecord): string {
    const messages = asArrayValue(payload['messages']);
    if (messages.length === 0) {
      return '<messages unavailable>';
    }
    const out: string[] = [];
    for (const item of messages) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']) || 'unknown';
      out.push(`[${role}]\n${messageContentToText(message['content'])}`);
    }
    return out.length > 0 ? out.join('\n\n') : '<messages unavailable>';
  }

  private formatClaudeMessages(payload: JsonRecord): string {
    return this.formatOpenAiMessages(payload);
  }

  private formatGeminiContents(payload: JsonRecord): string {
    const contents = asArrayValue(payload['contents']);
    if (contents.length === 0) {
      return '<contents unavailable>';
    }
    const out: string[] = [];
    for (const item of contents) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const content = item as JsonRecord;
      const role = asStringValue(content['role']) || 'unknown';
      const parts = asArrayValue(content['parts']);
      const textParts: string[] = [];
      for (const part of parts) {
        if (part !== null && !Array.isArray(part) && typeof part === 'object') {
          textParts.push(asStringValue((part as JsonRecord)['text']));
        }
      }
      out.push(`[${role}]\n${textParts.join('')}`);
    }
    return out.length > 0 ? out.join('\n\n') : '<contents unavailable>';
  }

  private formatInputItems(value: LoggerJsonValue, systemInstruction: string): string {
    const out: string[] = [];
    if (systemInstruction.trim().length > 0) {
      out.push(`[system]\n${systemInstruction.trim()}`);
    }
    if (typeof value === 'string') {
      out.push(`[user]\n${value}`);
    } else if (Array.isArray(value)) {
      const items: JsonArray = value;
      for (let index = 0; index < items.length; index += 1) {
        const item: Object | string | number | boolean | null = items[index];
        if (item === null || Array.isArray(item) || typeof item !== 'object') {
          continue;
        }
        const record = item as JsonRecord;
        const role = asStringValue(record['role']) || asStringValue(record['type']) || 'input';
        out.push(`[${role}]\n${messageContentToText(record['content'] ?? item)}`);
      }
    }
    return out.length > 0 ? out.join('\n\n') : '<input unavailable>';
  }

  private formatResponseReadable(response: JsonRecord): string {
    const choices = asArrayValue(response['choices']);
    if (choices.length > 0) {
      const first = choices[0];
      if (first !== null && !Array.isArray(first) && typeof first === 'object') {
        const message = asRecordValue((first as JsonRecord)['message']);
        const content = asStringValue(message['content']);
        if (content.length > 0) {
          return content;
        }
      }
    }
    return '<response unavailable>';
  }

  private indexPath(): string {
    return joinPath(this.dirs.llmApiLogRoot, 'llm-api-index.json');
  }

  private metaPath(id: number): string {
    return joinPath(this.dirs.llmApiLogRoot, `llm-api-${id}.meta.json`);
  }

  private requestPath(id: number): string {
    return joinPath(this.dirs.llmApiLogRoot, `llm-api-${id}.request.json`);
  }

  private responseJsonPath(id: number): string {
    return joinPath(this.dirs.llmApiLogRoot, `llm-api-${id}.response.json`);
  }

  private responseSsePath(id: number): string {
    return joinPath(this.dirs.llmApiLogRoot, `llm-api-${id}.response.sse`);
  }

  private settingsPath(): string {
    return joinPath(this.dirs.llmApiLogRoot, 'llm-api-settings.json');
  }
}

class StreamReadableCollector {
  private source: ChatCompletionSource;
  private endpoint: string;
  private lineBuffer: string = '';
  private buffer: string = '';

  constructor(source: ChatCompletionSource, endpoint: string) {
    this.source = source;
    this.endpoint = endpoint;
  }

  pushText(text: string): void {
    this.lineBuffer += text;
    let newline = this.lineBuffer.indexOf('\n');
    while (newline >= 0) {
      const line = this.lineBuffer.slice(0, newline).replace(/\r$/, '');
      this.lineBuffer = this.lineBuffer.slice(newline + 1);
      this.pushLine(line);
      newline = this.lineBuffer.indexOf('\n');
    }
  }

  intoString(): string {
    if (this.lineBuffer.length > 0) {
      this.pushLine(this.lineBuffer.replace(/\r$/, ''));
      this.lineBuffer = '';
    }
    return this.buffer;
  }

  private pushLine(line: string): void {
    if (!line.startsWith('data:')) {
      return;
    }
    const data = line.slice(5).trim();
    if (data.length === 0 || data === '[DONE]') {
      return;
    }
    const source = this.readableSource();
    if (source === 'claude') {
      this.pushClaude(data);
    } else if (source === 'cohere') {
      this.pushCohere(data);
    } else if (source === 'makersuite' || source === 'vertexai') {
      this.pushGemini(data);
    } else {
      this.pushOpenAi(data);
    }
  }

  private readableSource(): ChatCompletionSource {
    if (this.endpoint.endsWith('/messages')) {
      return 'claude';
    }
    return this.source;
  }

  private pushOpenAi(data: string): void {
    const parsed = parseJsonRecord(data);
    const choices = asArrayValue(parsed['choices']);
    for (const item of choices) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const delta = asRecordValue((item as JsonRecord)['delta']);
      this.buffer += asStringValue(delta['content']);
      this.buffer += asStringValue(delta['reasoning_content']);
    }
  }

  private pushClaude(data: string): void {
    const parsed = parseJsonRecord(data);
    if (asStringValue(parsed['type']) !== 'content_block_delta') {
      return;
    }
    const delta = asRecordValue(parsed['delta']);
    if (asStringValue(delta['type']) === 'text_delta') {
      this.buffer += asStringValue(delta['text']);
    }
  }

  private pushCohere(data: string): void {
    const parsed = parseJsonRecord(data);
    const message = asRecordValue(asRecordValue(parsed['delta'])['message']);
    const content = asRecordValue(message['content']);
    this.buffer += asStringValue(content['text']);
    this.buffer += asStringValue(message['tool_plan']);
  }

  private pushGemini(data: string): void {
    const parsed = parseJsonRecord(data);
    const candidates = asArrayValue(parsed['candidates']);
    if (candidates.length === 0 || candidates[0] === null || Array.isArray(candidates[0]) ||
      typeof candidates[0] !== 'object') {
      return;
    }
    const content = asRecordValue((candidates[0] as JsonRecord)['content']);
    const parts = asArrayValue(content['parts']);
    for (const part of parts) {
      if (part !== null && !Array.isArray(part) && typeof part === 'object') {
        this.buffer += asStringValue((part as JsonRecord)['text']);
      }
    }
  }
}
