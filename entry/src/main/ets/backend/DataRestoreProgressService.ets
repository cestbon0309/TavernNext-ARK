type RestoreProgressListener = (state: DataRestoreProgressState) => void;

export class DataRestoreProgressState {
  active: boolean = false;
  title: string = '';
  message: string = '';
  detail: string = '';
  failedExtensionGitRepairs: string[] = [];
}

export class DataRestoreProgressService {
  private static instance: DataRestoreProgressService | null = null;
  private state: DataRestoreProgressState = new DataRestoreProgressState();
  private listeners: RestoreProgressListener[] = [];

  static getInstance(): DataRestoreProgressService {
    if (DataRestoreProgressService.instance === null) {
      DataRestoreProgressService.instance = new DataRestoreProgressService();
    }
    return DataRestoreProgressService.instance;
  }

  subscribe(listener: RestoreProgressListener): void {
    this.listeners.push(listener);
    listener(this.snapshot());
  }

  begin(message: string, detail: string = ''): void {
    this.state.active = true;
    this.state.title = '正在导入数据';
    this.state.message = message;
    this.state.detail = detail;
    this.notify();
  }

  update(message: string, detail: string = ''): void {
    if (!this.state.active) {
      this.begin(message, detail);
      return;
    }
    this.state.message = message;
    this.state.detail = detail;
    this.notify();
  }

  finish(message: string = '导入完成', failedExtensionGitRepairs: string[] = []): void {
    this.state.active = false;
    this.state.title = '数据导入';
    this.state.message = message;
    this.state.detail = '';
    this.state.failedExtensionGitRepairs = failedExtensionGitRepairs;
    this.notify();
  }

  private snapshot(): DataRestoreProgressState {
    const copy = new DataRestoreProgressState();
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
