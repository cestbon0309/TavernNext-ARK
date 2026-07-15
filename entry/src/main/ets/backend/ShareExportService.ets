import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileStore } from './FileStore';
import { emptyJsonRecord, HttpResponse, JsonRecord } from './HttpTypes';
import { extensionOf, joinPath, sanitizeFileName, withoutExtension } from './PathUtils';

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
    const file = this.exportFileReference(category, fileName, contentType, utd);
    this.store.writeBytes(file.path, bytes);
    return file;
  }

  exportFileReference(category: string, fileName: string, contentType: string, utd: string): ExportedFile {
    const safeCategory = sanitizeFileName(category);
    const safeFileName = sanitizeFileName(fileName);
    const directory = joinPath(this.root, safeCategory);
    const path = joinPath(directory, safeFileName);
    this.store.ensureDir(directory);
    return new ExportedFile(path, fileUri.getUriFromPath(path), safeFileName, contentType, utd);
  }

  webDownloadFileReference(fileName: string, contentType: string): ExportedFile {
    const safeFileName = sanitizeFileName(fileName);
    const extension = extensionOf(safeFileName);
    const baseName = withoutExtension(safeFileName) || 'download';
    const normalizedContentType = contentType.split(';')[0].trim() ||
      ShareExportService.contentTypeForExtension(extension);
    let candidate = safeFileName === 'unnamed' ? `download${extension}` : safeFileName;
    let suffix = 1;
    while (this.store.exists(joinPath(this.root, 'downloads', candidate))) {
      candidate = `${baseName}_${suffix}${extension}`;
      suffix += 1;
    }
    return this.exportFileReference('downloads', candidate, normalizedContentType,
      ShareExportService.utdForContentType(normalizedContentType, extension));
  }

  discard(file: ExportedFile): void {
    this.store.deleteFile(file.path);
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
      case '.zip':
        return 'application/zip';
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
      case '.zip':
        return uniformTypeDescriptor.UniformDataType.ZIP_ARCHIVE;
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

  static utdForContentType(contentType: string, extension: string): string {
    try {
      if (contentType.length > 0 && contentType !== 'application/octet-stream') {
        return uniformTypeDescriptor.getUniformDataTypeByMIMEType(contentType);
      }
      if (extension.length > 0) {
        return uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(extension);
      }
    } catch (_err) {
    }
    return ShareExportService.utdForExtension(extension);
  }
}
