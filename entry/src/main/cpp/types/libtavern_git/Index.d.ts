export interface GitCloneOptions {
  branch?: string;
  depth?: number;
  allowInsecureCertificate?: boolean;
  caBundlePath?: string;
}

export interface GitFetchOptions {
  unshallow?: boolean;
  allowInsecureCertificate?: boolean;
  caBundlePath?: string;
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

export declare function getNativeVersion(): string;
export declare function clone(url: string, targetPath: string, options?: GitCloneOptions): Promise<string>;
export declare function rehydrate(url: string, repoPath: string, reference: string, commit: string,
  options?: GitFetchOptions): Promise<GitVersionResult>;
export declare function update(repoPath: string, options?: GitFetchOptions): Promise<GitUpdateResult>;
export declare function version(repoPath: string, options?: GitFetchOptions): Promise<GitVersionResult>;
export declare function branches(repoPath: string, options?: GitFetchOptions): Promise<GitBranchInfo[]>;
export declare function switchBranch(repoPath: string, branch: string): Promise<void>;
