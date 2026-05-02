export type CancellationCallback = () => void;

export class CancellationToken {
  private cancelled: boolean = false;
  private callbacks: CancellationCallback[] = [];

  isCancelled(): boolean {
    return this.cancelled;
  }

  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    for (let index = 0; index < this.callbacks.length; index += 1) {
      this.callbacks[index]();
    }
    this.callbacks = [];
  }

  onCancel(callback: CancellationCallback): void {
    if (this.cancelled) {
      callback();
      return;
    }
    this.callbacks.push(callback);
  }
}
