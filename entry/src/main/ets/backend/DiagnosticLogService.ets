import { hilog as systemHilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { FileStore } from './FileStore';
import { joinPath, sanitizeFileName } from './PathUtils';
import type { ExportedFile, ShareExportService } from './ShareExportService';

const DIAGNOSTIC_DOMAIN = 0x5441;
const DIAGNOSTIC_TAG = 'TavernDiagnostics';
const CAPTURE_DURATION_MS = 30 * 1000;
const FLUSH_INTERVAL_MS = 500;
const EXPORT_RETENTION_MS = 5 * 60 * 1000;
const MAX_LOG_LINES = 12000;
const MAX_LOG_LINE_LENGTH = 4000;

type LogArgument = string | number | boolean | Object | null | undefined;
type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'fatal';

export class DiagnosticLogService {
  private static instance: DiagnosticLogService = new DiagnosticLogService();
  private store: FileStore = new FileStore();
  private filesDir: string = '';
  private diagnosticsDir: string = '';
  private pendingCapturePath: string = '';
  private startupInProgressPath: string = '';
  private sessionLogPath: string = '';
  private captureActive: boolean = false;
  private captureFinalizing: boolean = false;
  private sessionLines: string[] = [];
  private flushedLineCount: number = 0;
  private sessionDirty: boolean = false;
  private flushTimer: number = -1;
  private captureTimer: number = -1;
  private launchStartedAtMs: number = Date.now();
  private shareExports: ShareExportService | null = null;
  private preparedReport: string = '';

  private constructor() {
  }

  static getInstance(): DiagnosticLogService {
    return DiagnosticLogService.instance;
  }

  static initialize(filesDir: string): void {
    DiagnosticLogService.instance.initializeInternal(filesDir);
  }

  static setShareExportService(service: ShareExportService): void {
    DiagnosticLogService.instance.shareExports = service;
  }

  static debug(domain: number, tag: string, format: string, ...args: LogArgument[]): void {
    DiagnosticLogService.instance.emit('debug', domain, tag, format, args);
  }

  static info(domain: number, tag: string, format: string, ...args: LogArgument[]): void {
    DiagnosticLogService.instance.emit('info', domain, tag, format, args);
  }

  static warn(domain: number, tag: string, format: string, ...args: LogArgument[]): void {
    DiagnosticLogService.instance.emit('warn', domain, tag, format, args);
  }

  static error(domain: number, tag: string, format: string, ...args: LogArgument[]): void {
    DiagnosticLogService.instance.emit('error', domain, tag, format, args);
  }

  static fatal(domain: number, tag: string, format: string, ...args: LogArgument[]): void {
    DiagnosticLogService.instance.emit('fatal', domain, tag, format, args);
  }

  isCapturing(): boolean {
    return this.captureActive;
  }

  remainingLaunchDelay(delayMs: number): number {
    return Math.max(0, delayMs - (Date.now() - this.launchStartedAtMs));
  }

  launchDeadline(delayMs: number): number {
    return this.launchStartedAtMs + delayMs;
  }

  launchStartTime(): number {
    return this.launchStartedAtMs;
  }

  markNextLaunchCapture(): void {
    if (this.pendingCapturePath.length === 0) {
      return;
    }
    if (!this.writeMarker(this.pendingCapturePath)) {
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
        'Failed to persist the next-launch diagnostic capture marker');
      return;
    }
    this.emit('info', DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
      'Frontend initialization watchdog requested capture on the next launch', []);
  }

  markFrontendInitialized(): void {
    if (this.startupInProgressPath.length === 0 || !this.store.exists(this.startupInProgressPath)) {
      return;
    }
    if (!this.store.deleteFile(this.startupInProgressPath)) {
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
        'Failed to clear the startup-in-progress diagnostic marker');
    }
  }

  scheduleCaptureCompletion(completion: () => void): void {
    if (!this.captureActive || this.captureTimer >= 0) {
      return;
    }
    const delayMs = this.remainingLaunchDelay(CAPTURE_DURATION_MS);
    this.captureTimer = setTimeout(() => {
      this.captureTimer = -1;
      completion();
    }, delayMs);
  }

  cancelCaptureCompletion(): void {
    if (this.captureTimer >= 0) {
      clearTimeout(this.captureTimer);
      this.captureTimer = -1;
    }
  }

  suspendCapture(): void {
    this.cancelCaptureCompletion();
    if (!this.captureActive) {
      return;
    }
    this.flushSessionLog();
    this.stopFlushTimer();
    this.resetSessionState();
  }

  appendWebLog(level: string, message: string): void {
    const normalizedLevel = this.normalizeLevel(level);
    const normalizedMessage = message.trim();
    if (normalizedMessage.length === 0 || !this.isAllowedWebMessage(normalizedMessage)) {
      return;
    }
    this.appendSessionLine('ArkWeb', normalizedLevel, 'console', normalizedMessage);
  }

  prepareCaptureReport(): boolean {
    if (!this.captureActive) {
      return this.preparedReport.length > 0;
    }
    this.appendSessionLine('Native', 'info', DIAGNOSTIC_TAG, 'Diagnostic capture finished');
    this.flushSessionLog();
    this.stopFlushTimer();
    this.captureActive = false;
    this.preparedReport = this.createReport();
    this.resetSessionState();
    return true;
  }

  async finishCaptureAndShare(): Promise<boolean> {
    if (this.captureFinalizing || !this.prepareCaptureReport()) {
      return false;
    }
    this.captureFinalizing = true;
    const report = this.preparedReport;
    const shareService = this.shareExports;
    if (shareService === null) {
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
        'Cannot share diagnostic report because ShareExportService is not ready');
      this.resetSessionState();
      this.captureFinalizing = false;
      return false;
    }

    const fileName = sanitizeFileName(`tavernnext-diagnostics-${Date.now()}.txt`);
    let file: ExportedFile | null = null;
    try {
      const bytes = new util.TextEncoder('utf-8').encodeInto(report);
      file = shareService.writeExportFile('diagnostics', fileName, bytes, 'text/plain; charset=utf-8',
        uniformTypeDescriptor.UniformDataType.PLAIN_TEXT);
      await shareService.share(file, 'TavernNext 启动诊断日志');
      const sharedFile = file;
      setTimeout(() => {
        shareService.discard(sharedFile);
      }, EXPORT_RETENTION_MS);
      this.deleteMarker(this.pendingCapturePath, 'next-launch diagnostic capture');
      this.deleteMarker(this.startupInProgressPath, 'startup-in-progress diagnostic');
      this.store.deleteFile(this.sessionLogPath);
      this.preparedReport = '';
      this.resetSessionState();
      this.captureFinalizing = false;
      return true;
    } catch (err) {
      if (file !== null) {
        shareService.discard(file);
      }
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
        'Failed to create or share diagnostic report: %{public}s', JSON.stringify(err));
      this.preparedReport = '';
      this.resetSessionState();
      this.captureFinalizing = false;
      return false;
    }
  }

  private initializeInternal(filesDir: string): void {
    this.stopFlushTimer();
    if (this.captureTimer >= 0) {
      clearTimeout(this.captureTimer);
      this.captureTimer = -1;
    }
    this.resetSessionState();
    this.captureFinalizing = false;
    this.preparedReport = '';
    this.shareExports = null;
    this.filesDir = filesDir;
    this.diagnosticsDir = joinPath(filesDir, '_diagnostics');
    this.pendingCapturePath = joinPath(this.diagnosticsDir, 'capture-on-next-launch');
    this.startupInProgressPath = joinPath(this.diagnosticsDir, 'startup-in-progress');
    this.sessionLogPath = joinPath(this.diagnosticsDir, 'startup-session.log');
    this.store.ensureDir(this.diagnosticsDir);
    this.launchStartedAtMs = Date.now();

    const explicitCaptureRequested = this.store.readText(this.pendingCapturePath).trim() === '1';
    const previousStartupIncomplete = this.store.readText(this.startupInProgressPath).trim() === '1';
    if (!this.writeMarker(this.startupInProgressPath)) {
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
        'Failed to persist the startup-in-progress diagnostic marker');
    }
    const captureRequested = explicitCaptureRequested || previousStartupIncomplete;
    if (captureRequested) {
      if (!this.writeMarker(this.pendingCapturePath)) {
        systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG,
          'Failed to persist the active diagnostic capture marker');
      }
      this.captureActive = true;
      this.sessionLines = [];
      this.flushedLineCount = 0;
      this.store.deleteFile(this.sessionLogPath);
      this.appendSessionLine('Native', 'info', DIAGNOSTIC_TAG,
        previousStartupIncomplete
          ? 'Diagnostic capture started because the previous launch did not finish initialization'
          : 'Diagnostic capture started because the frontend watchdog requested it');
      this.startFlushTimer();
    }
  }

  private resetSessionState(): void {
    this.captureActive = false;
    this.sessionLines = [];
    this.flushedLineCount = 0;
    this.sessionDirty = false;
  }

  private writeMarker(path: string): boolean {
    this.store.writeText(path, '1');
    return this.store.readText(path).trim() === '1';
  }

  private deleteMarker(path: string, label: string): void {
    if (path.length === 0 || !this.store.exists(path)) {
      return;
    }
    if (!this.store.deleteFile(path)) {
      systemHilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG, 'Failed to clear %{public}s marker', label);
    }
  }

  private emit(level: LogLevel, domain: number, tag: string, format: string, args: LogArgument[]): void {
    switch (level) {
      case 'debug':
        systemHilog.debug(domain, tag, format, ...args);
        break;
      case 'info':
        systemHilog.info(domain, tag, format, ...args);
        break;
      case 'warn':
        systemHilog.warn(domain, tag, format, ...args);
        break;
      case 'error':
        systemHilog.error(domain, tag, format, ...args);
        break;
      case 'fatal':
        systemHilog.fatal(domain, tag, format, ...args);
        break;
    }
    this.appendSessionLine('Native', level, tag, this.formatMessage(format, args));
  }

  private appendSessionLine(source: string, level: string, tag: string, message: string): void {
    if (!this.captureActive) {
      return;
    }
    if (this.sessionLines.length >= MAX_LOG_LINES) {
      if (this.sessionLines.length === MAX_LOG_LINES) {
        this.sessionLines.push(this.timestamp() + ' [Native] [warn] [TavernDiagnostics] log limit reached');
        this.sessionDirty = true;
      }
      return;
    }
    const safeMessage = this.redact(message).slice(0, MAX_LOG_LINE_LENGTH);
    this.sessionLines.push(`${this.timestamp()} [${source}] [${level}] [${tag}] ${safeMessage}`);
    this.sessionDirty = true;
  }

  private startFlushTimer(): void {
    this.stopFlushTimer();
    this.flushTimer = setInterval(() => {
      this.flushSessionLog();
    }, FLUSH_INTERVAL_MS);
  }

  private stopFlushTimer(): void {
    if (this.flushTimer >= 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
  }

  private flushSessionLog(): void {
    if (!this.captureActive || !this.sessionDirty) {
      return;
    }
    const pendingLines = this.sessionLines.slice(this.flushedLineCount);
    if (pendingLines.length === 0) {
      this.sessionDirty = false;
      return;
    }
    const content = pendingLines.join('\n') + '\n';
    if (this.flushedLineCount === 0) {
      this.store.writeText(this.sessionLogPath, content);
    } else {
      this.store.appendText(this.sessionLogPath, content);
    }
    this.flushedLineCount = this.sessionLines.length;
    this.sessionDirty = false;
  }

  private createReport(): string {
    const sessionLog = this.store.readText(this.sessionLogPath, this.sessionLines.join('\n'));
    const endTime = new Date().toISOString();
    return [
      'TavernNext startup diagnostic report',
      `capture_started_at: ${new Date(this.launchStartedAtMs).toISOString()}`,
      `capture_finished_at: ${endTime}`,
      `capture_duration_ms: ${Date.now() - this.launchStartedAtMs}`,
      'privacy: request bodies and raw response bodies are not collected; credentials are redacted from captured messages.',
      '--- log begins ---',
      sessionLog,
      '--- log ends ---',
      ''
    ].join('\n');
  }

  private formatMessage(format: string, args: LogArgument[]): string {
    let index = 0;
    const formatted = format.replace(/%\{public\}[sdif]/g, () => {
      const value = index < args.length ? args[index] : '';
      index += 1;
      return this.argumentText(value);
    });
    if (index >= args.length) {
      return formatted;
    }
    const remaining = args.slice(index).map((value: LogArgument): string => this.argumentText(value)).join(', ');
    return `${formatted} args=[${remaining}]`;
  }

  private argumentText(value: LogArgument): string {
    if (value === null || value === undefined) {
      return String(value);
    }
    if (value instanceof Error) {
      return value.stack ?? value.message;
    }
    if (typeof value === 'object') {
      try {
        return JSON.stringify(value);
      } catch (_err) {
        return '[unserializable object]';
      }
    }
    return String(value);
  }

  private normalizeLevel(level: string): LogLevel {
    switch (level.toLowerCase()) {
      case 'debug':
        return 'debug';
      case 'info':
      case 'log':
        return 'info';
      case 'warn':
      case 'warning':
        return 'warn';
      case 'error':
        return 'error';
      default:
        return 'info';
    }
  }

  private isAllowedWebMessage(message: string): boolean {
    return /^(\[TavernNext startup\]|ArkWeb|window\.|document\.|resource-error|unhandledrejection)/.test(message);
  }

  private redact(value: string): string {
    const bearerRedacted = value
      .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [REDACTED]')
      .replace(/Basic\s+[A-Za-z0-9+/=]+/gi, 'Basic [REDACTED]')
      .replace(/\b(https?:\/\/)[^/\s:@]+:[^@\s/]+@/gi, '$1[REDACTED]@');
    return bearerRedacted.replace(
      /(["']?(?:authorization|proxy-authorization|cookie|set-cookie|(?:[A-Za-z0-9]+[-_])*(?:api[-_]?key|access[-_]?token|refresh[-_]?token|password|secret|token)(?:[-_][A-Za-z0-9]+)*)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,\s&}\]]+)/gi,
      '$1[REDACTED]');
  }

  private timestamp(): string {
    return new Date().toISOString();
  }
}
