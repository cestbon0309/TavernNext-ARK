export function joinPath(...parts: string[]): string {
  const normalized: string[] = [];
  for (const part of parts) {
    const splitParts = part.replace(/\\/g, '/').split('/');
    for (const segment of splitParts) {
      if (segment.length === 0 || segment === '.') {
        continue;
      }
      normalized.push(segment);
    }
  }

  if (parts.length > 0 && parts[0].startsWith('/')) {
    return `/${normalized.join('/')}`;
  }
  return normalized.join('/');
}

export function sanitizeFileName(input: string): string {
  const illegalPattern = /[<>:"/\\|?*\u0000-\u001f]/g;
  const sanitized = input.replace(illegalPattern, '_').trim();
  if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
    return 'unnamed';
  }
  return sanitized;
}

export function withoutExtension(name: string): string {
  const slashIndex = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
  const baseName = slashIndex >= 0 ? name.slice(slashIndex + 1) : name;
  const dotIndex = baseName.lastIndexOf('.');
  if (dotIndex <= 0) {
    return baseName;
  }
  return baseName.slice(0, dotIndex);
}

export function extensionOf(name: string): string {
  const dotIndex = name.lastIndexOf('.');
  if (dotIndex < 0) {
    return '';
  }
  return name.slice(dotIndex).toLowerCase();
}

export function ensureJsonExtension(name: string): string {
  return name.toLowerCase().endsWith('.json') ? name : `${name}.json`;
}

export function ensureJsonlExtension(name: string): string {
  return name.toLowerCase().endsWith('.jsonl') ? name : `${name}.jsonl`;
}

export function ensurePngExtension(name: string): string {
  return name.toLowerCase().endsWith('.png') ? name : `${name}.png`;
}
