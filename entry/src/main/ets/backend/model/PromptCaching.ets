import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { DataDirectories } from '../DataDirectories';
import { FileStore } from '../FileStore';
import { JsonArray, JsonRecord, emptyJsonRecord } from '../HttpTypes';
import { joinPath } from '../PathUtils';
import { ChatCompletionApiConfig, ChatCompletionSource } from './ChatCompletionTypes';
import { asArrayValue, asBooleanValue, asRecordValue, asStringValue, cloneJsonValue } from './JsonHelpers';

const PROMPT_CACHE_VERSION = 1;

type PromptCacheStrategy = 'claude' | 'openrouter_claude' | 'nanogpt_claude' | 'none';

class PromptDigestSnapshot {
  version: number = PROMPT_CACHE_VERSION;
  digests: string[] = [];
}

class PromptCacheLocation {
  kind: string = '';
  first: number = 0;
  second: number = 0;
}

class PromptCachePlan {
  strategy: PromptCacheStrategy = 'none';
  key: string = '';
  anthropicBetaHeaderMode: string = '';
}

class PromptDigestCollection {
  locations: PromptCacheLocation[] = [];
  snapshot: PromptDigestSnapshot = new PromptDigestSnapshot();
}

export class PromptCachingService {
  private snapshots: Record<string, PromptDigestSnapshot> = {};
  private dirs: DataDirectories;
  private store: FileStore;
  private cacheRoot: string;

  constructor(dirs: DataDirectories, store: FileStore) {
    this.dirs = dirs;
    this.store = store;
    this.cacheRoot = joinPath(this.dirs.cacheRoot, 'prompt-cache');
    this.store.ensureDir(this.cacheRoot);
  }

  apply(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string, payload: JsonRecord,
    originalPayload: JsonRecord): ChatCompletionApiConfig {
    const ttl = this.resolveTtl(originalPayload);
    if (ttl.length === 0) {
      return config;
    }
    const plan = this.resolvePlan(source, config, endpointPath, payload, originalPayload);
    if (plan.strategy === 'none') {
      return config;
    }
    if (this.containsCacheControl(payload)) {
      throw new Error('Claude prompt caching cannot be combined with manually supplied cache_control fields');
    }
    if (plan.anthropicBetaHeaderMode.length > 0) {
      config.anthropicBetaHeaderMode = plan.anthropicBetaHeaderMode === 'prompt_caching_only' ?
        'prompt_caching_only' : 'claude_defaults';
    }
    if (plan.strategy === 'nanogpt_claude') {
      payload['cache_control'] = this.nanoGptCacheControl(ttl);
      return config;
    }
    const previous = this.loadSnapshot(plan.key);
    let snapshot = new PromptDigestSnapshot();
    if (plan.strategy === 'openrouter_claude') {
      snapshot = this.applyOpenRouterClaude(payload, previous, ttl);
    } else {
      snapshot = this.applyClaude(payload, previous, ttl);
    }
    this.saveSnapshot(plan.key, snapshot);
    return config;
  }

  private resolvePlan(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string,
    payload: JsonRecord, originalPayload: JsonRecord): PromptCachePlan {
    const plan = new PromptCachePlan();
    if (source === 'claude') {
      plan.strategy = 'claude';
      plan.key = 'claude';
      plan.anthropicBetaHeaderMode = 'claude_defaults';
      return plan;
    }
    if (source === 'openrouter' && this.isOpenRouterClaudeModel(payload)) {
      plan.strategy = 'openrouter_claude';
      plan.key = 'openrouter_claude';
      return plan;
    }
    if (source === 'nanogpt' && this.isNanoGptClaudeModel(payload)) {
      plan.strategy = 'nanogpt_claude';
      plan.key = 'nanogpt_claude';
      return plan;
    }
    if (source === 'custom' && asBooleanValue(originalPayload['custom_claude_prompt_caching'])) {
      if (endpointPath !== '/messages') {
        throw new Error('Custom Claude prompt caching requires custom_api_format=claude_messages');
      }
      plan.strategy = 'claude';
      plan.key = `custom_claude_${this.digestText(config.baseUrl.trim().replace(/\/+$/, ''))}`;
      plan.anthropicBetaHeaderMode = 'prompt_caching_only';
    }
    return plan;
  }

