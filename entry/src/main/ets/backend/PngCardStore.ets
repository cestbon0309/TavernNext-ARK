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
    return this.readCardFromBytes(bytes);
  }

  readCardFromBytes(bytes: Uint8Array): JsonRecord | null {
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

  writeCardWithBase(path: string, baseImage: Uint8Array, card: JsonRecord): boolean {
    const output = this.writeCardToBytes(baseImage, card);
    if (output === null) {
      return false;
    }
    this.store.writeBytes(path, output);
    return true;
  }

  writeCardToBytes(baseImage: Uint8Array, card: JsonRecord): Uint8Array | null {
    try {
      return this.writeCardText(baseImage, JSON.stringify(card));
    } catch (_err) {
      return null;
    }
  }

  private readCardText(image: Uint8Array): string {
    if (!this.hasSignature(image)) {
      throw new Error('Invalid PNG signature');
    }

    let charaStart = -1;
    let charaEnd = -1;
    let offset = PNG_SIGNATURE.length;
    while (offset + 12 <= image.byteLength) {
      const length = this.readUInt32(image, offset);
      const type = this.readChunkType(image, offset + 4);
      const dataStart = offset + 8;
      const dataEnd = dataStart + length;
      if (dataEnd + 4 > image.byteLength) {
        throw new Error('Invalid PNG chunk length');
      }

      if (type === 'tEXt') {
        const separatorIndex = this.findTextSeparator(image, dataStart, dataEnd);
        if (separatorIndex >= 0) {
          const keyword = this.decodeAsciiRange(image, dataStart, separatorIndex).toLowerCase();
          if (keyword === 'ccv3') {
            return this.decodeCardJson(image.slice(separatorIndex + 1, dataEnd));
          }
          if (keyword === 'chara' && charaStart < 0) {
            charaStart = separatorIndex + 1;
            charaEnd = dataEnd;
          }
        }
      }

      offset = dataEnd + 4;
      if (type === 'IEND') {
        break;
      }
    }

    if (charaStart < 0 || charaEnd < charaStart) {
      throw new Error('No character metadata');
    }
    return this.decodeCardJson(image.slice(charaStart, charaEnd));
  }

  private writeCardText(image: Uint8Array, jsonText: string): Uint8Array {
    const filtered: PngChunk[] = [];

    if (!this.hasSignature(image)) {
      throw new Error('Invalid PNG signature');
    }

    let offset = PNG_SIGNATURE.length;
    while (offset + 12 <= image.byteLength) {
      const length = this.readUInt32(image, offset);
      const type = this.readChunkType(image, offset + 4);
      const dataStart = offset + 8;
      const dataEnd = dataStart + length;
      if (dataEnd + 4 > image.byteLength) {
        throw new Error('Invalid PNG chunk length');
      }

      let keepChunk = true;
      if (type === 'tEXt') {
        const separatorIndex = this.findTextSeparator(image, dataStart, dataEnd);
        if (separatorIndex >= 0) {
          const keyword = this.decodeAsciiRange(image, dataStart, separatorIndex).toLowerCase();
          if (keyword === 'chara' || keyword === 'ccv3') {
            keepChunk = false;
          }
        }
      }

      if (keepChunk) {
        filtered.push(new PngChunk(type, image.slice(dataStart, dataEnd)));
      }

      offset = dataEnd + 4;
      if (type === 'IEND') {
        break;
      }
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

  private decodeCardJson(encodedBytes: Uint8Array): string {
    const encoded = this.decoder.decodeToString(encodedBytes);
    return this.decoder.decodeToString(this.base64.decodeSync(encoded, util.Type.BASIC));
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

  private readChunkType(bytes: Uint8Array, offset: number): string {
    return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
  }

  private findTextSeparator(bytes: Uint8Array, start: number, end: number): number {
    for (let index = start; index < end; index += 1) {
      if (bytes[index] === 0) {
        return index;
      }
    }
    return -1;
  }

  private decodeAsciiRange(bytes: Uint8Array, start: number, end: number): string {
    return this.decoder.decodeToString(bytes.slice(start, end));
  }

  private latin1Encode(value: string): Uint8Array {
    const output = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index += 1) {
      output[index] = value.charCodeAt(index) & 0xff;
    }
    return output;
  }

}
