import { util } from '@kit.ArkTS';
import { FileStore } from './FileStore';
import { JsonRecord } from './HttpTypes';

class PngChunk {
  type: string;
  data: Uint8Array;

  constructor(type: string, data: Uint8Array) {
    this.type = type;
    this.data = data;
  }
}

class TextChunkInfo {
  keyword: string;
  text: string;

  constructor(keyword: string, text: string) {
    this.keyword = keyword;
    this.text = text;
  }
}

const PNG_SIGNATURE: number[] = [137, 80, 78, 71, 13, 10, 26, 10];
const DEFAULT_PNG_BYTES: number[] = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0,
  0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1,
  122, 94, 171, 63, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

export class PngCardStore {
  private store: FileStore;
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();

  constructor(store: FileStore) {
    this.store = store;
  }

  readCard(path: string): JsonRecord | null {
    const bytes = this.store.readBytes(path);
    if (bytes === null) {
      return null;
    }
    try {
      const jsonText = this.readCardText(bytes);
      return JSON.parse(jsonText) as JsonRecord;
    } catch (_err) {
      return null;
    }
  }

  writeCard(path: string, card: JsonRecord): boolean {
    const existing = this.store.readBytes(path);
    const baseImage = existing ?? new Uint8Array(DEFAULT_PNG_BYTES);
    try {
      const output = this.writeCardText(baseImage, JSON.stringify(card));
      this.store.writeBytes(path, output);
      return true;
    } catch (_err) {
      return false;
    }
  }

  private readCardText(image: Uint8Array): string {
    const chunks = this.extractChunks(image);
    let charaText = '';
    let ccv3Text = '';
    for (const chunk of chunks) {
      if (chunk.type !== 'tEXt') {
        continue;
      }
      const text = this.decodeTextChunk(chunk.data);
      const keyword = text.keyword.toLowerCase();
      if (keyword === 'ccv3') {
        ccv3Text = text.text;
      } else if (keyword === 'chara') {
        charaText = text.text;
      }
    }

    const encoded = ccv3Text.length > 0 ? ccv3Text : charaText;
    if (encoded.length === 0) {
      throw new Error('No character metadata');
    }
    return this.decoder.decodeToString(this.base64.decodeSync(encoded, util.Type.BASIC));
  }

  private writeCardText(image: Uint8Array, jsonText: string): Uint8Array {
    const chunks = this.extractChunks(image);
    const filtered: PngChunk[] = [];
    for (const chunk of chunks) {
      if (chunk.type === 'tEXt') {
        const text = this.decodeTextChunk(chunk.data);
        const keyword = text.keyword.toLowerCase();
        if (keyword === 'chara' || keyword === 'ccv3') {
          continue;
        }
      }
      filtered.push(chunk);
    }

    const base64Json = this.base64.encodeToStringSync(this.encoder.encodeInto(jsonText), util.Type.BASIC);
    const charaChunk = new PngChunk('tEXt', this.encodeTextChunk('chara', base64Json));

    let insertIndex = filtered.length;
    for (let index = 0; index < filtered.length; index += 1) {
      if (filtered[index].type === 'IEND') {
        insertIndex = index;
        break;
      }
    }
    filtered.splice(insertIndex, 0, charaChunk);
    return this.encodeChunks(filtered);
  }

  private extractChunks(image: Uint8Array): PngChunk[] {
    if (!this.hasSignature(image)) {
      throw new Error('Invalid PNG signature');
    }
    const chunks: PngChunk[] = [];
    let offset = 8;
    while (offset + 12 <= image.byteLength) {
      const length = this.readUInt32(image, offset);
      const type = this.asciiDecode(image.slice(offset + 4, offset + 8));
      const dataStart = offset + 8;
      const dataEnd = dataStart + length;
      if (dataEnd + 4 > image.byteLength) {
        throw new Error('Invalid PNG chunk length');
      }
      chunks.push(new PngChunk(type, image.slice(dataStart, dataEnd)));
      offset = dataEnd + 4;
      if (type === 'IEND') {
        break;
      }
    }
    return chunks;
  }

  private encodeChunks(chunks: PngChunk[]): Uint8Array {
    let total = PNG_SIGNATURE.length;
    for (const chunk of chunks) {
      total += 12 + chunk.data.byteLength;
    }

    const output = new Uint8Array(total);
    output.set(new Uint8Array(PNG_SIGNATURE), 0);
    let offset = PNG_SIGNATURE.length;
    for (const chunk of chunks) {
      this.writeUInt32(output, offset, chunk.data.byteLength);
      output.set(this.asciiEncode(chunk.type), offset + 4);
      output.set(chunk.data, offset + 8);
      const crcInput = new Uint8Array(4 + chunk.data.byteLength);
      crcInput.set(this.asciiEncode(chunk.type), 0);
      crcInput.set(chunk.data, 4);
      this.writeUInt32(output, offset + 8 + chunk.data.byteLength, this.crc32(crcInput));
      offset += 12 + chunk.data.byteLength;
    }
    return output;
  }

  private decodeTextChunk(data: Uint8Array): TextChunkInfo {
    let zeroIndex = -1;
    for (let index = 0; index < data.byteLength; index += 1) {
      if (data[index] === 0) {
        zeroIndex = index;
        break;
      }
    }
    if (zeroIndex < 0) {
      throw new Error('Invalid tEXt chunk');
    }
    return new TextChunkInfo(this.latin1Decode(data.slice(0, zeroIndex)), this.latin1Decode(data.slice(zeroIndex + 1)));
  }

  private encodeTextChunk(keyword: string, text: string): Uint8Array {
    const keywordBytes = this.latin1Encode(keyword);
    const textBytes = this.latin1Encode(text);
    const output = new Uint8Array(keywordBytes.byteLength + 1 + textBytes.byteLength);
    output.set(keywordBytes, 0);
    output[keywordBytes.byteLength] = 0;
    output.set(textBytes, keywordBytes.byteLength + 1);
    return output;
  }

  private hasSignature(image: Uint8Array): boolean {
    if (image.byteLength < PNG_SIGNATURE.length) {
      return false;
    }
    for (let index = 0; index < PNG_SIGNATURE.length; index += 1) {
      if (image[index] !== PNG_SIGNATURE[index]) {
        return false;
      }
    }
    return true;
  }

  private readUInt32(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
  }

  private writeUInt32(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = (value >>> 24) & 0xff;
    bytes[offset + 1] = (value >>> 16) & 0xff;
    bytes[offset + 2] = (value >>> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
  }

  private crc32(bytes: Uint8Array): number {
    let crc = 0xffffffff;
    for (let index = 0; index < bytes.byteLength; index += 1) {
      crc = (crc >>> 8) ^ this.crc32TableValue((crc ^ bytes[index]) & 0xff);
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  private crc32TableValue(value: number): number {
    let crc = value;
    for (let index = 0; index < 8; index += 1) {
      crc = (crc & 1) !== 0 ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
    return crc >>> 0;
  }

  private asciiEncode(value: string): Uint8Array {
    return this.latin1Encode(value);
  }

  private asciiDecode(bytes: Uint8Array): string {
    return this.latin1Decode(bytes);
  }

  private latin1Encode(value: string): Uint8Array {
    const output = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index += 1) {
      output[index] = value.charCodeAt(index) & 0xff;
    }
    return output;
  }

  private latin1Decode(bytes: Uint8Array): string {
    let output = '';
    for (let index = 0; index < bytes.byteLength; index += 1) {
      output += String.fromCharCode(bytes[index]);
    }
    return output;
  }
}