  private resolveTtl(originalPayload: JsonRecord): string {
    const raw = asStringValue(originalPayload['prompt_cache_ttl']) ||
      asStringValue(originalPayload['claude_prompt_cache_ttl']) ||
      asStringValue(originalPayload['promptCacheTtl']);
    if (raw.trim().length > 0) {
      return this.parseTtl(raw);
    }
    const settingsPath = joinPath(this.dirs.defaultUser.root, 'settings.json');
    const settings = this.store.readJsonRecord(settingsPath);
    const models = asRecordValue(settings['models']);
    const claude = asRecordValue(models['claude']);
    return this.parseTtl(asStringValue(claude['prompt_cache_ttl']));
  }

  private parseTtl(raw: string): string {
    const normalized = raw.trim().toLowerCase();
    if (normalized === 'off' || normalized === 'false' || normalized === '0') {
      return '';
    }
    if (normalized === '1h' || normalized === 'one_hour' || normalized === 'one-hour') {
      return '1h';
    }
    if (normalized === '5m' || normalized === 'five_minutes' || normalized === 'five-minutes' ||
      normalized === 'true') {
      return '5m';
    }
    if (normalized.length === 0) {
      return '';
    }
    throw new Error(`Unsupported Claude prompt cache TTL: ${raw}`);
  }

  private loadSnapshot(key: string): PromptDigestSnapshot | undefined {
    const memory = this.snapshots[key];
    if (memory !== undefined) {
      return memory;
    }
    const path = this.snapshotPath(key);
    const value = this.store.readJsonObject(path, emptyJsonRecord());
    if (value === null || Array.isArray(value) || typeof value !== 'object') {
      return undefined;
    }
    const record = value as JsonRecord;
    const digests = asArrayValue(record['digests']);
    const snapshot = new PromptDigestSnapshot();
    snapshot.version = Number(record['version'] ?? 0);
    for (const digest of digests) {
      if (typeof digest === 'string') {
        snapshot.digests.push(digest);
      }
    }
    if (snapshot.version !== PROMPT_CACHE_VERSION) {
      return undefined;
    }
    this.snapshots[key] = snapshot;
    return snapshot;
  }

  private saveSnapshot(key: string, snapshot: PromptDigestSnapshot): void {
    this.snapshots[key] = snapshot;
    this.store.writeJson(this.snapshotPath(key), snapshot);
  }

  private snapshotPath(key: string): string {
    return joinPath(this.cacheRoot, `${key}.json`);
  }

  private applyClaude(payload: JsonRecord, previous: PromptDigestSnapshot | undefined, ttl: string): PromptDigestSnapshot {
    const collection = this.collectClaudeDigests(payload);
    const snapshot = collection.snapshot;
    if (snapshot.digests.length === 0) {
      return snapshot;
    }
    payload['cache_control'] = this.cacheControl(ttl);
    const systemLocation = this.findClaudeSystemBreakLocation(payload);
    if (systemLocation !== null) {
      this.insertClaudeCacheControl(payload, systemLocation, ttl);
    }
    const preHistoryLocation = this.findClaudePreHistoryBreakLocation(payload);
    if (preHistoryLocation !== null && !this.locationsEqual(preHistoryLocation, this.lastClaudeMessageLocation(collection.locations))) {
      this.insertClaudeCacheControl(payload, preHistoryLocation, ttl);
    }
    if (previous !== undefined && previous.version === PROMPT_CACHE_VERSION) {
      const lcp = this.commonPrefixLen(previous.digests, snapshot.digests);
      if (lcp > 0) {
        const candidate = collection.locations[lcp - 1];
        const last = this.lastClaudeMessageLocation(collection.locations);
        const duplicate = this.locationsEqual(candidate, systemLocation) ||
          this.locationsEqual(candidate, preHistoryLocation) || this.locationsEqual(candidate, last);
        if (!duplicate && candidate.kind === 'message') {
          this.insertClaudeCacheControl(payload, candidate, ttl);
        }
      }
    }
    return snapshot;
  }

