import { fileIo } from '@kit.CoreFileKit';
import { emptyJsonRecord, JsonRecord } from './HttpTypes';
import { extensionOf, joinPath } from './PathUtils';

export class FileEntry {
  name: string;
  path: string;
  isFile: boolean;
  isDirectory: boolean;
  size: number;
  mtimeMs: number;
  ctimeMs: number;

  constructor(name: string, path: string, isFile: boolean, isDirectory: boolean, size: number, mtimeMs: number,
    ctimeMs: number) {
    this.name = name;
    this.path = path;
    this.isFile = isFile;
    this.isDirectory = isDirectory;
    this.size = size;
    this.mtimeMs = mtimeMs;
    this.ctimeMs = ctimeMs;
  }
}

export class FileStore {
  exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_err) {
      return false;
    }
  }

  ensureDir(path: string): void {
    if (this.exists(path)) {
      return;
    }
    try {
      fileIo.mkdirSync(path, true);
    } catch (_err) {
    }
  }

  ensureParentDir(path: string): void {
    const normalized = path.replace(/\\/g, '/');
    const lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) {
      return;
    }
    this.ensureDir(normalized.slice(0, lastSlash));
  }

  readText(path: string, fallback: string = ''): string {
    if (!this.exists(path)) {
      return fallback;
    }
    try {
      return fileIo.readTextSync(path, { encoding: 'utf-8' });
    } catch (_err) {
      return fallback;
    }
  }

  readBytes(path: string): Uint8Array | null {
    if (!this.exists(path)) {
      return null;
    }
    try {
      const stat = fileIo.statSync(path);
      const size = Number(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(size);
        const readLength = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
        return new Uint8Array(buffer).slice(0, readLength);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_err) {
      return null;
    }
  }

  writeText(path: string, content: string): void {
    this.ensureParentDir(path);
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
      try {
        fileIo.writeSync(file.fd, content, { encoding: 'utf-8' });
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_err) {
    }
  }

  writeBytes(path: string, content: Uint8Array): void {
    this.ensureParentDir(path);
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
      try {
        const buffer = new ArrayBuffer(content.byteLength);
        new Uint8Array(buffer).set(content);
        fileIo.writeSync(file.fd, buffer, { offset: 0, length: content.byteLength });
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_err) {
    }
  }

  readJsonObject(path: string, fallback: Object = emptyJsonRecord()): Object {
    const text = this.readText(path, '');
    if (text.length === 0) {
      return fallback;
    }
    try {
      const parsed = JSON.parse(text) as Object;
      return parsed;
    } catch (_err) {
      return fallback;
    }
  }

  readJsonRecord(path: string): JsonRecord {
    return this.readJsonObject(path, emptyJsonRecord()) as JsonRecord;
  }

  writeJson(path: string, value: Object): void {
    this.writeText(path, JSON.stringify(value, null, 4));
  }

  copyFile(source: string, target: string): boolean {
    if (!this.exists(source)) {
      return false;
    }
    this.ensureParentDir(target);
    if (this.exists(target)) {
      this.deleteFile(target);
    }
    try {
      fileIo.copyFileSync(source, target);
      return this.exists(target);
    } catch (_err) {
      return false;
    }
  }

  copyDirectory(source: string, target: string): boolean {
    if (!this.exists(source)) {
      return false;
    }

    try {
      this.ensureDir(target);
      const entries = this.list(source);
      for (const entry of entries) {
        const targetPath = joinPath(target, entry.name);
        if (entry.isDirectory) {
          if (!this.copyDirectory(entry.path, targetPath)) {
            return false;
          }
        } else if (!this.copyFile(entry.path, targetPath)) {
          return false;
        }
      }
      return true;
    } catch (_err) {
      return false;
    }
  }

  moveDirectory(source: string, target: string): boolean {
    if (!this.exists(source) || this.exists(target)) {
      return false;
    }
    if (!this.copyDirectory(source, target)) {
      return false;
    }
    return this.deleteDirectory(source);
  }

  stat(path: string, name: string = ''): FileEntry | null {
    if (!this.exists(path)) {
      return null;
    }
    try {
      const stat = fileIo.statSync(path);
      const displayName = name.length > 0 ? name : this.baseName(path);
      return new FileEntry(displayName, path, !stat.isDirectory(), stat.isDirectory(), Number(stat.size),
        this.toMs(Number(stat.mtime)), this.toMs(Number(stat.ctime)));
    } catch (_err) {
      return null;
    }
  }

  list(path: string): FileEntry[] {
    if (!this.exists(path)) {
      return [];
    }

    let names: string[] = [];
    try {
      names = fileIo.listFileSync(path);
    } catch (_err) {
      return [];
    }

    const entries: FileEntry[] = [];
    for (const name of names) {
      const entryPath = joinPath(path, name);
      try {
        const stat = fileIo.statSync(entryPath);
        entries.push(new FileEntry(name, entryPath, !stat.isDirectory(), stat.isDirectory(), Number(stat.size),
          this.toMs(Number(stat.mtime)), this.toMs(Number(stat.ctime))));
      } catch (_err) {
      }
    }
    return entries;
  }

  listFilesByExtension(path: string, ext: string): FileEntry[] {
    const targetExt = ext.toLowerCase();
    return this.list(path).filter((entry: FileEntry) => entry.isFile && extensionOf(entry.name) === targetExt)
      .sort((a: FileEntry, b: FileEntry) => a.name.localeCompare(b.name));
  }

  deleteFile(path: string): boolean {
    if (!this.exists(path)) {
      return false;
    }
    try {
      fileIo.unlinkSync(path);
      return true;
    } catch (_err) {
      return false;
    }
  }

  deleteDirectory(path: string): boolean {
    if (!this.exists(path)) {
      return false;
    }
    try {
      const entries = this.list(path);
      for (const entry of entries) {
        if (entry.isDirectory) {
          this.deleteDirectory(entry.path);
        } else {
          this.deleteFile(entry.path);
        }
      }
      fileIo.rmdirSync(path);
      return true;
    } catch (_err) {
      return false;
    }
  }

  baseName(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const index = normalized.lastIndexOf('/');
    if (index < 0) {
      return normalized;
    }
    return normalized.slice(index + 1);
  }

  directoryName(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const index = normalized.lastIndexOf('/');
    if (index <= 0) {
      return '';
    }
    return normalized.slice(0, index);
  }

  private toMs(value: number): number {
    return value > 0 && value < 1000000000000 ? value * 1000 : value;
  }

}
