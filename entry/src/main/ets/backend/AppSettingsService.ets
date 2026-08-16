import { FileStore } from './FileStore';
import { JsonRecord } from './HttpTypes';
import { joinPath } from './PathUtils';

const SETTINGS_FILE = 'app-settings.json';

export const APP_SETTING_BACKGROUND_PRIVACY_ENABLED = 'backgroundPrivacyEnabled';
export const APP_SETTING_FORCE_HTTP1_1 = 'forceHttp1_1';
export const APP_SETTING_NOTIFY_ON_COMPLETED = 'notifyOnCompleted';
export const APP_SETTING_LLM_API_LOG_KEEP = 'llmApiLogKeep';
export const APP_SETTING_LLM_API_LOG_STREAM_ENABLED = 'llmApiLogStreamEnabled';
export const APP_SETTING_SHELL_BACKGROUND_COLOR = 'shellBackgroundColor';
export const APP_SETTING_CHAT_BROWSER_DARK_MODE = 'chatBrowserDarkMode';

const DEFAULT_BACKGROUND_PRIVACY_ENABLED = true;
const DEFAULT_FORCE_HTTP1_1 = true;
const DEFAULT_NOTIFY_ON_COMPLETED = false;
const DEFAULT_LLM_API_LOG_KEEP = 5;
const DEFAULT_LLM_API_LOG_STREAM_ENABLED = false;
const DEFAULT_SHELL_BACKGROUND_COLOR = '#171717';
const DEFAULT_CHAT_BROWSER_DARK_MODE = false;

export class AppSettingsService {
  private static instance: AppSettingsService | null = null;
  private store: FileStore = new FileStore();
  private path: string;
  private values: JsonRecord = {};

  private constructor(filesDir: string) {
    this.path = joinPath(filesDir, 'data', '_storage', SETTINGS_FILE);
    this.values = this.store.readJsonRecord(this.path);
    this.migrateLegacyValues(filesDir);
  }

  static getInstance(filesDir: string): AppSettingsService {
    if (AppSettingsService.instance === null) {
      AppSettingsService.instance = new AppSettingsService(filesDir);
    }
    return AppSettingsService.instance;
  }

  getBoolean(key: string, fallback: boolean): boolean {
    const value = this.values[key];
    return typeof value === 'boolean' ? value : fallback;
  }

  getNumber(key: string, fallback: number): number {
    const value = this.values[key];
    return typeof value === 'number' ? value : fallback;
  }

  getString(key: string, fallback: string): string {
    const value = this.values[key];
    return typeof value === 'string' ? value : fallback;
  }

  setBoolean(key: string, value: boolean): void {
    this.values[key] = value;
    this.save();
  }

  setNumber(key: string, value: number): void {
    this.values[key] = value;
    this.save();
  }

  setString(key: string, value: string): void {
    this.values[key] = value;
    this.save();
  }

  settingsJson(): JsonRecord {
    return this.values;
  }

  private migrateLegacyValues(filesDir: string): void {
    const storageRoot = joinPath(filesDir, 'data', '_storage');
    const llmApiLogRoot = joinPath(filesDir, 'data', '_cache', 'llm-api-logs');
    const shellThemePath = joinPath(filesDir, '_shell', 'shell-theme.json');
    const legacySettingsPath = joinPath(filesDir, 'data', 'default-user', 'settings.json');

    let changed = this.ensureBoolean(APP_SETTING_BACKGROUND_PRIVACY_ENABLED,
      this.legacyBoolean(joinPath(storageRoot, 'background-privacy.json'), 'enabled',
        DEFAULT_BACKGROUND_PRIVACY_ENABLED));
    changed = this.ensureBoolean(APP_SETTING_NOTIFY_ON_COMPLETED,
      this.legacyBoolean(joinPath(storageRoot, 'notification-preferences.json'), 'notifyOnCompleted',
        DEFAULT_NOTIFY_ON_COMPLETED)) || changed;
    changed = this.ensureNumber(APP_SETTING_LLM_API_LOG_KEEP,
      this.legacyNumber(joinPath(llmApiLogRoot, 'llm-api-settings.json'), 'keep',
        DEFAULT_LLM_API_LOG_KEEP)) || changed;
    changed = this.ensureBoolean(APP_SETTING_LLM_API_LOG_STREAM_ENABLED,
      this.legacyBoolean(joinPath(llmApiLogRoot, 'llm-api-settings.json'), 'streamEnabled',
        DEFAULT_LLM_API_LOG_STREAM_ENABLED)) || changed;
    changed = this.ensureString(APP_SETTING_SHELL_BACKGROUND_COLOR,
      this.legacyString(shellThemePath, 'backgroundColor', DEFAULT_SHELL_BACKGROUND_COLOR)) || changed;
    changed = this.ensureBoolean(APP_SETTING_CHAT_BROWSER_DARK_MODE,
      this.legacyBoolean(joinPath(storageRoot, 'chat-browser-settings.json'), 'darkMode',
        DEFAULT_CHAT_BROWSER_DARK_MODE)) || changed;
    changed = this.ensureBoolean(APP_SETTING_FORCE_HTTP1_1,
      this.legacyForceHttp1_1(legacySettingsPath)) || changed;

    if (changed) {
      this.save();
    }

    this.store.deleteFile(joinPath(storageRoot, 'background-privacy.json'));
    this.store.deleteFile(joinPath(storageRoot, 'notification-preferences.json'));
    this.store.deleteFile(joinPath(storageRoot, 'chat-browser-settings.json'));
    this.store.deleteFile(joinPath(llmApiLogRoot, 'llm-api-settings.json'));
    this.store.deleteFile(shellThemePath);
  }

  private legacyForceHttp1_1(settingsPath: string): boolean {
    const settings = this.store.readJsonRecord(settingsPath);
    const extensionSettings = settings['extension_settings'];
    if (extensionSettings !== null && typeof extensionSettings === 'object' && !Array.isArray(extensionSettings)) {
      const record = extensionSettings as JsonRecord;
      const value = record['ohosForceHttp1_1'];
      if (typeof value === 'boolean') {
        return value;
      }
    }
    return DEFAULT_FORCE_HTTP1_1;
  }

  private legacyBoolean(path: string, key: string, fallback: boolean): boolean {
    const record = this.store.readJsonRecord(path);
    const value = record[key];
    return typeof value === 'boolean' ? value : fallback;
  }

  private legacyNumber(path: string, key: string, fallback: number): number {
    const record = this.store.readJsonRecord(path);
    const value = record[key];
    return typeof value === 'number' ? value : fallback;
  }

  private legacyString(path: string, key: string, fallback: string): string {
    const record = this.store.readJsonRecord(path);
    const value = record[key];
    return typeof value === 'string' ? value : fallback;
  }

  private ensureBoolean(key: string, fallback: boolean): boolean {
    if (typeof this.values[key] === 'boolean') {
      return false;
    }
    this.values[key] = fallback;
    return true;
  }

  private ensureNumber(key: string, fallback: number): boolean {
    if (typeof this.values[key] === 'number') {
      return false;
    }
    this.values[key] = fallback;
    return true;
  }

  private ensureString(key: string, fallback: string): boolean {
    if (typeof this.values[key] === 'string') {
      return false;
    }
    this.values[key] = fallback;
    return true;
  }

  private save(): void {
    this.store.writeJson(this.path, this.values);
  }
}
