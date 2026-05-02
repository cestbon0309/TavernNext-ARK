import { CryptoUtils } from './CryptoUtils';
import { UserDirectories } from './DataDirectories';
import { FileStore } from './FileStore';
import { emptyJsonRecord, HttpRequest, HttpResponse, JsonArray, JsonRecord } from './HttpTypes';
import { joinPath } from './PathUtils';

type JsonValue = Object | string | number | boolean | null | JsonArray;

class SecretValue {
  id: string = '';
  value: string = '';
  label: string = 'Unlabeled';
  active: boolean = true;
}

export class SecretsService {
  private static readonly fileName: string = 'secrets.json';
  private static readonly exportableKeys: string[] = ['libre_url', 'lingva_url', 'oneringtranslator_url', 'deeplx_url'];
  private readonly secretKeys: string[] = [
    'api_key_horde',
    'api_key_mancer',
    'api_key_vllm',
    'api_key_aphrodite',
    'api_key_tabby',
    'api_key_openai',
    'api_key_novel',
    'api_key_claude',
    'deepl',
    'libre',
    'libre_url',
    'lingva_url',
    'api_key_openrouter',
    'api_key_ai21',
    'oneringtranslator_url',
    'deeplx_url',
    'api_key_makersuite',
    'api_key_vertexai',
    'api_key_serpapi',
    'api_key_togetherai',
    'api_key_mistralai',
    'api_key_custom',
    'api_key_ooba',
    'api_key_infermaticai',
    'api_key_dreamgen',
    'api_key_nomicai',
    'api_key_koboldcpp',
    'api_key_llamacpp',
    'api_key_cohere',
    'api_key_perplexity',
    'api_key_groq',
    'api_key_azure_tts',
    'api_key_featherless',
    'api_key_huggingface',
    'api_key_stability',
    'api_key_custom_openai_tts',
    'api_key_tavily',
    'api_key_chutes',
    'api_key_electronhub',
    'api_key_nanogpt',
    'api_key_bfl',
    'api_key_comfy_runpod',
    'api_key_falai',
    'api_key_generic',
    'api_key_deepseek',
    'api_key_serper',
    'api_key_aimlapi',
    'api_key_xai',
    'api_key_fireworks',
    'vertexai_service_account_json',
    'api_key_minimax',
    'minimax_group_id',
    'api_key_moonshot',
    'api_key_cometapi',
    'api_key_azure_openai',
    'api_key_zai',
    'api_key_siliconflow',
    'api_key_elevenlabs',
    'api_key_pollinations',
    'volcengine_app_id',
    'volcengine_access_key',
  ];

  private store: FileStore;
  private dirs: UserDirectories;
  private crypto: CryptoUtils;
  private allowKeysExposure: boolean = false;

  constructor(store: FileStore, dirs: UserDirectories, crypto: CryptoUtils) {
    this.store = store;
    this.dirs = dirs;
    this.crypto = crypto;
  }

  settings(): HttpResponse {
    const response = emptyJsonRecord();
    response['allowKeysExposure'] = this.allowKeysExposure;
    return HttpResponse.json(response);
  }

  write(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const key = this.asString(body['key']);
    const value = this.asString(body['value']);
    const label = this.asString(body['label']) || 'Unlabeled';
    if (key.length === 0 || typeof body['value'] !== 'string') {
      return HttpResponse.text('Invalid key or value', 400);
    }

    const secrets = this.readSecrets();
    const values = this.secretArray(secrets[key]);
    for (const item of values) {
      item.active = false;
    }
    const secret = new SecretValue();
    secret.id = this.crypto.uuid();
    secret.value = value;
    secret.label = label;
    secret.active = true;
    values.push(secret);
    secrets[key] = values;
    this.writeSecrets(secrets);

    const response = emptyJsonRecord();
    response['id'] = secret.id;
    return HttpResponse.json(response);
  }

  read(): HttpResponse {
    return HttpResponse.json(this.getSecretState());
  }

  view(): HttpResponse {
    if (!this.allowKeysExposure) {
      return HttpResponse.empty(403);
    }
    const secrets = this.readSecrets();
    const response = emptyJsonRecord();
    Object.keys(secrets).forEach((key: string) => {
      if (key === '_migrated') {
        return;
      }
      const values = this.secretArray(secrets[key]);
      const active = this.findSecret(values, '');
      if (active !== null) {
        response[key] = active.value;
      }
    });
    return HttpResponse.json(response);
  }

  find(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const key = this.asString(body['key']);
    const id = this.asString(body['id']);
    if (key.length === 0) {
      return HttpResponse.text('Key is required', 400);
    }
    if (!this.allowKeysExposure && !SecretsService.exportableKeys.includes(key)) {
      return HttpResponse.empty(403);
    }

    const secrets = this.readSecrets();
    const values = this.secretArray(secrets[key]);
    if (values.length === 0) {
      return HttpResponse.empty(404);
    }

    const secret = this.findSecret(values, id);
    const response = emptyJsonRecord();
    response['value'] = secret === null ? '' : secret.value;
    return HttpResponse.json(response);
  }

  delete(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const key = this.asString(body['key']);
    const id = this.asString(body['id']);
    if (key.length === 0) {
      return HttpResponse.text('Key and ID are required', 400);
    }

    const secrets = this.readSecrets();
    const values = this.secretArray(secrets[key]);
    const target = values.findIndex((item: SecretValue): boolean => id.length > 0 ? item.id === id : item.active);
    if (target >= 0) {
      values.splice(target, 1);
    }
    if (values.length > 0 && !values.some((item: SecretValue): boolean => item.active)) {
      values[0].active = true;
    }
    if (values.length === 0) {
      this.writeSecrets(this.withoutSecretKey(secrets, key));
      return HttpResponse.empty(204);
    } else {
      secrets[key] = values;
    }
    this.writeSecrets(secrets);
    return HttpResponse.empty(204);
  }

