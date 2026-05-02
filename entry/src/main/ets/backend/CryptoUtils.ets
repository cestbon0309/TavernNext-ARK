import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export class CryptoUtils {
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();

  randomBytes(length: number): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(length).data;
  }

  randomBase64(length: number): string {
    return this.base64.encodeToStringSync(this.randomBytes(length), util.Type.BASIC);
  }

  uuid(): string {
    const bytes = this.randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = this.toHex(bytes);
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  sha256(bytes: Uint8Array): Uint8Array {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: bytes });
    return md.digestSync().data;
  }

  sha256Hex(text: string): string {
    return this.toHex(this.sha256(this.encoder.encodeInto(text)));
  }

  hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = generator.convertKeySync({ data: key });
    const mac = cryptoFramework.createMac({
      algName: 'HMAC',
      mdName: 'SHA256',
    } as cryptoFramework.HmacSpec);
    mac.initSync(symKey);
    mac.updateSync({ data });
    return mac.doFinalSync().data;
  }

  scryptSillyTavern(password: string, salt: string): string {
    const kdf = cryptoFramework.createKdf('SCRYPT');
    const spec: cryptoFramework.ScryptSpec = {
      algName: 'SCRYPT',
      passphrase: this.encoder.encodeInto(password.normalize()),
      salt: this.encoder.encodeInto(salt),
      n: 16384,
      r: 8,
      p: 1,
      maxMemory: 32 * 1024 * 1024,
      keySize: 64,
    };
    return this.base64.encodeToStringSync(kdf.generateSecretSync(spec).data, util.Type.BASIC);
  }

  private toHex(bytes: Uint8Array): string {
    const chars: string[] = [];
    for (let index = 0; index < bytes.byteLength; index += 1) {
      chars.push(bytes[index].toString(16).padStart(2, '0'));
    }
    return chars.join('');
  }
}
