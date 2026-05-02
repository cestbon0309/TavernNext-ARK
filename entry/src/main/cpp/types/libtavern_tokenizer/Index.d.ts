export interface TokenizerEncodeResult {
  ids: number[];
  count: number;
}

export declare function getNativeVersion(): string;
export declare function resolveModel(model: string): string;
export declare function encode(model: string, text: string): TokenizerEncodeResult;
export declare function decode(model: string, ids: number[]): string;
export declare function count(model: string, text: string): number;