  rotate(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const key = this.asString(body['key']);
    const id = this.asString(body['id']);
    if (key.length === 0 || id.length === 0) {
      return HttpResponse.text('Key and ID are required', 400);
    }

    const secrets = this.readSecrets();
    const values = this.secretArray(secrets[key]);
    for (const item of values) {
      item.active = item.id === id;
    }
    if (values.length > 0) {
      secrets[key] = values;
      this.writeSecrets(secrets);
    }
    return HttpResponse.empty(204);
  }

  rename(request: HttpRequest): HttpResponse {
    const body = this.bodyAsRecord(request);
    const key = this.asString(body['key']);
    const id = this.asString(body['id']);
    const label = this.asString(body['label']);
    if (key.length === 0 || id.length === 0 || label.length === 0) {
      return HttpResponse.text('Key, ID, and label are required', 400);
    }

    const secrets = this.readSecrets();
    const values = this.secretArray(secrets[key]);
    for (const item of values) {
      if (item.id === id) {
        item.label = label;
      }
    }
    if (values.length > 0) {
      secrets[key] = values;
      this.writeSecrets(secrets);
    }
    return HttpResponse.empty(204);
  }

  activeSecretValue(key: string): string {
    const values = this.secretArray(this.readSecrets()[key]);
    const secret = this.findSecret(values, '');
    return secret === null ? '' : secret.value;
  }

  private getSecretState(): JsonRecord {
    const secrets = this.readSecrets();
    const response = emptyJsonRecord();
    for (const key of this.secretKeys) {
      const values = this.secretArray(secrets[key]);
      if (values.length === 0) {
        response[key] = null;
        continue;
      }
      const states: JsonArray = [];
      for (const secret of values) {
        const item = emptyJsonRecord();
        item['id'] = secret.id;
        item['value'] = this.maskSecret(secret.value, key);
        item['label'] = secret.label;
        item['active'] = secret.active;
        states.push(item);
      }
      response[key] = states;
    }
    return response;
  }

  private readSecrets(): JsonRecord {
    const path = joinPath(this.dirs.root, SecretsService.fileName);
    if (!this.store.exists(path)) {
      this.store.writeJson(path, emptyJsonRecord());
      return emptyJsonRecord();
    }
    const raw = this.store.readJsonRecord(path);
    return this.migrateFlatSecretsIfNeeded(raw);
  }

  private writeSecrets(secrets: JsonRecord): void {
    this.store.writeJson(joinPath(this.dirs.root, SecretsService.fileName), secrets);
  }

  private migrateFlatSecretsIfNeeded(secrets: JsonRecord): JsonRecord {
    const values = Object.keys(secrets).map((key: string): JsonValue | JsonArray => secrets[key]);
    if (secrets['_migrated'] !== undefined || values.length === 0 || values.some((value: JsonValue | JsonArray): boolean =>
      Array.isArray(value))) {
      return secrets;
    }

    const migrated = emptyJsonRecord();
    Object.keys(secrets).forEach((key: string) => {
      const value = this.asString(secrets[key]);
      if (value.trim().length === 0) {
        return;
      }
      const secret = new SecretValue();
      secret.id = this.crypto.uuid();
      secret.value = value;
      secret.label = key;
      secret.active = true;
      migrated[key] = [secret];
    });
    migrated['_migrated'] = [];
    this.store.copyFile(joinPath(this.dirs.root, SecretsService.fileName),
      joinPath(this.dirs.backups, `secrets_migration_${Date.now()}.json`));
    this.writeSecrets(migrated);
    return migrated;
  }

  private secretArray(value: JsonValue | JsonArray | undefined): SecretValue[] {
    if (!Array.isArray(value)) {
      return [];
    }
    const values: SecretValue[] = [];
    for (let index = 0; index < value.length; index += 1) {
      const item: Object | string | number | boolean | null = value[index];
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      const secret = new SecretValue();
      secret.id = this.asString(record['id']);
      secret.value = this.asString(record['value']);
      secret.label = this.asString(record['label']) || 'Unlabeled';
      secret.active = record['active'] === true;
      values.push(secret);
    }
    return values;
  }

  private withoutSecretKey(secrets: JsonRecord, keyToRemove: string): JsonRecord {
    const keys = Object.keys(secrets);
    const next = emptyJsonRecord();
    for (const key of keys) {
      if (key !== keyToRemove) {
        next[key] = secrets[key];
      }
    }
    return next;
  }

  private findSecret(values: SecretValue[], id: string): SecretValue | null {
    for (const item of values) {
      if (id.length > 0 ? item.id === id : item.active) {
        return item;
      }
    }
    return null;
  }

  private maskSecret(value: string, key: string): string {
    if (this.allowKeysExposure || SecretsService.exportableKeys.includes(key)) {
      return value;
    }
    const threshold = 10;
    const exposedChars = 3;
    if (value.length <= threshold) {
      return '*'.repeat(threshold);
    }
    return `${'*'.repeat(threshold - exposedChars)}${value.slice(-exposedChars)}`;
  }

  private bodyAsRecord(request: HttpRequest): JsonRecord {
    if (request.body === null || Array.isArray(request.body)) {
      return emptyJsonRecord();
    }
    return request.body as JsonRecord;
  }

  private asString(value: JsonValue | JsonArray | undefined): string {
    if (value === undefined || value === null || Array.isArray(value)) {
      return '';
    }
    return `${value}`;
  }
}