  private applyOpenRouterClaude(payload: JsonRecord, previous: PromptDigestSnapshot | undefined,
    ttl: string): PromptDigestSnapshot {
    const collection = this.collectOpenRouterDigests(payload);
    const snapshot = collection.snapshot;
    if (snapshot.digests.length === 0) {
      return snapshot;
    }
    payload['cache_control'] = this.cacheControl(ttl);
    const messages = asArrayValue(payload['messages']);
    const systemLocation = this.findOpenRouterSystemBreakLocation(messages);
    const last = this.lastOpenRouterMessageLocation(messages);
    if (systemLocation !== null && !this.locationsEqual(systemLocation, last)) {
      this.insertOpenRouterCacheControl(messages, systemLocation, ttl);
    }
    const preHistoryLocation = this.findOpenRouterPreHistoryBreakLocation(messages, systemLocation);
    if (preHistoryLocation !== null && !this.locationsEqual(preHistoryLocation, last)) {
      this.insertOpenRouterCacheControl(messages, preHistoryLocation, ttl);
    }
    if (previous !== undefined && previous.version === PROMPT_CACHE_VERSION) {
      const lcp = this.commonPrefixLen(previous.digests, snapshot.digests);
      if (lcp > 0) {
        const candidate = collection.locations[lcp - 1];
        const duplicate = this.locationsEqual(candidate, systemLocation) ||
          this.locationsEqual(candidate, preHistoryLocation) || this.locationsEqual(candidate, last);
        if (!duplicate && candidate.kind === 'message') {
          this.insertOpenRouterCacheControl(messages, candidate, ttl);
        }
      }
    }
    return snapshot;
  }

