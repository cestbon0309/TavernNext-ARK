import { FileStore } from './FileStore';
import { emptyJsonRecord, JsonRecord } from './HttpTypes';
import { PngCardStore } from './PngCardStore';

@Concurrent
export function writePngCardFavorite(path: string, favorite: boolean): boolean {
  const cardStore = new PngCardStore(new FileStore());
  const card = cardStore.readCard(path);
  if (card === null) {
    return false;
  }

  const dataValue = card['data'];
  const data = dataValue !== null && typeof dataValue === 'object' && !Array.isArray(dataValue) ?
    dataValue as JsonRecord : emptyJsonRecord();
  const extensionsValue = data['extensions'];
  const extensions = extensionsValue !== null && typeof extensionsValue === 'object' &&
    !Array.isArray(extensionsValue) ? extensionsValue as JsonRecord : emptyJsonRecord();
  extensions['fav'] = favorite;
  data['extensions'] = extensions;
  card['fav'] = favorite;
  card['data'] = data;
  return cardStore.writeCard(path, card);
}
