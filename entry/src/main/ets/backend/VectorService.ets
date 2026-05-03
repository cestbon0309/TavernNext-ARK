import { DataDirectories } from './DataDirectories';
import { FileEntry, FileStore } from './FileStore';
import { SecretsService } from './SecretsService';
import { HttpRequest, HttpResponse, JsonArray, JsonRecord, emptyJsonRecord } from './HttpTypes';
import { RemoteHttpClient } from './RemoteHttpClient';
import { asArray, asNumber, asRecord, asString, bodyAsRecord, parseJsonRecord } from './JsonUtils';
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
    if (texts.length === 0) {
      return [];
    }
    if (source === 'webllm' || source === 'koboldcpp') {
      const output: number[][] = [];
      const embeddings = settings['embeddings'];
      const records = embeddings !== null && embeddings !== undefined && !Array.isArray(embeddings) &&
        typeof embeddings === 'object' ? embeddings as JsonRecord : emptyJsonRecord();
      for (const text of texts) {
        const vector = records[text];
        output.push(Array.isArray(vector) ? this.numbers(vector) : this.hashVector(text));
      }
      return output;
    }
    if (source === 'transformers') {
      return texts.map((text: string): number[] => this.hashVector(text));
    }
    const endpoint = this.embeddingEndpoint(source, settings, isQuery);
    if (endpoint.url.length === 0) {
      return texts.map((text: string): number[] => this.hashVector(text));
    }
    const output: number[][] = [];
    const batchSize = 10;
    for (let index = 0; index < texts.length; index += batchSize) {
      const batch = texts.slice(index, index + batchSize);
      const vectors = await this.remoteBatchVectors(source, endpoint, batch, isQuery);
      for (let itemIndex = 0; itemIndex < batch.length; itemIndex += 1) {
        const vector = itemIndex < vectors.length ? vectors[itemIndex] : [];
        output.push(vector.length > 0 ? vector : this.hashVector(batch[itemIndex]));
      }
    }
    return output;
  }

  private async getVector(source: string, settings: JsonRecord, text: string, isQuery: boolean): Promise<number[]> {
    const vectors = await this.getBatchVectors(source, settings, [text], isQuery);
    return vectors.length > 0 ? vectors[0] : this.hashVector(text);
  }

  private async remoteBatchVectors(source: string, endpoint: EmbeddingEndpoint, texts: string[],
    isQuery: boolean): Promise<number[][]> {
    const request = this.embeddingRequest(source, endpoint, texts, isQuery);
    try {
      const result = await this.http.postJson(endpoint.url, request, endpoint.headers, 120000);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        return [];
      }
      const data = parseJsonRecord(result.text);
      return this.extractEmbeddings(source, data);
    } catch (_err) {
      return [];
    }
  }

  private embeddingEndpoint(source: string, settings: JsonRecord, isQuery: boolean): EmbeddingEndpoint {
    const endpoint = new EmbeddingEndpoint();
    endpoint.model = this.embeddingModel(source, settings);
    endpoint.headers['Content-Type'] = 'application/json';
    switch (source) {
      case 'nomicai':
        endpoint.url = 'https://api-atlas.nomic.ai/v1/embedding/text';
        endpoint.headers['Authorization'] = `Bearer ${this.secrets.activeSecretValue('api_key_nomicai')}`;
        break;
      case 'openai':
      case 'togetherai':
      case 'mistral':
      case 'nanogpt':
      case 'siliconflow':
      case 'openrouter':
      case 'electronhub':
        endpoint.url = this.http.joinUrl(this.embeddingBase(source, settings), '/embeddings');
        endpoint.headers['Authorization'] = `Bearer ${this.embeddingKey(source)}`;
        break;
      case 'chutes':
        endpoint.url = this.http.joinUrl(`https://${endpoint.model}.chutes.ai/v1`, '/embeddings');
        endpoint.headers['Authorization'] = `Bearer ${this.embeddingKey(source)}`;
        break;
      case 'llamacpp':
      case 'vllm':
        endpoint.url = this.http.joinUrl(this.trimV1(asString(settings['apiUrl'])), '/v1/embeddings');
        break;
      case 'ollama':
        endpoint.url = this.http.joinUrl(asString(settings['apiUrl']), '/api/embed');
        break;
      case 'extras':
        endpoint.url = this.http.joinUrl(asString(settings['extrasUrl']), '/api/embeddings/compute');
        if (asString(settings['extrasKey']).length > 0) {
          endpoint.headers['Authorization'] = `Bearer ${asString(settings['extrasKey'])}`;
        }
        break;
      case 'palm':
      case 'makersuite':
        endpoint.url = this.withGoogleKey(this.http.joinUrl('https://generativelanguage.googleapis.com',
          `/v1beta/models/${endpoint.model}:batchEmbedContents`), this.secrets.activeSecretValue('api_key_makersuite'));
        break;
      case 'vertexai':
        endpoint.url = this.http.joinUrl(this.vertexBase(settings), `/publishers/google/models/${endpoint.model}:predict`);
        const vertexKey = this.secrets.activeSecretValue('api_key_vertexai');
        if (vertexKey.length > 0) {
          endpoint.url = this.withGoogleKey(endpoint.url, vertexKey);
        }
        break;
      case 'cohere':
        endpoint.url = 'https://api.cohere.ai/v2/embed';
        endpoint.headers['Authorization'] = `Bearer ${this.secrets.activeSecretValue('api_key_cohere')}`;
        break;
      default:
        endpoint.url = '';
        break;
    }
    return endpoint;
  }

  private embeddingRequest(source: string, endpoint: EmbeddingEndpoint, texts: string[], isQuery: boolean): JsonRecord {
    const request = emptyJsonRecord();
    switch (source) {
      case 'extras':
        request['text'] = texts.length === 1 ? texts[0] : texts;
        return request;
      case 'cohere':
        request['texts'] = texts;
        request['model'] = endpoint.model;
        request['embedding_types'] = ['float'];
        request['input_type'] = isQuery ? 'search_query' : 'search_document';
        request['truncate'] = 'END';
        return request;
      case 'ollama':
        request['input'] = texts;
        request['model'] = endpoint.model;
        request['truncate'] = true;
        return request;
      case 'nomicai':
        request['texts'] = texts;
        request['model'] = endpoint.model;
        return request;
      case 'palm':
      case 'makersuite':
        const googleRequests: JsonArray = [];
        for (const text of texts) {
          const content = emptyJsonRecord();
          content['parts'] = [this.textPart(text)];
          const row = emptyJsonRecord();
          row['model'] = `models/${endpoint.model}`;
          row['content'] = content;
          googleRequests.push(row);
        }
        request['requests'] = googleRequests;
        return request;
      case 'vertexai':
        const instances: JsonArray = [];
        for (const text of texts) {
          const row = emptyJsonRecord();
          row['content'] = text;
          instances.push(row);
        }
        request['instances'] = instances;
        return request;
      case 'llamacpp':
        request['input'] = texts;
        return request;
      case 'chutes':
        request['input'] = texts;
        request['model'] = null;
        return request;
      default:
        request['input'] = texts;
        request['model'] = endpoint.model;
        return request;
    }
  }

  private textPart(text: string): JsonRecord {
    const part = emptyJsonRecord();
    part['text'] = text;
    return part;
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

  private embeddingModel(source: string, settings: JsonRecord): string {
    const model = asString(settings['model']);
    if (model.length > 0) {
      return model;
    }
    switch (source) {
      case 'openai':
        return 'text-embedding-ada-002';
      case 'togetherai':
        return 'togethercomputer/m2-bert-80M-32k-retrieval';
      case 'mistral':
        return 'mistral-embed';
      case 'openrouter':
        return 'openai/text-embedding-3-large';
      case 'electronhub':
      case 'nanogpt':
        return 'text-embedding-3-small';
      case 'chutes':
        return 'chutes-qwen-qwen3-embedding-8b';
      case 'siliconflow':
        return 'Qwen/Qwen3-Embedding-0.6B';
      case 'nomicai':
        return 'nomic-embed-text-v1.5';
      case 'palm':
      case 'makersuite':
      case 'vertexai':
        return 'text-embedding-005';
      default:
        return 'text-embedding-3-small';
    }
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
        return this.secrets.activeSecretValue('api_key_togetherai');
      default:
        return this.secrets.activeSecretValue('api_key_openai');
    }
  }

  private extractEmbeddings(source: string, data: JsonRecord): number[][] {
    if (source === 'extras') {
      const embedding = data['embedding'];
      if (Array.isArray(embedding)) {
        const values: JsonArray = embedding;
        if (values.length > 0 && Array.isArray(values[0])) {
          const rows: number[][] = [];
          for (let index = 0; index < values.length; index += 1) {
            const row: Object | string | number | boolean | null = values[index];
            if (Array.isArray(row)) {
              rows.push(this.numbers(row));
            }
          }
          return rows;
        }
        return [this.numbers(values)];
      }
    }
    if (source === 'cohere') {
      const embeddings = asRecord(data['embeddings']);
      const rows = embeddings['float'];
      if (Array.isArray(rows)) {
        return this.numberRows(rows);
      }
    }
    if (source === 'ollama' || source === 'nomicai') {
      const rows = data['embeddings'];
      if (Array.isArray(rows)) {
        return this.numberRows(rows);
      }
    }
    if (source === 'palm' || source === 'makersuite') {
      const rows = data['embeddings'];
      if (Array.isArray(rows)) {
        const output: number[][] = [];
        for (const row of rows as JsonArray) {
          if (row !== null && !Array.isArray(row) && typeof row === 'object') {
            output.push(this.numbers(asArray((row as JsonRecord)['values'])));
          }
        }
        return output;
      }
    }
    if (source === 'vertexai') {
      const rows = data['predictions'];
      if (Array.isArray(rows)) {
        const output: number[][] = [];
        for (const row of rows as JsonArray) {
          if (row !== null && !Array.isArray(row) && typeof row === 'object') {
            const embeddings = asRecord((row as JsonRecord)['embeddings']);
            output.push(this.numbers(asArray(embeddings['values'])));
          }
        }
        return output;
      }
    }
    const rows = data['data'];
    if (Array.isArray(rows) && rows.length > 0) {
      const values = rows as JsonArray;
      const records: JsonRecord[] = [];
      for (const value of values) {
        if (value !== null && !Array.isArray(value) && typeof value === 'object') {
          records.push(value as JsonRecord);
        }
      }
      records.sort((left: JsonRecord, right: JsonRecord): number => asNumber(left['index']) - asNumber(right['index']));
      const output: number[][] = [];
      for (const record of records) {
        output.push(this.numbers(asArray(record['embedding'])));
      }
      return output;
    }
    const embedding = data['embedding'];
    if (Array.isArray(embedding)) {
      return [this.numbers(embedding)];
    }
    return [];
  }

  private numberRows(rows: JsonArray): number[][] {
    const output: number[][] = [];
    for (const row of rows) {
      if (Array.isArray(row)) {
        output.push(this.numbers(row));
      }
    }
    return output;
  }

  private trimV1(value: string): string {
    const trimmed = this.http.normalizeBaseUrl(value);
    return trimmed.endsWith('/v1') ? trimmed.slice(0, trimmed.length - 3) : trimmed;
  }

  private withGoogleKey(url: string, key: string): string {
    if (key.length === 0) {
      return url;
    }
    return url.includes('?') ? `${url}&key=${encodeURIComponent(key)}` : `${url}?key=${encodeURIComponent(key)}`;
  }

  private vertexBase(settings: JsonRecord): string {
    const region = asString(settings['vertexai_region']) || asString(settings['region']) || 'us-central1';
    const projectId = asString(settings['vertexai_express_project_id']) || asString(settings['projectId']);
    if (projectId.length === 0) {
      return region === 'global' ? 'https://aiplatform.googleapis.com/v1' :
        `https://${region}-aiplatform.googleapis.com/v1`;
    }
    const host = region === 'global' ? 'https://aiplatform.googleapis.com' :
      `https://${region}-aiplatform.googleapis.com`;
    return `${host}/v1/projects/${projectId}/locations/${region}`;
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
