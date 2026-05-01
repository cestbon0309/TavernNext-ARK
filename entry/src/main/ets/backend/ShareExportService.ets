import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileStore } from './FileStore';
import { emptyJsonRecord, HttpResponse, JsonRecord } from './HttpTypes';
import { joinPath, sanitizeFileName } from './PathUtils';

const DOMAIN = 0x544156;
const TAG = 'TavernShareExport';

export class ExportedFile {
  path: string;
  uri: string;
  fileName: string;
  contentType: string;
  utd: string;

  constructor(path: string, uri: string, fileName: string, contentType: string, utd: string) {
    this.path = path;
    this.uri = uri;
    this.fileName = fileName;
    this.contentType = contentType;
    this.utd = utd;
  }
}

export class ShareExportService {
  private context: common.UIAbilityContext;
  private store: FileStore;
  private root: string;

  constructor(context: common.UIAbilityContext, store: FileStore, root: string) {
    this.context = context;
    this.store = store;
    this.root = root;
    this.store.ensureDir(this.root);
  }

  writeExportFile(category: string, fileName: string, bytes: Uint8Array, contentType: string, utd: string): ExportedFile {
    const safeCategory = sanitizeFileName(category);
    const safeFileName = sanitizeFileName(fileName);
    const directory = joinPath(this.root, safeCategory);
    const path = joinPath(directory, safeFileName);
    this.store.ensureDir(directory);
    this.store.writeBytes(path, bytes);
    return new ExportedFile(path, fileUri.getUriFromPath(path), safeFileName, contentType, utd);
  }

  async share(file: ExportedFile, title: string = ''): Promise<void> {
    try {
      const record: systemShare.SharedRecord = {
        utd: file.utd,
        uri: file.uri,
        title: title.length > 0 ? title : file.fileName,
        label: file.fileName,
        description: file.contentType,
      };
      const data = new systemShare.SharedData(record);
      const controller = new systemShare.ShareController(data);
      await controller.show(this.context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT,
      });
    } catch (err) {
      throw new Error(`ShareKit failed: ${JSON.stringify(err)}`);
    }
  }

  async shareHttpResponse(file: ExportedFile, title: string = ''): Promise<HttpResponse> {
    try {
      await this.share(file, title);
      return HttpResponse.json(this.responseBody(file, true));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ShareKit failed: %{public}s', JSON.stringify(err));
      const response = this.responseBody(file, false);
      response['error'] = 'share_failed';
      response['message'] = 'Export file was written, but ShareKit failed to open.';
      return HttpResponse.json(response, 500);
    }
  }

  private responseBody(file: ExportedFile, shared: boolean): JsonRecord {
    const response = emptyJsonRecord();
    response['ok'] = shared;
    response['shared'] = shared;
    response['file_name'] = file.fileName;
    response['path'] = file.path;
    response['uri'] = file.uri;
    response['content_type'] = file.contentType;
    return response;
  }

  static contentTypeForExtension(extension: string): string {
    switch (extension.toLowerCase()) {
      case '.json':
        return 'application/json';
      case '.jsonl':
        return 'application/jsonl';
      case '.png':
        return 'image/png';
      case '.txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  static utdForExtension(extension: string): string {
    switch (extension.toLowerCase()) {
      case '.json':
      case '.jsonl':
      case '.txt':
        return uniformTypeDescriptor.UniformDataType.PLAIN_TEXT;
      case '.png':
        return uniformTypeDescriptor.UniformDataType.PNG;
      default:
        return uniformTypeDescriptor.UniformDataType.FILE;
    }
  }
}