  private collectClaudeDigests(payload: JsonRecord): PromptDigestCollection {
    const collection = new PromptDigestCollection();
    const tools = asArrayValue(payload['tools']);
    for (let index = 0; index < tools.length; index += 1) {
      const tool = tools[index];
      if (tool !== null && !Array.isArray(tool) && typeof tool === 'object') {
        collection.locations.push(this.location('tool', index, 0));
        collection.snapshot.digests.push(this.digestValue(this.segmentValue('tools', 'tool', this.stripCacheControl(tool))));
      }
    }
    const system = asArrayValue(payload['system']);
    for (let index = 0; index < system.length; index += 1) {
      const block = system[index];
      if (this.isCacheEligibleBlock(block)) {
        collection.locations.push(this.location('system', index, 0));
        collection.snapshot.digests.push(this.digestValue(this.segmentValue('system', 'block', this.stripCacheControl(block))));
      }
    }
    const messages = asArrayValue(payload['messages']);
    for (let messageIndex = 0; messageIndex < messages.length; messageIndex += 1) {
      const message = messages[messageIndex];
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        continue;
      }
      const messageRecord = message as JsonRecord;
      const role = asStringValue(messageRecord['role']);
      const content = asArrayValue(messageRecord['content']);
      for (let blockIndex = 0; blockIndex < content.length; blockIndex += 1) {
        const block = content[blockIndex];
        if (this.isCacheEligibleBlock(block)) {
          collection.locations.push(this.location('message', messageIndex, blockIndex));
          collection.snapshot.digests.push(this.digestValue(this.messageSegmentValue(role, this.stripCacheControl(block))));
        }
      }
    }
    return collection;
  }

  private collectOpenRouterDigests(payload: JsonRecord): PromptDigestCollection {
    const collection = new PromptDigestCollection();
    const tools = asArrayValue(payload['tools']);
    for (let index = 0; index < tools.length; index += 1) {
      const tool = tools[index];
      if (tool !== null && !Array.isArray(tool) && typeof tool === 'object') {
        collection.locations.push(this.location('tool', index, 0));
        collection.snapshot.digests.push(this.digestValue(this.segmentValue('tools', 'tool', this.stripCacheControl(tool))));
      }
    }
    const messages = asArrayValue(payload['messages']);
    for (let messageIndex = 0; messageIndex < messages.length; messageIndex += 1) {
      const message = messages[messageIndex];
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        continue;
      }
      const messageRecord = message as JsonRecord;
      this.ensureOpenRouterContentParts(messageRecord);
      const role = asStringValue(messageRecord['role']);
      const content = asArrayValue(messageRecord['content']);
      for (let partIndex = 0; partIndex < content.length; partIndex += 1) {
        const part = content[partIndex];
        if (this.isCacheEligibleBlock(part)) {
          collection.locations.push(this.location('message', messageIndex, partIndex));
          collection.snapshot.digests.push(this.digestValue(this.messageSegmentValue(role, this.stripCacheControl(part))));
        }
      }
    }
    payload['messages'] = messages;
    return collection;
  }

  private findClaudeSystemBreakLocation(payload: JsonRecord): PromptCacheLocation | null {
    const system = asArrayValue(payload['system']);
    for (let index = system.length - 1; index >= 0; index -= 1) {
      if (this.isCacheEligibleBlock(system[index])) {
        return this.location('system', index, 0);
      }
    }
    return null;
  }

  private findClaudePreHistoryBreakLocation(payload: JsonRecord): PromptCacheLocation | null {
    const messages = asArrayValue(payload['messages']);
    if (messages.length === 0 || messages[0] === null || Array.isArray(messages[0]) || typeof messages[0] !== 'object') {
      return null;
    }
    const content = asArrayValue((messages[0] as JsonRecord)['content']);
    for (let index = content.length - 1; index >= 0; index -= 1) {
      if (this.isCacheEligibleBlock(content[index])) {
        return this.location('message', 0, index);
      }
    }
    return null;
  }

  private lastClaudeMessageLocation(locations: PromptCacheLocation[]): PromptCacheLocation | null {
    for (let index = locations.length - 1; index >= 0; index -= 1) {
      if (locations[index].kind === 'message') {
        return locations[index];
      }
    }
    return null;
  }

  private findOpenRouterSystemBreakLocation(messages: JsonArray): PromptCacheLocation | null {
    let lastSystem = -1;
    for (let index = 0; index < messages.length; index += 1) {
      const message = messages[index];
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        continue;
      }
      const role = asStringValue((message as JsonRecord)['role']);
      if (role === 'system') {
        lastSystem = index;
        continue;
      }
      break;
    }
    if (lastSystem < 0) {
      return null;
    }
    const message = messages[lastSystem];
    if (message === null || Array.isArray(message) || typeof message !== 'object') {
      return null;
    }
    const content = asArrayValue((message as JsonRecord)['content']);
    for (let index = content.length - 1; index >= 0; index -= 1) {
      if (this.isCacheEligibleBlock(content[index])) {
        return this.location('message', lastSystem, index);
      }
    }
    return null;
  }

  private findOpenRouterPreHistoryBreakLocation(messages: JsonArray,
    systemLocation: PromptCacheLocation | null): PromptCacheLocation | null {
    const start = systemLocation === null ? 0 : systemLocation.first + 1;
    for (let messageIndex = start; messageIndex < messages.length; messageIndex += 1) {
      const message = messages[messageIndex];
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        continue;
      }
      if (asStringValue((message as JsonRecord)['role']) === 'system') {
        continue;
      }
      const content = asArrayValue((message as JsonRecord)['content']);
      for (let partIndex = content.length - 1; partIndex >= 0; partIndex -= 1) {
        if (this.isCacheEligibleBlock(content[partIndex])) {
          return this.location('message', messageIndex, partIndex);
        }
      }
      break;
    }
    return null;
  }

  private lastOpenRouterMessageLocation(messages: JsonArray): PromptCacheLocation | null {
    for (let messageIndex = messages.length - 1; messageIndex >= 0; messageIndex -= 1) {
      const message = messages[messageIndex];
      if (message === null || Array.isArray(message) || typeof message !== 'object') {
        continue;
      }
      const content = asArrayValue((message as JsonRecord)['content']);
      for (let partIndex = content.length - 1; partIndex >= 0; partIndex -= 1) {
        if (this.isCacheEligibleBlock(content[partIndex])) {
          return this.location('message', messageIndex, partIndex);
        }
      }
    }
    return null;
  }

  private insertClaudeCacheControl(payload: JsonRecord, location: PromptCacheLocation, ttl: string): void {
    if (location.kind === 'system') {
      const system = asArrayValue(payload['system']);
      this.insertCacheOnBlock(system[location.first], ttl);
      payload['system'] = system;
      return;
    }
    if (location.kind !== 'message') {
      return;
    }
    const messages = asArrayValue(payload['messages']);
    const message = messages[location.first];
    if (message === null || Array.isArray(message) || typeof message !== 'object') {
      return;
    }
    const content = asArrayValue((message as JsonRecord)['content']);
    this.insertCacheOnBlock(content[location.second], ttl);
    (message as JsonRecord)['content'] = content;
    payload['messages'] = messages;
  }

  private insertOpenRouterCacheControl(messages: JsonArray, location: PromptCacheLocation, ttl: string): void {
    const message = messages[location.first];
    if (message === null || Array.isArray(message) || typeof message !== 'object') {
      return;
    }
    const content = asArrayValue((message as JsonRecord)['content']);
    this.insertCacheOnBlock(content[location.second], ttl);
    (message as JsonRecord)['content'] = content;
  }

  private insertCacheOnBlock(block: Object | string | number | boolean | null | undefined, ttl: string): void {
    if (block === undefined || block === null || Array.isArray(block) || typeof block !== 'object') {
      return;
    }
    const record = block as JsonRecord;
    if (record['cache_control'] === undefined) {
      record['cache_control'] = this.cacheControl(ttl);
    }
  }

  private ensureOpenRouterContentParts(message: JsonRecord): void {
    const content = message['content'];
    if (typeof content === 'string') {
      const part = emptyJsonRecord();
      part['type'] = 'text';
      part['text'] = content;
      message['content'] = [part];
    }
  }

  private isCacheEligibleBlock(block: Object | string | number | boolean | null): boolean {
    if (block === null || Array.isArray(block) || typeof block !== 'object') {
      return false;
    }
    const record = block as JsonRecord;
    const type = asStringValue(record['type']);
    if (type.includes('thinking')) {
      return false;
    }
    if (type === 'text' && asStringValue(record['text']).length === 0) {
      return false;
    }
    return true;
  }

  private stripCacheControl(value: Object | string | number | boolean | null): Object | string | number | boolean | null | JsonArray {
    if (value === null || Array.isArray(value) || typeof value !== 'object') {
      return cloneJsonValue(value);
    }
    const source = value as JsonRecord;
    const next = emptyJsonRecord();
    Object.keys(source).forEach((key: string) => {
      if (key !== 'cache_control') {
        next[key] = cloneJsonValue(source[key]);
      }
    });
    return next;
  }

  private segmentValue(segment: string, key: string, value: Object | string | number | boolean | null | JsonArray): JsonRecord {
    const record = emptyJsonRecord();
    record['segment'] = segment;
    record[key] = value;
    return record;
  }

  private messageSegmentValue(role: string, block: Object | string | number | boolean | null | JsonArray): JsonRecord {
    const record = emptyJsonRecord();
    record['segment'] = 'messages';
    record['role'] = role;
    record['block'] = block;
    return record;
  }

  private cacheControl(ttl: string): JsonRecord {
    const value = emptyJsonRecord();
    value['type'] = 'ephemeral';
    value['ttl'] = ttl;
    return value;
  }

  private nanoGptCacheControl(ttl: string): JsonRecord {
    const value = emptyJsonRecord();
    value['enabled'] = true;
    value['ttl'] = ttl;
    return value;
  }

  private location(kind: string, first: number, second: number): PromptCacheLocation {
    const location = new PromptCacheLocation();
    location.kind = kind;
    location.first = first;
    location.second = second;
    return location;
  }

  private locationsEqual(left: PromptCacheLocation | null, right: PromptCacheLocation | null): boolean {
    if (left === null || right === null) {
      return left === right;
    }
    return left.kind === right.kind && left.first === right.first && left.second === right.second;
  }

  private commonPrefixLen(left: string[], right: string[]): number {
    const max = Math.min(left.length, right.length);
    for (let index = 0; index < max; index += 1) {
      if (left[index] !== right[index]) {
        return index;
      }
    }
    return max;
  }

  private isOpenRouterClaudeModel(payload: JsonRecord): boolean {
    return asStringValue(payload['model']).trim().toLowerCase().startsWith('anthropic/claude');
  }

  private isNanoGptClaudeModel(payload: JsonRecord): boolean {
    const model = asStringValue(payload['model']).trim().toLowerCase();
    return model.startsWith('claude-') || model.startsWith('claude_') ||
      model.includes('/claude-') || model.includes('/claude_');
  }

  private digestValue(value: Object | string | number | boolean | null | JsonArray): string {
    return this.digestText(JSON.stringify(value));
  }

  private containsCacheControl(value: Object | string | number | boolean | null | JsonArray | undefined): boolean {
    if (value === undefined || value === null) {
      return false;
    }
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        const item: Object | string | number | boolean | null = value[index];
        if (this.containsCacheControl(item)) {
          return true;
        }
      }
      return false;
    }
    if (typeof value !== 'object') {
      return false;
    }
    const record = value as JsonRecord;
    if (record['cache_control'] !== undefined) {
      return true;
    }
    const keys = Object.keys(record);
    for (const key of keys) {
      if (this.containsCacheControl(record[key])) {
        return true;
      }
    }
    return false;
  }

  private digestText(value: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.update({ data: new util.TextEncoder().encodeInto(value) });
    const digest = md.digestSync();
    return this.hex(new Uint8Array(digest.data));
  }

  private hex(bytes: Uint8Array): string {
    const table = '0123456789abcdef';
    let out = '';
    for (let index = 0; index < bytes.length; index += 1) {
      const byte = bytes[index];
      out += table.charAt((byte >> 4) & 0x0f);
      out += table.charAt(byte & 0x0f);
    }
    return out;
  }
}
