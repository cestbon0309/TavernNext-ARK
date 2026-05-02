import { DataDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { SecretsService } from './SecretsService';
import { HttpRequest, HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from './HttpTypes';
import { RemoteHttpClient } from './RemoteHttpClient';
import { asArray, asNumber, asString, bodyAsRecord, parseJsonRecord } from './JsonUtils';
import { joinPath, sanitizeFileName } from './PathUtils';

class VectorItem {
  id: string = '';
  vector: number[] = [];
  metadata: JsonRecord = emptyJsonRecord();
}

class VectorIndexFile {
  items: VectorItem[] = [];
}

export class VectorService {
  private store: FileStore;
  private dirs: DataDirectories;
  private secrets: SecretsService;
  private http: RemoteHttpClient = new RemoteHttpClient();

  constructor(store: FileStore, dirs: DataDirectories, secrets: SecretsService) {
    this.store = store;
    this.dirs = dirs;
    this.secrets = secrets;
  }

  async insert(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const collectionId = sanitizeFileName(asString(body['collectionId']));
    const items = asArray(body['items']);
    if (collectionId.length === 0 || items.length === 0) {
      return HttpResponse.empty(400);
    }
    const source = asString(body['source']) || 'transformers';
    const index = this.readIndex(collectionId, source, body);
    const texts: string[] = [];
    const incoming: JsonRecord[] = [];
    for (const item of items) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      incoming.push(record);
      texts.push(asString(record['text']));
    }
    const vectors = await this.getBatchVectors(source, body, texts, false);
    for (let indexNumber = 0; indexNumber < incoming.length; indexNumber += 1) {
      const record = incoming[indexNumber];
      const hash = asNumber(record['hash']);
      const metadata = emptyJsonRecord();
      metadata['hash'] = hash;
      metadata['text'] = asString(record['text']);
      metadata['index'] = asNumber(record['index'], indexNumber);
      this.upsert(index.items, `${hash}`, vectors[indexNumber], metadata);
    }
    this.writeIndex(collectionId, source, body, index);
    return HttpResponse.empty(200);
  }

  list(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const collectionId = sanitizeFileName(asString(body['collectionId']));
    if (collectionId.length === 0) {
      return HttpResponse.empty(400);
    }
    const index = this.readIndex(collectionId, asString(body['source']) || 'transformers', body);
    const hashes: number[] = [];
    for (const item of index.items) {
      hashes.push(asNumber(item.metadata['hash']));
    }
    return HttpResponse.json(hashes);
  }

  delete(request: HttpRequest): HttpResponse {
    const body = bodyAsRecord(request);
    const collectionId = sanitizeFileName(asString(body['collectionId']));
    const hashes = asArray(body['hashes']);
    if (collectionId.length === 0 || hashes.length === 0) {
      return HttpResponse.empty(400);
    }
    const source = asString(body['source']) || 'transformers';
    const index = this.readIndex(collectionId, source, body);
    const hashSet = new Set<number>();
    for (const hash of hashes) {
      hashSet.add(Number(hash));
    }
    index.items = index.items.filter((item: VectorItem): boolean => !hashSet.has(asNumber(item.metadata['hash'])));
    this.writeIndex(collectionId, source, body, index);
    return HttpResponse.empty(200);
  }

  async query(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const collectionId = sanitizeFileName(asString(body['collectionId']));
    const searchText = asString(body['searchText']);
    if (collectionId.length === 0 || searchText.length === 0) {
      return HttpResponse.empty(400);
    }
    const source = asString(body['source']) || 'transformers';
    const topK = asNumber(body['topK'], 10);
    const threshold = asNumber(body['threshold'], 0);
    const vector = await this.getVector(source, body, searchText, true);
    const index = this.readIndex(collectionId, source, body);
    return HttpResponse.json(this.queryItems(index.items, vector, topK, threshold));
  }

  async queryMulti(request: HttpRequest): Promise<HttpResponse> {
    const body = bodyAsRecord(request);
    const collectionIds = asArray(body['collectionIds']);
    const searchText = asString(body['searchText']);
    if (collectionIds.length === 0 || searchText.length === 0) {
      return HttpResponse.empty(400);
    }
    const source = asString(body['source']) || 'transformers';
    const topK = asNumber(body['topK'], 10);
    const threshold = asNumber(body['threshold'], 0);
    const vector = await this.getVector(source, body, searchText, true);
    const scored: MultiScore[] = [];
    for (const collection of collectionIds) {
      const collectionId = sanitizeFileName(asString(collection));
      const index = this.readIndex(collectionId, source, body);
      const local = this.scoredItems(index.items, vector, topK, threshold);
      for (const item of local) {
        const next = new MultiScore();
        next.collectionId = collectionId;
        next.score = item.score;
        next.item = item.item;
        scored.push(next);
      }
    }
    scored.sort((a: MultiScore, b: MultiScore): number => b.score - a.score);
    const response = emptyJsonRecord();
    for (const entry of scored.slice(0, topK)) {
      let grouped = response[entry.collectionId] as JsonRecord | undefined;
      if (grouped === undefined || grouped === null || Array.isArray(grouped) || typeof grouped !== 'object') {
        grouped = emptyJsonRecord();
        grouped['hashes'] = [];
        grouped['metadata'] = [];
        response[entry.collectionId] = grouped;
      }
      (grouped['hashes'] as JsonArray).push(asNumber(entry.item.metadata['hash']));
      (grouped['metadata'] as JsonArray).push(entry.item.metadata);
    }
    return HttpResponse.json(response);
  }

  purge(request: HttpRequest): HttpResponse {
    const collectionId = sanitizeFileName(asString(bodyAsRecord(request)['collectionId']));
    if (collectionId.length === 0) {
      return HttpResponse.empty(400);
    }
    for (const source of this.store.list(this.dirs.defaultUser.vectors)) {
      const path = joinPath(source.path, collectionId);
      if (this.store.exists(path)) {
        this.store.deleteDirectory(path);
      }
    }
    return HttpResponse.empty(200);
  }

  purgeAll(): HttpResponse {
    this.store.deleteDirectory(this.dirs.defaultUser.vectors);
    this.store.ensureDir(this.dirs.defaultUser.vectors);
    return HttpResponse.empty(200);
  }

  private async getBatchVectors(source: string, settings: JsonRecord, texts: string[], isQuery: boolean): Promise<number[][]> {
    const output: number[][] = [];
    for (const text of texts) {
      output.push(await this.getVector(source, settings, text, isQuery));
    }
    return output;
  }

  private async getVector(source: string, settings: JsonRecord, text: string, isQuery: boolean): Promise<number[]> {
    if (source === 'webllm' || source === 'koboldcpp') {
      const embeddings = settings['embeddings'];
      if (embeddings !== null && embeddings !== undefined && !Array.isArray(embeddings) && typeof embeddings === 'object') {
        const record = embeddings as JsonRecord;
        const vector = record[text];
        if (Array.isArray(vector)) {
          return this.numbers(vector);
        }
      }
    }
    if (source === 'transformers') {
      return this.hashVector(text);
    }
    return this.remoteVector(source, settings, text, isQuery);
  }

  private async remoteVector(source: string, settings: JsonRecord, text: string, isQuery: boolean): Promise<number[]> {
    const endpoint = this.embeddingEndpoint(source, settings, isQuery);
    if (endpoint.url.length === 0) {
      return this.hashVector(text);
    }
    const request = emptyJsonRecord();
    request['input'] = text;
    request['model'] = endpoint.model;
    try {
      const result = await this.http.postJson(endpoint.url, request, endpoint.headers, 120000);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return this.hashVector(text);
      }
      const data = parseJsonRecord(result.text);
      const vector = this.extractEmbedding(data);
      return vector.length > 0 ? vector : this.hashVector(text);
    } catch (_err) {
      return this.hashVector(text);
    }
  }

  private embeddingEndpoint(source: string, settings: JsonRecord, isQuery: boolean): EmbeddingEndpoint {
    const endpoint = new EmbeddingEndpoint();
    endpoint.model = asString(settings['model']) || 'text-embedding-3-small';
    endpoint.headers['Content-Type'] = 'application/json';
    switch (source) {
      case 'openai':
      case 'togetherai':
      case 'mistral':
      case 'chutes':
      case 'nanogpt':
      case 'siliconflow':
      case 'openrouter':
      case 'electronhub':
        endpoint.url = this.http.joinUrl(this.embeddingBase(source, settings), '/embeddings');
        endpoint.headers['Authorization'] = `Bearer ${this.embeddingKey(source)}`;
        break;
      case 'llamacpp':
      case 'vllm':
        endpoint.url = this.http.joinUrl(asString(settings['apiUrl']), '/v1/embeddings');
        break;
      case 'ollama':
        endpoint.url = this.http.joinUrl(asString(settings['apiUrl']), '/api/embeddings');
        break;
      case 'extras':
        endpoint.url = this.http.joinUrl(asString(settings['extrasUrl']), '/api/embeddings/compute');
        if (asString(settings['extrasKey']).length > 0) {
          endpoint.headers['Authorization'] = `Bearer ${asString(settings['extrasKey'])}`;
        }
        break;
      case 'cohere':
        endpoint.url = 'https://api.cohere.ai/v1/embed';
        endpoint.headers['Authorization'] = `Bearer ${this.secrets.activeSecretValue('api_key_cohere')}`;
        endpoint.headers['input_type'] = isQuery ? 'search_query' : 'search_document';
        break;
      default:
        endpoint.url = '';
        break;
    }
    return endpoint;
  }

  private embeddingBase(source: string, settings: JsonRecord): string {
    if (source === 'openrouter') {
      return 'https://openrouter.ai/api/v1';
    }
    if (source === 'electronhub') {
      return 'https://api.electronhub.ai/v1';
    }
    if (source === 'nanogpt') {
      return 'https://nano-gpt.com/api/v1';
    }
    if (source === 'siliconflow') {
      return asString(settings['urlOverride']) || 'https://api.siliconflow.com/v1';
    }
    if (source === 'chutes') {
      return 'https://llm.chutes.ai/v1';
    }
    if (source === 'mistral') {
      return 'https://api.mistral.ai/v1';
    }
    if (source === 'togetherai') {
      return 'https://api.together.xyz/v1';
    }
    return 'https://api.openai.com/v1';
  }

  private embeddingKey(source: string): string {
    switch (source) {
      case 'openrouter':
        return this.secrets.activeSecretValue('api_key_openrouter');
      case 'electronhub':
        return this.secrets.activeSecretValue('api_key_electronhub');
      case 'nanogpt':
        return this.secrets.activeSecretValue('api_key_nanogpt');
      case 'siliconflow':
        return this.secrets.activeSecretValue('api_key_siliconflow');
      case 'chutes':
        return this.secrets.activeSecretValue('api_key_chutes');
      case 'mistral':
        return this.secrets.activeSecretValue('api_key_mistralai');
      case 'togetherai':
        return this.secrets.activeSecretValue('api_key_openai');
      default:
        return this.secrets.activeSecretValue('api_key_openai');
    }
  }

  private extractEmbedding(data: JsonRecord): number[] {
    const rows = data['data'];
    if (Array.isArray(rows) && rows.length > 0) {
      const values = rows as JsonArray;
      const first = values[0];
      if (first !== null && !Array.isArray(first) && typeof first === 'object') {
        const embedding = (first as JsonRecord)['embedding'];
        if (Array.isArray(embedding)) {
          return this.numbers(embedding);
        }
      }
    }
    const embedding = data['embedding'];
    if (Array.isArray(embedding)) {
      return this.numbers(embedding);
    }
    return [];
  }

  private indexPath(collectionId: string, source: string, settings: JsonRecord): string {
    const model = sanitizeFileName(asString(settings['model']));
    return joinPath(this.dirs.defaultUser.vectors, sanitizeFileName(source), sanitizeFileName(collectionId),
      model.length > 0 ? model : '_default', 'index.json');
  }

  private readIndex(collectionId: string, source: string, settings: JsonRecord): VectorIndexFile {
    const path = this.indexPath(collectionId, source, settings);
    const value = this.store.readJsonRecord(path);
    const file = new VectorIndexFile();
    const items = value['items'];
    if (!Array.isArray(items)) {
      return file;
    }
    for (const item of items as JsonArray) {
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      const vectorItem = new VectorItem();
      vectorItem.id = asString(record['id']);
      vectorItem.vector = this.numbers(asArray(record['vector']));
      const metadata = record['metadata'];
      if (metadata !== null && metadata !== undefined && !Array.isArray(metadata) && typeof metadata === 'object') {
        vectorItem.metadata = metadata as JsonRecord;
      }
      file.items.push(vectorItem);
    }
    return file;
  }

  private writeIndex(collectionId: string, source: string, settings: JsonRecord, index: VectorIndexFile): void {
    const record = emptyJsonRecord();
    record['items'] = index.items;
    this.store.writeJson(this.indexPath(collectionId, source, settings), record);
  }

  private upsert(items: VectorItem[], id: string, vector: number[], metadata: JsonRecord): void {
    const existing = items.findIndex((item: VectorItem): boolean => item.id === id);
    const next = new VectorItem();
    next.id = id;
    next.vector = vector;
    next.metadata = metadata;
    if (existing >= 0) {
      items[existing] = next;
    } else {
      items.push(next);
    }
  }

  private queryItems(items: VectorItem[], vector: number[], topK: number, threshold: number): JsonRecord {
    const scored = this.scoredItems(items, vector, topK, threshold);
    const response = emptyJsonRecord();
    const hashes: JsonArray = [];
    const metadata: JsonArray = [];
    for (const item of scored) {
      hashes.push(asNumber(item.item.metadata['hash']));
      metadata.push(item.item.metadata);
    }
    response['hashes'] = hashes;
    response['metadata'] = metadata;
    return response;
  }

  private scoredItems(items: VectorItem[], vector: number[], topK: number, threshold: number): ScoredItem[] {
    const scored: ScoredItem[] = [];
    for (const item of items) {
      const score = this.cosineSimilarity(vector, item.vector);
      if (score < threshold) {
        continue;
      }
      const next = new ScoredItem();
      next.score = score;
      next.item = item;
      scored.push(next);
    }
    scored.sort((a: ScoredItem, b: ScoredItem): number => b.score - a.score);
    return scored.slice(0, topK);
  }

  private cosineSimilarity(left: number[], right: number[]): number {
    const length = Math.min(left.length, right.length);
    if (length === 0) {
      return 0;
    }
    let dot = 0;
    let leftNorm = 0;
    let rightNorm = 0;
    for (let index = 0; index < length; index += 1) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm === 0 || rightNorm === 0) {
      return 0;
    }
    return dot / (Math.sqrt(leftNorm) * Math.sqrt(rightNorm));
  }

  private hashVector(text: string): number[] {
    const vector = new Array<number>(384).fill(0);
    const words = text.toLowerCase().split(/[^a-z0-9\u4e00-\u9fff]+/).filter((item: string): boolean => item.length > 0);
    for (const word of words) {
      const hash = this.hash(word);
      const slot = Math.abs(hash) % vector.length;
      vector[slot] += hash >= 0 ? 1 : -1;
    }
    return vector;
  }

  private hash(text: string): number {
    let value = 2166136261;
    for (let index = 0; index < text.length; index += 1) {
      value ^= text.charCodeAt(index);
      value = Math.imul(value, 16777619);
    }
    return value;
  }

  private numbers(values: JsonArray): number[] {
    const output: number[] = [];
    for (const value of values) {
      const number = Number(value);
      if (Number.isFinite(number)) {
        output.push(number);
      }
    }
    return output;
  }
}

class EmbeddingEndpoint {
  url: string = '';
  model: string = 'text-embedding-3-small';
  headers: Record<string, string> = {};
}

class ScoredItem {
  score: number = 0;
  item: VectorItem = new VectorItem();
}

class MultiScore extends ScoredItem {
  collectionId: string = '';
}
