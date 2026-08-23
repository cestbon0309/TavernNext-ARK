import { image } from '@kit.ImageKit';
import { FileStore } from './FileStore';

@Concurrent
export async function generateCharacterThumbnail(sourcePath: string, targetPath: string, size: number,
  quality: number): Promise<boolean> {
  const store = new FileStore();
  const bytes = store.readBytes(sourcePath);
  if (bytes === null || bytes.byteLength === 0) {
    return false;
  }

  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  const source = image.createImageSource(buffer);
  let pixelMap: image.PixelMap | null = null;
  try {
    const sourceInfo = await source.getImageInfo();
    const sourceWidth = Math.max(1, Number(sourceInfo.size.width));
    const sourceHeight = Math.max(1, Number(sourceInfo.size.height));
    const desiredWidth = sourceWidth >= sourceHeight ? Math.max(size, Math.round(size * sourceWidth / sourceHeight)) : size;
    const desiredHeight = sourceHeight >= sourceWidth ? Math.max(size, Math.round(size * sourceHeight / sourceWidth)) : size;
    pixelMap = await source.createPixelMap({
      desiredSize: {
        width: desiredWidth,
        height: desiredHeight,
      },
    });
  } catch (_err) {
    return false;
  } finally {
    await source.release();
  }

  if (pixelMap === null) {
    return false;
  }
  try {
    let current = await pixelMap.getImageInfo();
    let width = Number(current.size.width);
    let height = Number(current.size.height);
    if (width < size || height < size) {
      const scale = Math.max(size / Math.max(1, width), size / Math.max(1, height)) + 0.0001;
      await pixelMap.scale(scale, scale);
      current = await pixelMap.getImageInfo();
      width = Number(current.size.width);
      height = Number(current.size.height);
    }
    await pixelMap.crop({
      x: Math.max(0, Math.floor((width - size) / 2)),
      y: Math.max(0, Math.floor((height - size) / 2)),
      size: {
        width: Math.min(size, width),
        height: Math.min(size, height),
      },
    });

    const packer = image.createImagePacker();
    try {
      const packed = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality,
      });
      const output = new Uint8Array(packed);
      if (output.byteLength === 0) {
        return false;
      }
      store.writeBytes(targetPath, output);
      return store.exists(targetPath);
    } finally {
      await packer.release();
    }
  } catch (_err) {
    return false;
  } finally {
    await pixelMap.release();
  }
}
