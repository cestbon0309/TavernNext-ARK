import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { JsonRecord } from '../HttpTypes';
import { parseJsonRecord } from '../JsonUtils';
import { RemoteHttpClient } from '../RemoteHttpClient';
import { asNumberValue, asStringValue } from './JsonHelpers';

const CLOUD_PLATFORM_SCOPE = 'https://www.googleapis.com/auth/cloud-platform';
const GOOGLE_OAUTH_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const TOKEN_REFRESH_SKEW_SECONDS = 120;

class VertexServiceAccount {
  clientEmail: string = '';
  privateKey: string = '';
  privateKeyId: string = '';
  projectId: string = '';
}

class VertexAccessTokenCacheEntry {
  projectId: string = '';
  accessToken: string = '';
  expiresAtSeconds: number = 0;
}

export class VertexAccessToken {
  projectId: string = '';
  accessToken: string = '';
}

export class VertexAiAuthService {
  private http: RemoteHttpClient = new RemoteHttpClient();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();
  private cache: Record<string, VertexAccessTokenCacheEntry> = {};

  async getServiceAccountAccessToken(serviceAccountJson: string): Promise<VertexAccessToken> {
    const trimmed = serviceAccountJson.trim();
    if (trimmed.length === 0) {
      throw new Error('Google Vertex AI service account JSON is missing.');
    }
    const serviceAccount = this.parseServiceAccount(trimmed);
    const cacheKey = this.sha256Hex(trimmed);
    const nowSeconds = this.currentSeconds();
    const cached = this.cache[cacheKey];
    if (cached !== undefined && cached.accessToken.length > 0 &&
      cached.expiresAtSeconds - TOKEN_REFRESH_SKEW_SECONDS > nowSeconds) {
      const token = new VertexAccessToken();
      token.projectId = cached.projectId;
      token.accessToken = cached.accessToken;
      return token;
    }

    const assertion = this.createJwtAssertion(serviceAccount, nowSeconds);
    const body = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}` +
      `&assertion=${encodeURIComponent(assertion)}`;
    const result = await this.http.postText(GOOGLE_OAUTH_TOKEN_URL, body, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    }, 30000);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw new Error(`Vertex AI service account access token request failed: HTTP ${result.statusCode} ${result.text}`);
    }
    const parsed = parseJsonRecord(result.text);
    const accessToken = asStringValue(parsed['access_token']).trim();
    if (accessToken.length === 0) {
      throw new Error('Vertex AI access token response is missing access_token.');
    }
    const expiresIn = Math.max(60, asNumberValue(parsed['expires_in'], 3600));
    const cachedNext = new VertexAccessTokenCacheEntry();
    cachedNext.projectId = serviceAccount.projectId;
    cachedNext.accessToken = accessToken;
    cachedNext.expiresAtSeconds = nowSeconds + expiresIn;
    this.cache[cacheKey] = cachedNext;

    const token = new VertexAccessToken();
    token.projectId = serviceAccount.projectId;
    token.accessToken = accessToken;
    return token;
  }

  private parseServiceAccount(text: string): VertexServiceAccount {
    let parsed: JsonRecord;
    try {
      const value = JSON.parse(text) as Object;
      if (value === null || Array.isArray(value) || typeof value !== 'object') {
        throw new Error('not an object');
      }
      parsed = value as JsonRecord;
    } catch (err) {
      throw new Error(`Vertex AI service account JSON parse failed: ${err instanceof Error ? err.message : JSON.stringify(err)}`);
    }
    const serviceAccount = new VertexServiceAccount();
    serviceAccount.clientEmail = asStringValue(parsed['client_email']).trim();
    serviceAccount.privateKey = asStringValue(parsed['private_key']);
    serviceAccount.privateKeyId = asStringValue(parsed['private_key_id']).trim();
    serviceAccount.projectId = asStringValue(parsed['project_id']).trim();
    if (serviceAccount.projectId.length === 0) {
      throw new Error('Vertex AI service account JSON is missing project_id.');
    }
    if (serviceAccount.clientEmail.length === 0) {
      throw new Error('Vertex AI service account JSON is missing client_email.');
    }
    if (serviceAccount.privateKey.trim().length === 0) {
      throw new Error('Vertex AI service account JSON is missing private_key.');
    }
    return serviceAccount;
  }

  private createJwtAssertion(serviceAccount: VertexServiceAccount, issuedAtSeconds: number): string {
    const header: JsonRecord = {
      'alg': 'RS256',
      'typ': 'JWT',
    };
    if (serviceAccount.privateKeyId.length > 0) {
      header['kid'] = serviceAccount.privateKeyId;
    }
    const claims: JsonRecord = {
      'iss': serviceAccount.clientEmail,
      'scope': CLOUD_PLATFORM_SCOPE,
      'aud': GOOGLE_OAUTH_TOKEN_URL,
      'iat': issuedAtSeconds,
      'exp': issuedAtSeconds + 3600,
    };
    const signingInput = `${this.base64UrlJson(header)}.${this.base64UrlJson(claims)}`;
    const signature = this.signRsaSha256(serviceAccount.privateKey, signingInput);
    return `${signingInput}.${this.base64UrlBytes(signature)}`;
  }

  private signRsaSha256(privateKeyPem: string, signingInput: string): Uint8Array {
    const algorithms = ['RSA2048', 'RSA4096', 'RSA1024', 'RSA'];
    let lastError = '';
    for (const keyAlgorithm of algorithms) {
      try {
        const keyGenerator = cryptoFramework.createAsyKeyGenerator(keyAlgorithm);
        const keyPair = keyGenerator.convertPemKeySync(null, privateKeyPem);
        const signAlgorithm = keyAlgorithm === 'RSA' ? 'RSA|PKCS1|SHA256' : `${keyAlgorithm}|PKCS1|SHA256`;
        const signer = cryptoFramework.createSign(signAlgorithm);
        signer.initSync(keyPair.priKey);
        const signature = signer.signSync({ data: this.encoder.encodeInto(signingInput) });
        return signature.data;
      } catch (err) {
        lastError = err instanceof Error ? err.message : JSON.stringify(err);
      }
    }
    throw new Error(`Vertex AI service account JWT signing failed: ${lastError}`);
  }

  private base64UrlJson(value: Object): string {
    return this.base64UrlBytes(this.encoder.encodeInto(JSON.stringify(value)));
  }

  private base64UrlBytes(bytes: Uint8Array): string {
    let encoded = this.base64.encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE);
    while (encoded.endsWith('=')) {
      encoded = encoded.slice(0, encoded.length - 1);
    }
    return encoded;
  }

  private sha256Hex(text: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: this.encoder.encodeInto(text) });
    return this.hex(md.digestSync().data);
  }

  private hex(bytes: Uint8Array): string {
    const table = '0123456789abcdef';
    let out = '';
    for (let index = 0; index < bytes.length; index += 1) {
      const byte = bytes[index];
      out += table.charAt((byte >> 4) & 0x0f);
      out += table.charAt(byte & 0x0f);
    }
    return out;
  }

  private currentSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }
}
