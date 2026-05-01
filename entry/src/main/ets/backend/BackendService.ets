import { Context } from '@kit.AbilityKit';
import { DataDirectories } from './DataDirectories';
import { FileStore } from './FileStore';
import { HttpServer } from './HttpServer';
import { SillyTavernCore } from './SillyTavernCore';
import { StaticFileServer } from './StaticFileServer';

export class BackendStatus {
  running: boolean;
  url: string;
  dataRoot: string;
  message: string;

  constructor(running: boolean, url: string, dataRoot: string, message: string) {
    this.running = running;
    this.url = url;
    this.dataRoot = dataRoot;
    this.message = message;
  }
}

export class BackendService {
  private static instance: BackendService | null = null;
  private server: HttpServer;
  private directories: DataDirectories;
  private store: FileStore;
  private core: SillyTavernCore;
  private staticFiles: StaticFileServer;
  private lastMessage: string = 'Not started';

  private constructor(context: Context) {
    this.store = new FileStore();
    this.directories = new DataDirectories(context.filesDir, this.store);
    this.directories.initialize();
    this.core = new SillyTavernCore(this.store, this.directories);
    this.staticFiles = new StaticFileServer(context.resourceManager);
    this.server = new HttpServer('127.0.0.1', 8000);
    this.registerRoutes();
  }

  static getInstance(context: Context): BackendService {
    if (BackendService.instance === null) {
      BackendService.instance = new BackendService(context);
    }
    return BackendService.instance;
  }

  async start(): Promise<BackendStatus> {
    try {
      await this.server.start();
      this.lastMessage = 'ArkTS backend is listening.';
    } catch (err) {
      this.lastMessage = `Failed to start backend: ${JSON.stringify(err)}`;
    }
    return this.status();
  }

  async stop(): Promise<BackendStatus> {
    await this.server.stop();
    this.lastMessage = 'ArkTS backend stopped.';
    return this.status();
  }

  status(): BackendStatus {
    return new BackendStatus(this.server.isListening(), `http://${this.server.host}:${this.server.port}`,
      this.directories.dataRoot, this.lastMessage);
  }

  private registerRoutes(): void {
    this.server.route('GET', '/', async (request) => this.staticFiles.serve(request));
    this.server.route('GET', '/health', async () => this.core.health());
    this.server.route('GET', '/csrf-token', async () => this.core.csrfToken());
    this.server.route('GET', '/version', async () => this.core.version());
    this.server.route('GET', '/thumbnail', async (request) => this.core.getDataFile(request));

    this.server.route('POST', '/api/ping', async () => this.core.ping());

    this.server.route('POST', '/api/settings/get', async () => this.core.getSettings());
    this.server.route('POST', '/api/settings/save', async (request) => this.core.saveSettings(request));

    this.server.route('POST', '/api/characters/all', async () => this.core.listCharacters());
    this.server.route('POST', '/api/characters/get', async (request) => this.core.getCharacter(request));
    this.server.route('POST', '/api/characters/create', async (request) => this.core.createCharacter(request));
    this.server.route('POST', '/api/characters/edit', async (request) => this.core.editCharacter(request));
    this.server.route('POST', '/api/characters/delete', async (request) => this.core.deleteCharacter(request));
    this.server.route('POST', '/api/characters/chats', async (request) => this.core.listCharacterChats(request));

    this.server.route('POST', '/api/chats/get', async (request) => this.core.getChat(request));
    this.server.route('POST', '/api/chats/save', async (request) => this.core.saveChat(request));
    this.server.route('POST', '/api/chats/recent', async (request) => this.core.recentChats(request));

    this.server.route('POST', '/api/worldinfo/list', async () => this.core.listWorlds());
    this.server.route('POST', '/api/worldinfo/get', async (request) => this.core.getWorld(request));
    this.server.route('POST', '/api/worldinfo/edit', async (request) => this.core.editWorld(request));
    this.server.route('POST', '/api/worldinfo/delete', async (request) => this.core.deleteWorld(request));

    this.server.route('POST', '/api/groups/all', async () => this.core.listGroups());
    this.server.route('POST', '/api/groups/create', async (request) => this.core.createGroup(request));
    this.server.route('POST', '/api/groups/edit', async (request) => this.core.editGroup(request));
    this.server.route('POST', '/api/groups/delete', async (request) => this.core.deleteGroup(request));

    this.server.route('POST', '/api/backgrounds/all', async () => this.core.listBackgrounds());
    this.server.route('POST', '/api/backgrounds/folders', async () => this.core.listBackgroundFolders());
    this.server.route('POST', '/api/image-metadata/all', async () => this.core.imageMetadataAll());

    this.server.route('POST', '/api/avatars/get', async () => this.core.listAvatars());

    this.server.route('POST', '/api/secrets/settings', async () => this.core.secretsSettings());
    this.server.route('POST', '/api/secrets/read', async () => this.core.readSecretState());
    this.server.route('GET', '/api/extensions/discover', async () => this.core.discoverExtensions());
    this.server.route('POST', '/api/extensions/discover', async () => this.core.discoverExtensions());

    this.server.route('POST', '/api/tokenizers/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/gpt2/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/openai/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/llama/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/mistral/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/yi/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/llama3/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/gemma/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/jamba/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/qwen2/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/tokenizers/command-r/encode', async (request) => this.core.tokenEstimate(request));
    this.server.route('POST', '/api/vector/query', async () => this.core.notImplemented('Vector index'));
    this.server.route('POST', '/api/backends/chat-completions/generate', async () => this.core.notImplemented('Model proxy'));
    this.server.route('POST', '/api/openai/generate', async () => this.core.notImplemented('OpenAI proxy'));

    this.server.fallback(async (request) => {
      if (request.path.startsWith('/characters/') || request.path.startsWith('/User Avatars/') ||
        request.path.startsWith('/backgrounds/')) {
        return this.core.getDataFile(request);
      }
      return this.staticFiles.serve(request);
    });
  }
}
