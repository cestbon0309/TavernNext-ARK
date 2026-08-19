import { resourceManager } from '@kit.LocalizationKit';
import { DataDirectories, UserDirectories } from './DataDirectories';
import { FileStore } from './FileStore';
import { JsonArray, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';

class ContentItem {
  filename: string = '';
  type: string = '';
}

type JsonValue = Object | string | number | boolean | null | JsonArray;

export class DefaultContentSeeder {
  private static readonly rawContentRoot: string = 'default/content';
  private store: FileStore;
  private dirs: DataDirectories;
  private manager: resourceManager.ResourceManager;

  constructor(store: FileStore, dirs: DataDirectories, manager: resourceManager.ResourceManager) {
    this.store = store;
    this.dirs = dirs;
    this.manager = manager;
  }

  seedDefaultUser(): void {
    const logPath = joinPath(this.dirs.defaultUser.root, 'content.log');
    const contentLog = this.readContentLog(logPath);

    try {
      const contentIndex = this.readContentIndex();
      if (contentIndex.length === 0) {
        return;
      }

      let modified = false;

      for (const item of contentIndex) {
        if (item.filename.length === 0 || item.type.length === 0) {
          continue;
        }
        if (contentLog.includes(item.filename)) {
          continue;
        }
        const targetRoot = this.targetByType(item.type, this.dirs.defaultUser);
        if (targetRoot.length === 0 || !this.validRelativePath(item.filename)) {
          contentLog.push(item.filename);
          modified = true;
          continue;
        }

        const targetPath = joinPath(targetRoot, this.baseName(item.filename));
        if (this.store.exists(targetPath)) {
          contentLog.push(item.filename);
          modified = true;
          continue;
        }

        if (!this.copyRawContent(item.filename, targetPath) || !this.store.exists(targetPath)) {
          continue;
        }
        contentLog.push(item.filename);
        modified = true;
      }

      if (modified) {
        this.store.writeText(logPath, contentLog.join('\n'));
      }
    } catch (_err) {
    }
  }

  private readContentIndex(): ContentItem[] {
    try {
      const bytes = this.manager.getRawFileContentSync(`${DefaultContentSeeder.rawContentRoot}/index.json`);
      const text = this.utf8(bytes);
      const parsed = JSON.parse(text) as JsonArray;
      const result: ContentItem[] = [];
      for (const value of parsed) {
        const record = this.asRecord(value);
        const item = new ContentItem();
        item.filename = this.asString(record['filename']);
        item.type = this.asString(record['type']);
        result.push(item);
      }
      return result;
    } catch (_err) {
      return [];
    }
  }

  private readContentLog(path: string): string[] {
    const text = this.store.readText(path, '');
    if (text.length === 0) {
      return [];
    }
    return text.split('\n').filter((line: string): boolean => line.length > 0);
  }

  private copyRawContent(relativePath: string, targetPath: string): boolean {
    const rawPath = `${DefaultContentSeeder.rawContentRoot}/${relativePath.replace(/\\/g, '/')}`;
    try {
      this.manager.getRawFileListSync(rawPath);
      const copied = this.copyRawDirectory(rawPath, targetPath);
      if (!copied) {
        this.store.deleteDirectory(targetPath);
      }
      return copied;
    } catch (_dirErr) {
      try {
        const bytes = this.manager.getRawFileContentSync(rawPath);
        this.store.writeBytes(targetPath, bytes);
        const written = this.store.readBytes(targetPath);
        const copied = written !== null && written.byteLength === bytes.byteLength;
        if (!copied) {
          this.store.deleteFile(targetPath);
        }
        return copied;
      } catch (_fileErr) {
        this.store.deleteFile(targetPath);
        return false;
      }
    }
  }

  private copyRawDirectory(rawPath: string, targetPath: string): boolean {
    this.store.ensureDir(targetPath);
    if (!this.store.exists(targetPath)) {
      return false;
    }
    let names: string[] = [];
    try {
      names = this.manager.getRawFileListSync(rawPath);
    } catch (_err) {
      return false;
    }
    for (const name of names) {
      const safeName = sanitizeFileName(name);
      if (safeName.length === 0 || safeName === 'unnamed') {
        continue;
      }
      const childRaw = `${rawPath}/${name}`;
      const childTarget = joinPath(targetPath, safeName);
      try {
        this.manager.getRawFileListSync(childRaw);
        if (!this.copyRawDirectory(childRaw, childTarget)) {
          return false;
        }
      } catch (_dirErr) {
        try {
          const bytes = this.manager.getRawFileContentSync(childRaw);
          this.store.writeBytes(childTarget, bytes);
          const written = this.store.readBytes(childTarget);
          if (written === null || written.byteLength !== bytes.byteLength) {
            return false;
          }
        } catch (_fileErr) {
          return false;
        }
      }
    }
    return true;
  }

  private targetByType(type: string, dirs: UserDirectories): string {
    switch (type) {
      case 'settings':
        return dirs.root;
      case 'character':
      case 'sprites':
        return dirs.characters;
      case 'background':
        return dirs.backgrounds;
      case 'world':
        return dirs.worlds;
      case 'avatar':
        return dirs.avatars;
      case 'theme':
        return dirs.themes;
      case 'workflow':
        return dirs.comfyWorkflows;
      case 'kobold_preset':
        return dirs.koboldAISettings;
      case 'openai_preset':
        return dirs.openAISettings;
      case 'novel_preset':
        return dirs.novelAISettings;
      case 'textgen_preset':
        return dirs.textGenSettings;
      case 'instruct':
        return dirs.instruct;
      case 'context':
        return dirs.context;
      case 'moving_ui':
        return dirs.movingUI;
      case 'quick_replies':
        return dirs.quickreplies;
      case 'sysprompt':
        return dirs.sysprompt;
      case 'reasoning':
        return dirs.reasoning;
      default:
        return '';
    }
  }

  private validRelativePath(path: string): boolean {
    if (path.length === 0 || path.includes('\u0000')) {
      return false;
    }
    const normalized = path.replace(/\\/g, '/');
    return !normalized.split('/').some((segment: string): boolean => segment.length === 0 || segment === '.' ||
      segment === '..');
  }

  private baseName(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const slash = normalized.lastIndexOf('/');
    return slash >= 0 ? sanitizeFileName(normalized.slice(slash + 1)) : sanitizeFileName(normalized);
  }

  private utf8(bytes: Uint8Array): string {
    let text = '';
    for (let index = 0; index < bytes.byteLength; index += 1) {
      text += String.fromCharCode(bytes[index]);
    }
    return decodeURIComponent(escape(text));
  }

  private asString(value: JsonValue | JsonArray | undefined): string {
    if (value === undefined || value === null || Array.isArray(value)) {
      return '';
    }
    return `${value}`;
  }

  private asRecord(value: JsonValue | JsonArray | undefined): JsonRecord {
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
      const record: JsonRecord = {};
      return record;
    }
    return value as JsonRecord;
  }
}
