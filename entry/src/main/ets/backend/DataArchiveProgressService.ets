type ArchiveProgressListener = (state: DataArchiveProgressState) => void;

export class DataArchiveProgressState {
  active: boolean = false;
  title: string = '';
  message: string = '';
  detail: string = '';
  failedExtensionGitRepairs: string[] = [];
}

export class DataArchiveProgressService {
  private static instance: DataArchiveProgressService | null = null;
  private state: DataArchiveProgressState = new DataArchiveProgressState();
  private listeners: ArchiveProgressListener[] = [];

  static getInstance(): DataArchiveProgressService {
    if (DataArchiveProgressService.instance === null) {
      DataArchiveProgressService.instance = new DataArchiveProgressService();
    }
    return DataArchiveProgressService.instance;
  }

  subscribe(listener: ArchiveProgressListener): void {
    this.listeners.push(listener);
    listener(this.snapshot());
  }

  begin(title: string, message: string, detail: string = ''): void {
    this.state.active = true;
    this.state.title = title;
    this.state.message = message;
    this.state.detail = detail;
    this.state.failedExtensionGitRepairs = [];
    this.notify();
  }

  update(message: string, detail: string = ''): void {
    if (!this.state.active) {
      this.begin('正在处理数据', message, detail);
      return;
    }
    this.state.message = message;
    this.state.detail = detail;
    this.notify();
  }

  finish(message: string = '处理完成', failedExtensionGitRepairs: string[] = []): void {
    this.state.active = false;
    this.state.title = '';
    this.state.message = message;
    this.state.detail = '';
    this.state.failedExtensionGitRepairs = failedExtensionGitRepairs;
    this.notify();
  }

  private snapshot(): DataArchiveProgressState {
    const copy = new DataArchiveProgressState();
    copy.active = this.state.active;
    copy.title = this.state.title;
    copy.message = this.state.message;
    copy.detail = this.state.detail;
    copy.failedExtensionGitRepairs = [...this.state.failedExtensionGitRepairs];
    return copy;
  }

  private notify(): void {
    const snapshot = this.snapshot();
    for (const listener of this.listeners) {
      listener(snapshot);
    }
  }
}
