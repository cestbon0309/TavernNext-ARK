import { FileStore } from './FileStore';
import { emptyJsonRecord, JsonRecord } from './HttpTypes';
import { joinPath } from './PathUtils';

export class UserDirectories {
  root: string;
  thumbnails: string;
  thumbnailsBg: string;
  thumbnailsAvatar: string;
  thumbnailsPersona: string;
  worlds: string;
  user: string;
  avatars: string;
  userImages: string;
  characters: string;
  chats: string;
  groupChats: string;
  groups: string;
  backgrounds: string;
  novelAISettings: string;
  koboldAISettings: string;
  openAISettings: string;
  textGenSettings: string;
  themes: string;
  movingUI: string;
  extensions: string;
  instruct: string;
  context: string;
  quickreplies: string;
  assets: string;
  comfyWorkflows: string;
  files: string;
  vectors: string;
  backups: string;
  sysprompt: string;
  reasoning: string;

  constructor(dataRoot: string, handle: string) {
    this.root = joinPath(dataRoot, handle);
    this.thumbnails = joinPath(this.root, 'thumbnails');
    this.thumbnailsBg = joinPath(this.root, 'thumbnails', 'bg');
    this.thumbnailsAvatar = joinPath(this.root, 'thumbnails', 'avatar');
    this.thumbnailsPersona = joinPath(this.root, 'thumbnails', 'persona');
    this.worlds = joinPath(this.root, 'worlds');
    this.user = joinPath(this.root, 'user');
    this.avatars = joinPath(this.root, 'User Avatars');
    this.userImages = joinPath(this.root, 'user', 'images');
    this.characters = joinPath(this.root, 'characters');
    this.chats = joinPath(this.root, 'chats');
    this.groupChats = joinPath(this.root, 'group chats');
    this.groups = joinPath(this.root, 'groups');
    this.backgrounds = joinPath(this.root, 'backgrounds');
    this.novelAISettings = joinPath(this.root, 'NovelAI Settings');
    this.koboldAISettings = joinPath(this.root, 'KoboldAI Settings');
    this.openAISettings = joinPath(this.root, 'OpenAI Settings');
    this.textGenSettings = joinPath(this.root, 'TextGen Settings');
    this.themes = joinPath(this.root, 'themes');
    this.movingUI = joinPath(this.root, 'movingUI');
    this.extensions = joinPath(this.root, 'extensions');
    this.instruct = joinPath(this.root, 'instruct');
    this.context = joinPath(this.root, 'context');
    this.quickreplies = joinPath(this.root, 'QuickReplies');
    this.assets = joinPath(this.root, 'assets');
    this.comfyWorkflows = joinPath(this.root, 'user', 'workflows');
    this.files = joinPath(this.root, 'user', 'files');
    this.vectors = joinPath(this.root, 'vectors');
    this.backups = joinPath(this.root, 'backups');
    this.sysprompt = joinPath(this.root, 'sysprompt');
    this.reasoning = joinPath(this.root, 'reasoning');
  }
}

export class DataDirectories {
  dataRoot: string;
  uploadRoot: string;
  storageRoot: string;
  cacheRoot: string;
  characterCacheRoot: string;
  defaultUser: UserDirectories;
  private store: FileStore;

  constructor(filesDir: string, store: FileStore) {
    this.dataRoot = joinPath(filesDir, 'data');
    this.uploadRoot = joinPath(this.dataRoot, '_uploads');
    this.storageRoot = joinPath(this.dataRoot, '_storage');
    this.cacheRoot = joinPath(this.dataRoot, '_cache');
    this.characterCacheRoot = joinPath(this.cacheRoot, 'characters');
    this.defaultUser = new UserDirectories(this.dataRoot, 'default-user');
    this.store = store;
  }

  initialize(): void {
    this.store.ensureDir(this.dataRoot);
    this.store.ensureDir(this.uploadRoot);
    this.store.ensureDir(this.storageRoot);
    this.store.ensureDir(this.cacheRoot);
    this.store.ensureDir(this.characterCacheRoot);
    this.ensureUserDirectories(this.defaultUser);
    this.ensureRootFile('cookie-secret.txt', this.generateCookieSecret());

    const settingsPath = joinPath(this.defaultUser.root, 'settings.json');
    if (!this.store.exists(settingsPath)) {
      this.store.writeJson(settingsPath, emptyJsonRecord());
    }

    const secretsPath = joinPath(this.defaultUser.root, 'secrets.json');
    if (!this.store.exists(secretsPath)) {
      this.store.writeJson(secretsPath, emptyJsonRecord());
    }

    const statsPath = joinPath(this.defaultUser.root, 'stats.json');
    if (!this.store.exists(statsPath)) {
      this.store.writeJson(statsPath, emptyJsonRecord());
    }

    this.ensureUserFile('content.log', '');
    this.ensureUserFile('image-metadata.json', '{}');
  }

  private ensureUserDirectories(dirs: UserDirectories): void {
    this.store.ensureDir(dirs.root);
    this.store.ensureDir(dirs.thumbnails);
    this.store.ensureDir(dirs.thumbnailsBg);
    this.store.ensureDir(dirs.thumbnailsAvatar);
    this.store.ensureDir(dirs.thumbnailsPersona);
    this.store.ensureDir(dirs.worlds);
    this.store.ensureDir(dirs.user);
    this.store.ensureDir(dirs.avatars);
    this.store.ensureDir(dirs.userImages);
    this.store.ensureDir(dirs.characters);
    this.store.ensureDir(dirs.chats);
    this.store.ensureDir(dirs.groupChats);
    this.store.ensureDir(dirs.groups);
    this.store.ensureDir(dirs.backgrounds);
    this.store.ensureDir(dirs.novelAISettings);
    this.store.ensureDir(dirs.koboldAISettings);
    this.store.ensureDir(dirs.openAISettings);
    this.store.ensureDir(dirs.textGenSettings);
    this.store.ensureDir(dirs.themes);
    this.store.ensureDir(dirs.movingUI);
    this.store.ensureDir(dirs.extensions);
    this.store.ensureDir(dirs.instruct);
    this.store.ensureDir(dirs.context);
    this.store.ensureDir(dirs.quickreplies);
    this.store.ensureDir(dirs.assets);
    this.store.ensureDir(dirs.comfyWorkflows);
    this.store.ensureDir(dirs.files);
    this.store.ensureDir(dirs.vectors);
    this.store.ensureDir(dirs.backups);
    this.store.ensureDir(dirs.sysprompt);
    this.store.ensureDir(dirs.reasoning);
    this.store.ensureDir(joinPath(dirs.assets, 'bgm'));
    this.store.ensureDir(joinPath(dirs.assets, 'ambient'));
    this.store.ensureDir(joinPath(dirs.assets, 'blip'));
    this.store.ensureDir(joinPath(dirs.assets, 'live2d'));
    this.store.ensureDir(joinPath(dirs.assets, 'vrm'));
    this.store.ensureDir(joinPath(dirs.assets, 'character'));
    this.store.ensureDir(joinPath(dirs.assets, 'temp'));
  }

  private ensureRootFile(name: string, content: string): void {
    const path = joinPath(this.dataRoot, name);
    if (!this.store.exists(path)) {
      this.store.writeText(path, content);
    }
  }

  private ensureUserFile(name: string, content: string): void {
    const path = joinPath(this.defaultUser.root, name);
    if (!this.store.exists(path)) {
      this.store.writeText(path, content);
    }
  }

  private generateCookieSecret(): string {
    return `${Date.now()}-${Math.round(Math.random() * 1000000000)}`;
  }
}
