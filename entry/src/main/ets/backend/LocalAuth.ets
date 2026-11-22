import { cryptoFramework } from '@kit.CryptoArchitectureKit';

// Per-process secret that proves a request to the loopback server comes from this app.
export class LocalAuth {
  static readonly cookieName: string = 'tavern_next_auth';
  static readonly headerName: string = 'x-tavern-token';
  static readonly queryName: string = 't';
  static readonly bootstrapQueryName: string = 'tavernNextAuth';
  private static value: string = '';

  static token(): string {
    if (LocalAuth.value.length === 0) {
      const bytes = cryptoFramework.createRandom().generateRandomSync(32).data;
      let hex = '';
      for (let index = 0; index < bytes.byteLength; index++) {
        hex += bytes[index].toString(16).padStart(2, '0');
      }
      LocalAuth.value = hex;
    }
    return LocalAuth.value;
  }

  static headers(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers[LocalAuth.headerName] = LocalAuth.token();
    return headers;
  }

  static cookie(): string {
    return `${LocalAuth.cookieName}=${LocalAuth.token()}; Path=/; HttpOnly; SameSite=Strict`;
  }

  static withQueryToken(url: string): string {
    return `${url}${url.includes('?') ? '&' : '?'}${LocalAuth.queryName}=${LocalAuth.token()}`;
  }

  static matches(candidate: string): boolean {
    const expected = LocalAuth.token();
    if (candidate.length !== expected.length) {
      return false;
    }
    let diff = 0;
    for (let index = 0; index < expected.length; index++) {
      diff |= candidate.charCodeAt(index) ^ expected.charCodeAt(index);
    }
    return diff === 0;
  }
}
