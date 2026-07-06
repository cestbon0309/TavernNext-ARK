import { util } from '@kit.ArkTS';
import { emptyJsonRecord, HttpUploadedFile, JsonArray, JsonRecord } from './HttpTypes';

class MultipartHeaders {
  name: string = '';
  fileName: string = '';
  contentType: string = 'application/octet-stream';
}

export class MultipartResult {
  fields: JsonRecord = emptyJsonRecord();
  files: HttpUploadedFile[] = [];
}

export class MultipartParser {
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  parse(contentType: string, body: Uint8Array): MultipartResult {
    const boundary = this.boundaryFromContentType(contentType);
    if (boundary.length === 0) {
      throw new Error('multipart boundary missing');
    }

    const result = new MultipartResult();
    const delimiter = this.asciiBytes(`--${boundary}`);
    let cursor = 0;

    while (cursor < body.byteLength) {
      const delimiterIndex = this.indexOf(body, delimiter, cursor);
      if (delimiterIndex < 0) {
        break;
      }

      let partStart = delimiterIndex + delimiter.byteLength;
      if (this.matches(body, partStart, this.asciiBytes('--'))) {
        break;
      }
      if (this.matches(body, partStart, this.asciiBytes('\r\n'))) {
        partStart += 2;
      }

      const nextDelimiterIndex = this.indexOf(body, delimiter, partStart);
      if (nextDelimiterIndex < 0) {
        break;
      }

      let partEnd = nextDelimiterIndex;
      if (partEnd >= 2 && body[partEnd - 2] === 13 && body[partEnd - 1] === 10) {
        partEnd -= 2;
      }
      this.parsePart(body.slice(partStart, partEnd), result);
      cursor = nextDelimiterIndex;
    }
    return result;
  }

  private parsePart(part: Uint8Array, result: MultipartResult): void {
    const headerEnd = this.indexOf(part, this.asciiBytes('\r\n\r\n'), 0);
    if (headerEnd < 0) {
      return;
    }

    const headersText = this.decoder.decodeToString(part.slice(0, headerEnd));
    const headers = this.parseHeaders(headersText);
    if (headers.name.length === 0) {
      return;
    }

    const content = part.slice(headerEnd + 4);
    if (headers.fileName.length > 0) {
      result.files.push(new HttpUploadedFile(headers.name, headers.fileName, headers.contentType, content));
    } else {
      const decoded: string = this.decoder.decodeToString(content);
      const name: string = headers.name;
      const existing = result.fields[name] as string | JsonArray | undefined;
      if (existing === undefined) {
        result.fields[name] = decoded;
      } else if (Array.isArray(existing)) {
        (existing as JsonArray).push(decoded);
      } else {
        result.fields[name] = [existing, decoded] as JsonArray;
      }
    }
  }

  private parseHeaders(text: string): MultipartHeaders {
    const headers = new MultipartHeaders();
    for (const line of text.split('\r\n')) {
      const colon = line.indexOf(':');
      if (colon < 0) {
        continue;
      }
      const name = line.slice(0, colon).trim().toLowerCase();
      const value = line.slice(colon + 1).trim();
      if (name === 'content-type') {
        headers.contentType = value;
      } else if (name === 'content-disposition') {
        headers.name = this.dispositionValue(value, 'name');
        headers.fileName = this.dispositionValue(value, 'filename');
      }
    }
    return headers;
  }

  private dispositionValue(header: string, key: string): string {
    const parts = header.split(';');
    const prefix = `${key}=`;
    for (const part of parts) {
      const trimmed = part.trim();
      if (!trimmed.startsWith(prefix)) {
        continue;
      }
      let value = trimmed.slice(prefix.length);
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.slice(1, value.length - 1);
      }
      return value.replace(/\\"/g, '"');
    }
    return '';
  }

  private boundaryFromContentType(contentType: string): string {
    const parts = contentType.split(';');
    for (const part of parts) {
      const trimmed = part.trim();
      if (!trimmed.startsWith('boundary=')) {
        continue;
      }
      let value = trimmed.slice('boundary='.length);
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.slice(1, value.length - 1);
      }
      return value;
    }
    return '';
  }

  private asciiBytes(value: string): Uint8Array {
    const output = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index += 1) {
      output[index] = value.charCodeAt(index) & 0xff;
    }
    return output;
  }

  private matches(source: Uint8Array, offset: number, target: Uint8Array): boolean {
    if (offset + target.byteLength > source.byteLength) {
      return false;
    }
    for (let index = 0; index < target.byteLength; index += 1) {
      if (source[offset + index] !== target[index]) {
        return false;
      }
    }
    return true;
  }

  private indexOf(source: Uint8Array, target: Uint8Array, start: number): number {
    if (target.byteLength === 0) {
      return start;
    }
    for (let index = Math.max(0, start); index <= source.byteLength - target.byteLength; index += 1) {
      if (this.matches(source, index, target)) {
        return index;
      }
    }
    return -1;
  }
}
