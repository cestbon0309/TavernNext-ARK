import { Context } from '@kit.AbilityKit';
import { ColorMetrics, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileStore } from './FileStore';
import { HttpRequest, HttpResponse, JsonRecord } from './HttpTypes';
import { joinPath } from './PathUtils';

const DOMAIN = 0x544156;
const TAG = 'ShellTheme';
const DEFAULT_BACKGROUND = '#171717';
const SETTINGS_FILE = 'shell-theme.json';

type BackgroundListener = (color: string) => void;

class RgbaColor {
  red: number;
  green: number;
  blue: number;

  constructor(red: number, green: number, blue: number) {
    this.red = red;
    this.green = green;
    this.blue = blue;
  }
}

export class ShellThemeService {
  private static instance: ShellThemeService | null = null;
  private store: FileStore = new FileStore();
  private settingsPath: string;
  private backgroundColor: string = DEFAULT_BACKGROUND;
  private mainWindow: window.Window | null = null;
  private listeners: BackgroundListener[] = [];

  private constructor(context: Context) {
    this.settingsPath = joinPath(context.filesDir, '_shell', SETTINGS_FILE);
    const saved = this.store.readJsonRecord(this.settingsPath);
    this.backgroundColor = this.normalizeColor(this.asString(saved['backgroundColor'])) ?? DEFAULT_BACKGROUND;
  }

  static getInstance(context: Context): ShellThemeService {
    if (ShellThemeService.instance === null) {
      ShellThemeService.instance = new ShellThemeService(context);
    }
    return ShellThemeService.instance;
  }

  getBackgroundColor(): string {
    return this.backgroundColor;
  }

  subscribe(listener: BackgroundListener): void {
    this.listeners.push(listener);
  }

  attachWindow(mainWindow: window.Window): void {
    this.mainWindow = mainWindow;
    this.applyToWindow();
  }

  reportBackground(request: HttpRequest): HttpResponse {
    const body = (request.body ?? {}) as JsonRecord;
    const color = this.normalizeColor(this.asString(body['color']));
    if (color === null) {
      const response: JsonRecord = {};
      response['ok'] = false;
      response['backgroundColor'] = this.backgroundColor;
      return HttpResponse.json(response, 400);
    }

    this.setBackgroundColor(color);
    const response: JsonRecord = {};
    response['ok'] = true;
    response['backgroundColor'] = this.backgroundColor;
    return HttpResponse.json(response);
  }

  private setBackgroundColor(color: string): void {
    if (color === this.backgroundColor) {
      return;
    }
    this.backgroundColor = color;
    const settings: JsonRecord = {};
    settings['backgroundColor'] = color;
    this.store.writeJson(this.settingsPath, settings);
    this.applyToWindow();
    for (const listener of this.listeners) {
      listener(color);
    }
  }

  private applyToWindow(): void {
    if (this.mainWindow === null) {
      return;
    }

    try {
      this.mainWindow.setWindowBackgroundColor(this.backgroundColor);
      const contentColor = this.contentColorFor(this.backgroundColor);
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: this.backgroundColor,
        navigationBarColor: this.backgroundColor,
        isStatusBarLightIcon: contentColor === '#FFFFFF',
        isNavigationBarLightIcon: contentColor === '#FFFFFF',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Failed to set system bar theme. Cause: %{public}s', JSON.stringify(err));
      });

      const rgba = this.hexToRgba(this.backgroundColor);
      this.mainWindow.setStatusBarColor(ColorMetrics.rgba(rgba.red, rgba.green, rgba.blue, 1)).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Failed to set status bar color. Cause: %{public}s', JSON.stringify(err));
      });
      window.setStartWindowBackgroundColor('entry', 'EntryAbility',
        ColorMetrics.rgba(rgba.red, rgba.green, rgba.blue, 1)).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'Failed to set start window color. Cause: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to apply shell theme. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private normalizeColor(value: string): string | null {
    const trimmed = value.trim();
    if (trimmed.length === 0 || trimmed === 'transparent') {
      return null;
    }

    const hex = this.normalizeHex(trimmed);
    if (hex !== null) {
      return hex;
    }

    const rgba = this.parseRgb(trimmed);
    if (rgba !== null) {
      return this.rgbToHex(rgba.red, rgba.green, rgba.blue);
    }

    return null;
  }

  private normalizeHex(value: string): string | null {
    if (/^#[0-9a-fA-F]{6}$/.test(value)) {
      return value.toUpperCase();
    }
    if (/^#[0-9a-fA-F]{3}$/.test(value)) {
      const red = value[1];
      const green = value[2];
      const blue = value[3];
      return `#${red}${red}${green}${green}${blue}${blue}`.toUpperCase();
    }
    return null;
  }

  private parseRgb(value: string): RgbaColor | null {
    const match = /^rgba?\(([^)]+)\)$/i.exec(value);
    if (match === null) {
      return null;
    }

    const parts = match[1].split(',').map((part: string): string => part.trim());
    if (parts.length < 3) {
      return null;
    }

    const alpha = parts.length >= 4 ? Number(parts[3]) : 1;
    if (!Number.isFinite(alpha) || alpha <= 0) {
      return null;
    }

    const red = this.clampColor(Number(parts[0]));
    const green = this.clampColor(Number(parts[1]));
    const blue = this.clampColor(Number(parts[2]));
    if (red === null || green === null || blue === null) {
      return null;
    }

    if (alpha >= 1) {
      return new RgbaColor(red, green, blue);
    }

    const base = this.hexToRgba(DEFAULT_BACKGROUND);
    return new RgbaColor(
      Math.round(red * alpha + base.red * (1 - alpha)),
      Math.round(green * alpha + base.green * (1 - alpha)),
      Math.round(blue * alpha + base.blue * (1 - alpha))
    );
  }

  private clampColor(value: number): number | null {
    if (!Number.isFinite(value)) {
      return null;
    }
    return Math.max(0, Math.min(255, Math.round(value)));
  }

  private rgbToHex(red: number, green: number, blue: number): string {
    return `#${this.hexPair(red)}${this.hexPair(green)}${this.hexPair(blue)}`;
  }

  private hexPair(value: number): string {
    return value.toString(16).padStart(2, '0').toUpperCase();
  }

  private hexToRgba(value: string): RgbaColor {
    return new RgbaColor(
      Number.parseInt(value.slice(1, 3), 16),
      Number.parseInt(value.slice(3, 5), 16),
      Number.parseInt(value.slice(5, 7), 16)
    );
  }

  private contentColorFor(color: string): string {
    const rgba = this.hexToRgba(color);
    const luminance = (rgba.red * 299 + rgba.green * 587 + rgba.blue * 114) / 1000;
    return luminance < 160 ? '#FFFFFF' : '#000000';
  }

  private asString(value: Object | string | number | boolean | null | undefined): string {
    return typeof value === 'string' ? value : '';
  }
}
