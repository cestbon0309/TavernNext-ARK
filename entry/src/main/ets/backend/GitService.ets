import {
  branches as nativeBranches,
  clone as nativeClone,
  getNativeVersion,
  switchBranch as nativeSwitchBranch,
  update as nativeUpdate,
  version as nativeVersion,
} from 'libtavern_git.so';
import { FileStore } from './FileStore';
import { JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';

export class NativeGitOptions {
  branch?: string;
  depth?: number;
  unshallow?: boolean;
  allowInsecureCertificate?: boolean;
  caBundlePath?: string;
}

export interface GitCloneOptions {
  branch?: string;
  depth?: number;
}

export interface GitUpdateResult {
  shortCommitHash: string;
  currentCommitHash: string;
  currentBranchName: string;
  extensionPath: string;
  isUpToDate: boolean;
  remoteUrl: string;
}

export interface GitVersionResult {
  currentBranchName: string;
  currentCommitHash: string;
  isUpToDate: boolean;
  remoteUrl: string;
}

export interface GitBranchInfo {
  name: string;
  commit: string;
  current: boolean;
  label: string;
}

export class GitService {
  private store: FileStore;
  private caBundlePath: string;

  constructor(store: FileStore, caBundlePath: string = '') {
    this.store = store;
    this.caBundlePath = caBundlePath;
  }

  nativeVersion(): string {
    try {
      return getNativeVersion();
    } catch (_err) {
      return '';
    }
  }

  folderNameFromUrl(url: string): string {
    const clean = url.trim().split('?')[0].split('#')[0].replace(/\\/g, '/');
    const parts = clean.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length === 0) {
      return '';
    }
    let name = parts[parts.length - 1];
    if (name.toLowerCase().endsWith('.git')) {
      name = name.slice(0, name.length - 4);
    }
    return sanitizeFileName(name);
  }

  async clone(url: string, targetPath: string, options: GitCloneOptions = {}): Promise<string> {
    const nativeOptions = this.nativeOptions();
    nativeOptions.depth = options.depth === undefined ? 1 : options.depth;
    if (options.branch !== undefined && options.branch.trim().length > 0) {
      nativeOptions.branch = options.branch.trim();
    }
    return await nativeClone(url, targetPath, nativeOptions);
  }

  async update(repoPath: string): Promise<GitUpdateResult> {
    const result: Object = await nativeUpdate(repoPath, this.nativeOptions());
    return this.normalizeUpdateResult(result, repoPath);
  }

  async version(repoPath: string): Promise<GitVersionResult> {
    const result: Object = await nativeVersion(repoPath, this.nativeOptions());
    return this.normalizeVersionResult(result);
  }

  async branches(repoPath: string): Promise<GitBranchInfo[]> {
    const result: Object[] = await nativeBranches(repoPath, this.nativeOptions());
    if (!Array.isArray(result)) {
      return [];
    }
    return result.map((item: object): GitBranchInfo => this.normalizeBranch(item));
  }

  async switchBranch(repoPath: string, branch: string): Promise<void> {
    await nativeSwitchBranch(repoPath, branch);
  }

  readManifest(extensionPath: string): JsonRecord {
    return this.store.readJsonRecord(joinPath(extensionPath, 'manifest.json'));
  }

  private nativeOptions(): NativeGitOptions {
    const options = new NativeGitOptions();
    if (this.caBundlePath.length > 0) {
      options.caBundlePath = this.caBundlePath;
    }
    return options;
  }

  private normalizeUpdateResult(value: object, fallbackPath: string): GitUpdateResult {
    const record = value as Record<string, Object | string | number | boolean | null | undefined>;
    return {
      shortCommitHash: this.asString(record['shortCommitHash']),
      currentCommitHash: this.asString(record['currentCommitHash']),
      currentBranchName: this.asString(record['currentBranchName']),
      extensionPath: this.asString(record['extensionPath']) || fallbackPath,
      isUpToDate: record['isUpToDate'] === true,
      remoteUrl: this.asString(record['remoteUrl']),
    };
  }

  private normalizeVersionResult(value: object): GitVersionResult {
    const record = value as Record<string, Object | string | number | boolean | null | undefined>;
    return {
      currentBranchName: this.asString(record['currentBranchName']),
      currentCommitHash: this.asString(record['currentCommitHash']),
      isUpToDate: record['isUpToDate'] === true,
      remoteUrl: this.asString(record['remoteUrl']),
    };
  }

  private normalizeBranch(value: object): GitBranchInfo {
    const record = value as Record<string, Object | string | number | boolean | null | undefined>;
    return {
      name: this.asString(record['name']),
      commit: this.asString(record['commit']),
      current: record['current'] === true,
      label: this.asString(record['label']),
    };
  }

  private asString(value: Object | string | number | boolean | null | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    return `${value}`;
  }
}
