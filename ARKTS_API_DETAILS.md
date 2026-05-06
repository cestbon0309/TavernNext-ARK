# TavernNext ArkTS 接口细节

本文档描述 `tavernnext-ohos` 当前 ArkTS 后端的实际接口行为。它不是 SillyTavern Node.js 后端的完整替代说明，而是截至当前工程状态已经实现、已经占位、以及需要保持兼容的数据约定。

## 最新状态快照（2026-05-03）

当前工程已经完成本地数据兼容和 OpenAI chat-completions 最小可用链路，仍不是完整 SillyTavern Node.js 后端替代。

已完成并验证：
- WebView 加载 `http://127.0.0.1:8000`，rawfile 前端静态资源可用。
- 首次启动按原版默认内容初始化 `data/default-user/`，只在 `content.log` 为空时执行一次。
- settings、角色、聊天、群聊、世界书、groups、QuickReplies、secrets、users、extensions、data zip 导出/恢复、媒体上传等本地 API 已覆盖主要前端流程。
- 媒体相关处理已尽量使用 Harmony 官方 API：图片尺寸/裁剪/缩略图/平均色使用 `ImageKit`，zip 压缩/解压使用 `zlib`。
- data 恢复的前端入口已切换为后端唤起 Harmony 文件选择器，避免 50MB 级 zip 先从 WebView 上传到 ArkTS HTTP 后端再落盘；HTTP multipart 恢复接口仍保留用于调试。
- 扩展发现和第三方扩展静态资源已兼容导入备份里的 `extensions/third-party/<name>`、`public/scripts/extensions/third-party/<name>` 等结构；`/version` 返回 SillyTavern 兼容 agent 以满足第三方扩展版本门槛。
- 第三方扩展 Git 第一阶段已接入 native `.so` + `libgit2`：目标收敛为兼容 GitHub、GitLab、Gitee、Bitbucket 等常见 Git 托管平台的公开 HTTPS 仓库，支持安装、版本状态、分支列表、分支切换和 fast-forward 更新。
- OpenAI chat-completions 支持 `openai` 和 `custom` 来源，支持 `/models` 状态检查、`/chat/completions` 非流式生成和流式 SSE 生成。
- 流式生成已改为 Harmony `requestInStream()` + `dataReceive` 转发，并通过虚拟机、hdc 端口映射、慢速 mock OpenAI 服务确认分块即时到达。
- Tokenizer 已接入 native `.so` + Rust `miktik`：SillyTavern 本地 tokenizer 路由已走真实 encode/decode/count，覆盖 OpenAI/tiktoken、GPT-2、旧 OpenAI text/embedding 模型、Claude、DeepSeek、Gemma、Llama/Llama 3、Mistral、Yi、Jamba、Nerdstash/Nerdstash v2、Qwen2、Command-R/Command-A 和 Nemo；`/api/tokenizers/openai/count` 会按原版模型分支进行 OpenAI chat overhead、Claude-style prompt 或 SentencePiece flatten 计数。
- 管理类接口本轮已补：世界书 multipart 导入、settings snapshots、presets save/delete/restore、themes save/delete、moving UI save、assets 管理、content importURL/importUUID、聊天备份读/下载/删除，以及 LLM API logs 的 keep 配置、SSE 订阅和前端查看面板。

明确暂缓或仍不完善：
- 多用户明确暂缓：当前 App 形态不需要多用户运行模型，后端固定使用 `data/default-user/`；`/api/users/*` 只保留为本地账号弹窗、密码校验和备份恢复的兼容层，不启用真实 session、cookie-session、当前用户切换和权限中间件。
- 模型 provider 仍不完整：OpenAI/OpenAI-compatible `openai` 和 `custom` 主路径已可用；text-completions、NovelAI、Horde、Stable Diffusion 等已有基础代理或查询路由，但还没有完整对齐原版 provider 行为、错误格式、请求取消和流式转换。
- Tokenizer 本地路由已基本补齐：剩余风险主要是特殊 token、异常 token id、chunks 展示和包体积等边界细节；不再使用 byte 估算承担这些模型的主路径计数。
- Vector 已有可用实现：支持本地 JSON 索引、insert/list/delete/query/query-multi/purge、批量 remote embedding provider 调用和 hash fallback；已对齐 OpenAI-compatible、Cohere、Ollama、Extras、NomicAI、Google/MakerSuite、Vertex 等常用 embedding 请求/响应形状，但尚未对齐原版 `vectra.LocalIndex` 的完整行为和性能。
- Git 能力边界：当前只要求覆盖常见公开 HTTPS 仓库的插件安装/更新流程；私有仓库认证、SSH、submodule、非 fast-forward merge 冲突处理、hooks 执行仍暂缓。
- 管理类接口剩余差异：聊天备份目前每次保存都会写入并按单聊天前缀保留 50 条，尚未实现原版节流/全局最大数量/完整 integrity slug 校验；content import 的通用下载域名仍是内置白名单而非 config 驱动；data-maid、master import/export 和 Comfy workflow save/delete/rename 仍未完成。

代码入口：

- `entry/src/main/ets/backend/BackendService.ets`：后端生命周期和路由注册。
- `entry/src/main/ets/backend/HttpServer.ets`：轻量 HTTP/1.1 TCP 服务。
- `entry/src/main/ets/backend/SillyTavernCore.ets`：SillyTavern 兼容 API。
- `entry/src/main/ets/backend/DataDirectories.ets`：运行时 `data/` 目录初始化。
- `entry/src/main/ets/backend/PngCardStore.ets`：PNG 角色卡元数据读写。
- `entry/src/main/ets/backend/StaticFileServer.ets`：rawfile 静态前端资源服务。

## 1. 运行模型

应用启动后，`Index.ets` 获取 `UIAbilityContext`，创建 `BackendService` 单例，并启动本地 HTTP 服务：

```text
http://127.0.0.1:8000
```

前端通过 OHOS `Web` 组件加载这个地址。当前模型仍以本机默认用户数据为主，但已经补入本地账号兼容 API：

- 固定用户目录：`data/default-user/`
- `GET /csrf-token` 固定返回 `{ "token": "disabled" }`
- `enable_accounts` 固定为 `false`
- `SillyTavernCore` 的角色、聊天、设置等核心数据接口仍固定读写 `data/default-user/`
- `/api/users/*` 已实现本地账号 CRUD、密码校验、头像记录和备份等兼容接口；多用户系统明确暂缓，当前不会建立真实 session、cookie-session、当前用户切换和权限中间件

`HttpServer.start()` 已做单飞保护：Ability 和页面重复调用启动时会复用同一个 `startPromise`，避免监听竞态。

## 2. HTTP 通用约定

### 2.1 请求解析

支持：

- `GET`
- `POST`
- `HEAD`，仅静态资源服务显式支持
- `OPTIONS`，统一返回空响应

请求头全部转为小写存储。请求体只有在 `Content-Type` 包含 `application/json` 且 body 非空时才解析 JSON。

JSON 解析失败时返回：

```http
400 Bad Request
```

```json
{
  "error": "bad_request",
  "message": "invalid_json"
}
```

### 2.2 响应头

默认响应头：

```http
content-type: application/json; charset=utf-8
cache-control: no-store
access-control-allow-origin: *
access-control-allow-methods: GET, POST, OPTIONS
access-control-allow-headers: content-type, x-csrf-token
connection: close
```

每个响应都会写入 `content-length`。静态资源根据文件类型覆盖 `content-type` 和缓存策略。

### 2.3 错误格式

通用错误 helper：

```json
{
  "error": "<error>",
  "message": "<optional message>"
}
```

目前部分接口为了贴近 SillyTavern 旧行为，仍会返回空 body 的 `400` 或 `404`。成功操作一般返回：

```json
{ "ok": true }
```

或：

```json
{ "result": "ok" }
```

### 2.4 文件名安全处理

涉及文件名的参数会经过 `sanitizeFileName()`：

- 替换非法字符：`<>:"/\|?*` 和控制字符
- 去掉首尾空白
- 空字符串、`.`、`..` 会变成 `unnamed`

扩展名 helper：

- JSON 文件：`ensureJsonExtension(name)`
- JSONL 聊天文件：`ensureJsonlExtension(name)`
- PNG 角色卡：`ensurePngExtension(name)`

## 3. data 目录结构

运行时数据根目录：

```text
<context.filesDir>/data
```

模拟器当前实测示例：

```text
/data/storage/el2/base/haps/entry/files/data
```

初始化时创建：

```text
data/
  cookie-secret.txt
  _uploads/
  _storage/
  _cache/
    characters/
  default-user/
    settings.json
    secrets.json
    stats.json
    content.log
    image-metadata.json
    thumbnails/
      bg/
      avatar/
      persona/
    worlds/
    user/
      images/
      files/
      workflows/
    User Avatars/
    characters/
    chats/
    group chats/
    groups/
    backgrounds/
    NovelAI Settings/
    KoboldAI Settings/
    OpenAI Settings/
    TextGen Settings/
    themes/
    movingUI/
    extensions/
    instruct/
    context/
    QuickReplies/
    assets/
      bgm/
      ambient/
      blip/
      live2d/
      vrm/
      character/
      temp/
    vectors/
    backups/
    sysprompt/
    reasoning/
```

初始化默认文件：

- `data/cookie-secret.txt`：随机文本，格式为 `<Date.now()>-<random number>`。
- 首次启动会先从 `entry/src/main/resources/rawfile/default/content/index.json` 读取原版默认内容清单，并把 `default/content` 中的默认 `settings.json`、背景、Seraphina、Eldoria、头像、主题、预设、QuickReplies、Comfy workflow 等复制到 `data/default-user` 对应目录。
- 默认内容导入复用原版 `content.log` 语义：`content.log` 为空时执行一次初始化；写入已处理 filename 后，后续启动直接跳过。目标文件已存在时不覆盖，只记录该 filename。
- `data/default-user/settings.json`：默认内容导入后仍不存在时写 `{}` 兜底。
- `data/default-user/secrets.json`：不存在时写 `{}`。
- `data/default-user/stats.json`：不存在时写 `{}`。
- `data/default-user/content.log`：不存在时写空字符串。
- `data/default-user/image-metadata.json`：不存在时写 `{}`。

必须保持这些目录名大小写和空格与 SillyTavern 一致，例如 `User Avatars`、`group chats`、`NovelAI Settings`。

铁律：`<context.filesDir>/data` 只保存 SillyTavern 原版会保存的数据结构和文件。OHOS 适配产生的临时导出、分享中转文件、系统交互状态不能写入 `data/default-user`，也不能在其中新增非原版目录。当前导出文件统一写入：

```text
<context.filesDir>/exports/
  characters/
  chats/
  users/
```

这个 `exports/` 是应用私有目录，专门用于 ShareKit 分享中转，不属于 SillyTavern `data/` 兼容结构。

当前 data 恢复流程的上传 zip、解压目录和旧数据临时备份统一写入：

```text
<context.filesDir>/_restore/
```

这个 `_restore/` 同样是应用私有临时目录，不属于 SillyTavern `data/` 兼容结构。恢复成功后会清理本次临时目录和旧数据临时备份；恢复失败时会尽量回滚当前 `data/`。

## 4. 静态资源接口

### 4.1 `GET /`

返回 rawfile 中的：

```text
entry/src/main/resources/rawfile/public/index.html
```

`HEAD /` 也由静态资源服务支持，但当前路由表只显式注册了 `GET /`，其他静态路径通过 fallback 进入。

### 4.2 `GET /<public path>`

未命中 API 路由且不是数据文件路径时，fallback 会从 rawfile 读取：

```text
public/<request path without leading slash>
```

路径处理：

- 去掉 query 和 hash
- `decodeURIComponent`
- 反斜杠转 `/`
- 包含空字符或 `..` 时返回 `404`

常见 content type：

- `.html`：`text/html; charset=utf-8`
- `.js` / `.mjs`：`text/javascript; charset=utf-8`
- `.css`：`text/css; charset=utf-8`
- `.json` / `.map` / `.webmanifest`：`application/json; charset=utf-8`
- `.png`：`image/png`
- `.jpg` / `.jpeg`：`image/jpeg`
- `.gif`：`image/gif`
- `.svg`：`image/svg+xml`
- `.webp`：`image/webp`
- `.ico`：`image/x-icon`
- `.woff`：`font/woff`
- `.woff2`：`font/woff2`
- `.ttf`：`font/ttf`
- `.otf`：`font/otf`
- `.wasm`：`application/wasm`
- `.mp3`：`audio/mpeg`
- `.wav`：`audio/wav`
- `.ogg`：`audio/ogg`

缓存策略：

- `.html`：`no-cache`
- 其他静态资源：`public, max-age=3600`

注意：当前 `rawfile/public/lib.js` 必须是 SillyTavern webpack 构建产物，不应替换为 SillyTavern 源码中的 `public/lib.js`。

## 5. 基础接口

### 5.1 `GET /health`

用途：后端健康检查。

响应：

```json
{
  "ok": true,
  "app": "TavernNext OHOS ArkTS backend",
  "compatibility": "SillyTavern minimal local-data API",
  "dataRoot": "/data/storage/el2/base/haps/entry/files/data"
}
```

`dataRoot` 为运行时实际路径。

### 5.2 `GET /csrf-token`

用途：满足 SillyTavern 前端初始化流程。

响应：

```json
{
  "token": "disabled"
}
```

当前不校验 `x-csrf-token`。

### 5.3 `GET /version`

响应：

```json
{
  "agent": "SillyTavern:1.17.0:TavernNext-OHOS",
  "pkgVersion": "1.2.0-ohos",
  "gitRevision": "",
  "gitBranch": "arkts-port",
  "commitDate": "",
  "isLatest": true
}
```

### 5.4 `POST /api/ping`

用途：前端 keepalive / 连通性检查。

当前响应：

```json
{
  "ok": true
}
```

原 SillyTavern Node.js 返回 `204`；这里改为 JSON 是为了避免 OHOS 端口转发链路下部分客户端把空响应识别为 `Empty reply from server`。

## 6. 设置接口

### 6.1 `POST /api/settings/get`

读取 `data/default-user/settings.json`，并聚合预设、世界书名称、主题等目录内容。

响应字段：

```ts
type SettingsResponse = {
  settings: string;
  koboldai_settings: string[];
  koboldai_setting_names: string[];
  novelai_settings: string[];
  novelai_setting_names: string[];
  openai_settings: string[];
  openai_setting_names: string[];
  textgenerationwebui_presets: string[];
  textgenerationwebui_preset_names: string[];
  world_names: string[];
  themes: object[];
  movingUIPresets: object[];
  quickReplyPresets: object[];
  instruct: object[];
  context: object[];
  sysprompt: object[];
  reasoning: object[];
  enable_extensions: true;
  enable_extensions_auto_update: false;
  enable_accounts: false;
  request_compression: {
    enabled: false;
    minPayloadSize: 262144;
    maxPayloadSize: 8388608;
    timeout: 3000;
  };
};
```

目录映射：

- `settings`：读取 `default-user/settings.json` 的原始文本，默认 `'{}'`。
- `koboldai_settings` / `koboldai_setting_names`：`KoboldAI Settings/*.json`
- `novelai_settings` / `novelai_setting_names`：`NovelAI Settings/*.json`
- `openai_settings` / `openai_setting_names`：`OpenAI Settings/*.json`
- `textgenerationwebui_presets` / `textgenerationwebui_preset_names`：`TextGen Settings/*.json`
- `world_names`：`worlds/*.json` 去扩展名。
- `themes`：`themes/*.json` 解析为对象数组。
- `movingUIPresets`：`movingUI/*.json`
- `quickReplyPresets`：`QuickReplies/*.json`
- `instruct`：`instruct/*.json`
- `context`：`context/*.json`
- `sysprompt`：`sysprompt/*.json`
- `reasoning`：`reasoning/*.json`

兼容点：`koboldai_settings`、`novelai_settings`、`openai_settings` 和 `textgenerationwebui_presets` 与原版一致返回 JSON 文件原文字符串数组，前端会自行 `JSON.parse(item)`。主题、moving UI、Quick Reply、instruct、context、sysprompt、reasoning 仍返回解析后的对象数组。

### 6.2 `POST /api/settings/save`

请求 body：任意 JSON 对象。

行为：

- body 为空时返回 `400`：

```json
{
  "error": "body must be JSON"
}
```

- body 非空时写入：

```text
data/default-user/settings.json
```

响应：

```json
{
  "result": "ok"
}
```

## 7. 角色接口

角色文件存储在：

```text
data/default-user/characters/<internal-name>.png
```

角色聊天目录为：

```text
data/default-user/chats/<internal-name>/
```

### 7.1 PNG 角色卡格式

`PngCardStore` 读写 SillyTavern 兼容 PNG 元数据：

- PNG 必须有标准签名。
- 读取时扫描 `tEXt` chunk。
- 优先读取关键字 `ccv3`，不存在时读取 `chara`。
- `ccv3` / `chara` 的值为 base64 编码的 UTF-8 JSON。
- 写入时会删除已有 `chara` 和 `ccv3` 文本块，再在 `IEND` 前插入新的 `tEXt` chunk。
- 新建角色没有现有图片时使用内置 1x1 PNG 透明占位图。
- 当前写入关键字为 `chara`。
- 支持从内存 PNG bytes 读取角色卡，也支持以用户上传 PNG 为底图重写角色元数据；这用于 `characters/import` 的 PNG 导入、`characters/export` 的 PNG 私有导出，以及 `characters/edit-avatar` 的基础头像替换。

### 7.2 角色响应结构

```ts
type CharacterResponse = {
  shallow: boolean;
  name: string;
  avatar: string;
  chat: string;
  fav: boolean;
  date_added: number;
  create_date: string;
  date_last_chat: number;
  chat_size: number;
  data_size: number;
  tags: unknown[];
  data: object;
  json_data: string;
  spec: string;
  spec_version: string;
  description: string;
  personality: string;
  scenario: string;
  first_mes: string;
  mes_example: string;
};
```

`shallow=true` 时仅返回浅层 `data`：

```json
{
  "name": "...",
  "character_version": "...",
  "creator": "...",
  "creator_notes": "...",
  "tags": [],
  "extensions": {
    "fav": false,
    "world": ""
  }
}
```

`shallow=false` 时返回完整 `data`、`json_data`、`spec`、`spec_version` 和描述字段。

### 7.3 `POST /api/characters/all`

行为：

- 扫描 `characters/*.png`。
- 读取 PNG 中的角色 JSON。
- 读不出元数据的 PNG 会被跳过。
- 返回浅层角色数组。

响应：

```json
[
  {
    "shallow": true,
    "name": "Assistant",
    "avatar": "Assistant.png",
    "chat": "...",
    "fav": false,
    "date_added": 1777660000000,
    "create_date": "2026-05-02T00:00:00.000Z",
    "date_last_chat": 0,
    "chat_size": 0,
    "data_size": 123,
    "tags": [],
    "data": {}
  }
]
```

### 7.4 `POST /api/characters/get`

请求：

```json
{
  "avatar_url": "Assistant.png"
}
```

行为：

- `avatar_url` 不能为空，否则返回 `400` 空 body。
- 文件名会转为安全名并确保 `.png` 扩展名。
- 文件不存在返回 `404` 空 body。
- PNG 元数据读取失败返回：

```json
{
  "error": "failed_to_read_character"
}
```

成功时返回完整 `CharacterResponse`。

### 7.5 `POST /api/characters/create`

请求字段：

```ts
type CreateCharacterRequest = {
  ch_name?: string;
  file_name?: string;
  json_data?: string;
  description?: string;
  personality?: string;
  scenario?: string;
  first_mes?: string;
  mes_example?: string;
  creator_notes?: string;
  system_prompt?: string;
  post_history_instructions?: string;
  tags?: string[] | string;
  creator?: string;
  character_version?: string;
  alternate_greetings?: unknown[];
  talkativeness?: number | string;
  fav?: boolean | "true";
  world?: string;
  depth_prompt_prompt?: string;
  depth_prompt_depth?: number | string;
  depth_prompt_role?: string;
  chat?: string;
  create_date?: string;
};
```

行为：

- `ch_name` 默认 `New Character`。
- 如果传 `file_name`，内部名使用 `file_name` 去扩展名后的安全文件名。
- 如果不传 `file_name`，使用 `ch_name` 生成唯一文件名，遇到冲突追加数字。
- 如果传 `json_data`，会先解析为卡片基础对象；解析失败则从空对象构造。
- 写入 `characters/<internal-name>.png`。
- 确保 `chats/<internal-name>/` 目录存在。

写入卡片时会构造/覆盖：

```ts
card.spec = "chara_card_v2";
card.spec_version = "2.0";
card.name = ch_name;
card.description = body.description;
card.personality = body.personality;
card.scenario = body.scenario;
card.first_mes = body.first_mes;
card.mes_example = body.mes_example;
card.creatorcomment = body.creator_notes;
card.avatar = "none";
card.chat = body.chat || existingCard.chat || `${name} - ${now}`;
card.talkativeness = Number(body.talkativeness ?? 0.5);
card.fav = body.fav === true || body.fav === "true";
card.tags = tags;
card.create_date = body.create_date || now;
card.data = { ... };
```

`card.data.extensions` 中会写：

```json
{
  "talkativeness": 0.5,
  "fav": false,
  "world": "",
  "depth_prompt": {
    "prompt": "",
    "depth": 4,
    "role": "system"
  }
}
```

成功响应为纯文本文件名：

```text
Assistant.png
```

写入失败：

```http
500 Internal Server Error
```

```json
{
  "error": "failed_to_write_character"
}
```

### 7.6 `POST /api/characters/edit`

请求字段与创建类似，额外需要：

```json
{
  "avatar_url": "Assistant.png"
}
```

行为：

- `avatar_url` 为空返回 `400` 空 body。
- 内部名来自 `avatar_url` 去扩展名。
- 角色显示名取 `ch_name`，其次 `name`，最后内部名。
- 覆盖写入 `characters/<internal-name>.png`。

成功：

```json
{ "ok": true }
```

失败：

```json
{
  "error": "failed_to_write_character"
}
```

### 7.7 `POST /api/characters/duplicate`

请求：

```json
{
  "avatar_url": "Assistant.png"
}
```

行为：

- `avatar_url` 为空返回 `400` 空 body。
- 源文件不存在返回 `404` 空 body。
- 只复制角色 PNG 文件：`data/default-user/characters/<avatar_url>`。
- 不复制 `data/default-user/chats/<internal-name>/`，这与原 SillyTavern 行为一致。
- 新文件名沿用原版 `_数字` 递增策略，例如 `Alice.png` -> `Alice_1.png`，`Alice_1.png` -> `Alice_2.png`。

成功响应：

```json
{
  "path": "Assistant_1.png"
}
```

写入失败时返回：

```json
{ "error": true }
```

### 7.8 `POST /api/characters/rename`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "new_name": "New Assistant"
}
```

行为：

- `avatar_url` 或 `new_name` 为空返回 `400` 空 body。
- 读取旧角色 PNG 的卡片元数据。
- 将卡片顶层 `name` 和 `data.name` 改为清理后的 `new_name`。
- 使用 `new_name` 生成新的唯一内部名，写入：

```text
data/default-user/characters/<new-internal-name>.png
```

- 如果旧聊天目录存在且新聊天目录不存在，会递归复制并删除旧目录：

```text
data/default-user/chats/<old-internal-name>/
data/default-user/chats/<new-internal-name>/
```

- 最后删除旧角色 PNG，并清理旧头像缩略图缓存文件。

成功响应：

```json
{
  "avatar": "New Assistant.png"
}
```

已知差异：如果聊天目录复制失败，当前 ArkTS 版会保留旧聊天目录并继续返回角色重命名结果；后续可以改成更严格的事务式失败回滚。

### 7.9 `POST /api/characters/edit-avatar`

用途：替换角色卡底图，同时保留 PNG 里的角色卡 JSON 元数据。

请求：

```http
POST /api/characters/edit-avatar
Content-Type: multipart/form-data
```

表单字段：

```ts
type CharacterEditAvatarForm = {
  avatar: File;        // 必填，上传字段名必须是 avatar
  avatar_url: string;  // 必填，例如 Assistant.png
};
```

行为：

- 缺少 `avatar_url` 返回 `400` 文本错误。
- 缺少上传文件返回 `400` 文本错误。
- 读取 `characters/<avatar_url>` 中现有角色 JSON。
- 以上传 PNG bytes 作为新底图，重新写入同一个角色卡文件。
- 删除 `thumbnails/avatar/<avatar_url>`，让前端后续重新请求。

成功响应：

```http
200 OK
```

响应 body 为纯文本：

```text
OK
```

当前限制：

- 只做基础 PNG 底图替换，不做图片裁剪、resize、格式转换。
- 原前端裁剪弹窗通常会给出 PNG blob，因此这个路径可覆盖核心使用场景；直接上传 JPEG/WebP 等格式后续需要接入图片解码/转 PNG 能力。

### 7.10 `POST /api/characters/edit-attribute`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "field": "description",
  "value": "new value",
  "ch_name": "Assistant"
}
```

行为：

- `avatar_url` 或 `field` 为空返回 `400`。
- `field=json_data` 返回 `400`。
- 如果传入 `ch_name` 且为空字符串或 `.`，返回 `400`。
- 读取角色卡 JSON，要求 `field` 已存在于顶层或 `data` 中。
- 同时写入顶层字段和 `data[field]`，与原 Node 端行为保持一致。
- 写入成功后清理头像缩略图缓存文件。

成功响应：

```http
200 OK
```

响应 body 为纯文本：

```text
OK
```

### 7.11 `POST /api/characters/merge-attributes`

请求：

```json
{
  "avatar": "Assistant.png",
  "fav": true,
  "data": {
    "extensions": {
      "fav": true,
      "world": "Lorebook"
    }
  }
}
```

行为：

- `avatar` 为空时会退回读取 `avatar_url`；两者都为空返回 `400`。
- 读取 `characters/<avatar>` 中的角色卡 JSON。
- 删除请求和原卡片中的 `json_data` 字段。
- 对对象字段执行递归 deep merge；数组、字符串、数字、布尔和 `null` 直接覆盖。
- 做最小卡片校验：顶层 `name` 或 `data.name` 至少存在一个，`data` 必须是对象。
- 写入同一个角色 PNG，并清理头像缩略图缓存文件。

成功响应：

```http
200 OK
```

响应 body 为纯文本：

```text
OK
```

校验失败：

```json
{
  "message": "Validation failed for Assistant",
  "error": "data must be an object"
}
```

当前说明：原 Node 端使用完整 `TavernCardValidator` 校验 V1/V2 规格；ArkTS 版目前只做最小保护，后续需要补齐完整 Tavern Card 校验。

### 7.12 `POST /api/characters/delete`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "delete_chats": true
}
```

行为：

- `avatar_url` 为空返回 `400` 空 body。
- 删除 `characters/<internal-name>.png`。
- 文件不存在或删除失败返回 `400` 空 body。
- `delete_chats === true` 时递归删除 `chats/<internal-name>/`。

成功：

```json
{ "ok": true }
```

### 7.13 `POST /api/characters/import`

用途：导入角色卡，保持与原 SillyTavern 前端的 multipart 调用兼容。

请求：

```http
POST /api/characters/import
Content-Type: multipart/form-data
```

表单字段：

```ts
type CharacterImportForm = {
  avatar: File;             // 必填，上传字段名必须是 avatar
  file_type: "json" | "png";
  user_name?: string;       // 当前阶段接收但不参与转换
  preserved_name?: string;  // 可选，替换角色时保持原内部文件名
};
```

当前支持：

- `file_type=json`：读取上传文件 UTF-8 文本，兼容 UTF-8 BOM，支持 V2/V3 类角色卡、V1 角色卡、Pygmalion/Gradio notepad，并使用内置 1x1 PNG 透明图作为底图。
- `file_type=png`：读取上传 PNG 的 `tEXt/chara` 或 `tEXt/ccv3` 元数据，并使用上传 PNG 原图作为底图重写角色元数据。

导入时会归一为 `chara_card_v2`，清除 `fav`、`data.extensions.fav` 和 `chat`，刷新 `create_date`，并确保：

```text
data/default-user/characters/<internal-name>.png
data/default-user/chats/<internal-name>/
```

成功响应：

```json
{
  "file_name": "internal-name"
}
```

缺少文件或 `file_type` 返回 `400` 空 body；格式不支持返回 `unsupported_format`；解析失败或无有效角色数据返回：

```json
{ "error": true }
```

当前未支持：`yaml`、`yml`、`charx`、`byaf`，也未导入 Risu sprites、CharX 附带资产、BYAF 附带聊天/背景/图片。

### 7.14 `POST /api/characters/export`

用途：导出角色卡。在 OHOS 中，所有导出先写入应用私有目录，再通过华为官方 ShareKit 唤起系统分享面板，让用户决定保存或发送到哪里。

请求：

```json
{
  "format": "json",
  "avatar_url": "Assistant.png"
}
```

`format` 当前支持 `json` 和 `png`。

行为：

- 读取 `data/default-user/characters/<avatar_url>`。
- 从 PNG 角色卡元数据中读取角色 JSON。
- 导出前归一为 V2 结构，并清除 `fav`、`data.extensions.fav` 和 `chat`。
- `json` 导出写入格式化 JSON。
- `png` 导出使用原 PNG bytes 作为底图，重写安全后的角色元数据。
- 写入私有导出目录，不写入 SillyTavern `data/`：

```text
<context.filesDir>/exports/characters/<internal-name>.json
<context.filesDir>/exports/characters/<internal-name>.png
```

ShareKit 调用：

- 使用 `@kit.ShareKit` 的 `systemShare.SharedData` 和 `systemShare.ShareController`。
- 文件 URI 来自 `@kit.CoreFileKit` 的 `fileUri.getUriFromPath(path)`。
- JSON 使用 UTD `general.plain-text`，PNG 使用 UTD `general.png`。
- 当前使用单选分享模式 `SelectionMode.SINGLE` 和默认预览模式 `SharePreviewMode.DEFAULT`。

成功响应：

```json
{
  "ok": true,
  "shared": true,
  "file_name": "Assistant.json",
  "path": "/data/storage/el2/base/haps/entry/files/exports/characters/Assistant.json",
  "uri": "file://com.esoteric.tavernnext/...",
  "content_type": "application/json"
}
```

如果文件已写入但 ShareKit 未能打开，返回 `500`，响应里仍会带 `path` 和 `uri` 方便调试。

与原 Node 后端差异：原 SillyTavern `/api/characters/export` 直接返回下载流；OHOS 版按系统交互要求改为“私有文件 + ShareKit”。前端 rawfile 中角色导出点击逻辑也已适配为读取 JSON 结果，不再创建 WebView blob 下载。

### 7.15 `POST /api/characters/chats`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "simple": false
}
```

行为：

- `avatar_url` 为空返回 `400` 空 body。
- 读取目录：`chats/<avatar_url without .png>/`
- 目录不存在返回：

```json
{ "error": true }
```

`simple=true` 响应：

```json
[
  {
    "file_name": "chat.jsonl",
    "file_id": "chat"
  }
]
```

默认响应：

```json
[
  {
    "file_name": "chat.jsonl",
    "file_id": "chat",
    "chat_items": 12,
    "mes": "last message text",
    "last_mes": "last message text",
    "file_size": 12345,
    "date_last_chat": 1777660000000
  }
]
```

当前 `chat_items` 是解析出的 JSONL 行数，`mes` 和 `last_mes` 都取最后一条消息的 `mes` 字段。这个与 Node 版 `getChatInfo()` 的 `last_mes=send_date` 仍有差异，后续可对齐。

## 8. 聊天接口

角色聊天存储：

```text
data/default-user/chats/<character internal name>/<file_name>.jsonl
```

JSONL 每行是一个聊天对象。读取时逐行 `JSON.parse`，解析失败的行会跳过。

### 8.1 `POST /api/chats/get`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "file_name": "chat.jsonl"
}
```

行为：

- `avatar_url` 为空返回 `400` 空 body。
- 自动确保 `chats/<internal-name>/` 存在。
- `file_name` 为空时返回 `{}`。
- 文件名自动确保 `.jsonl` 扩展名。
- 文件不存在时返回 `[]`。
- 文件存在时返回 JSON 对象数组。

### 8.2 `POST /api/chats/save`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "file_name": "chat.jsonl",
  "chat": [
    {
      "name": "Assistant",
      "is_user": false,
      "send_date": "2026-05-02T00:00:00.000Z",
      "mes": "Hello"
    }
  ]
}
```

行为：

- `avatar_url`、`file_name` 必须非空。
- `chat` 必须是数组。
- 自动确保 `chats/<internal-name>/` 存在。
- 写入时每个元素 `JSON.stringify(item)`，用 `\n` 拼接为 JSONL。

错误：

```http
400 Bad Request
```

```json
{
  "error": "avatar_url, file_name and chat[] are required"
}
```

成功：

```json
{ "ok": true }
```

### 8.3 `POST /api/chats/delete`

请求：

```json
{
  "avatar_url": "Assistant.png",
  "chatfile": "chat.jsonl"
}
```

行为：

- `avatar_url` 或 `chatfile` 为空返回 `400` 空 body。
- `chatfile` 自动确保 `.jsonl` 扩展名。
- 删除 `data/default-user/chats/<avatar_url without .png>/<chatfile>`。
- 文件不存在或删除失败返回 `400` 空 body。

成功：

```json
{ "ok": true }
```

### 8.4 `POST /api/chats/rename`

请求：

```json
{
  "is_group": false,
  "avatar_url": "Assistant.png",
  "original_file": "old.jsonl",
  "renamed_file": "new.jsonl"
}
```

行为：

- 普通聊天目录：`data/default-user/chats/<avatar_url without .png>/`
- 群聊目录：`data/default-user/group chats/`
- 原文件不存在或目标文件已存在时返回：

```json
{ "error": true }
```

- 成功时复制到新文件名并删除旧文件。

成功：

```json
{
  "ok": true,
  "sanitizedFileName": "new"
}
```

### 8.5 `POST /api/chats/import`

用途：导入普通角色聊天。

请求：

```http
POST /api/chats/import
Content-Type: multipart/form-data
```

表单字段：

```ts
type ChatImportForm = {
  avatar: File;          // 必填，上传字段名必须是 avatar
  file_type: "json" | "jsonl";
  avatar_url: string;    // 目标角色 PNG 文件名
  character_name: string;
  user_name?: string;
};
```

行为：

- 写入目录：`data/default-user/chats/<avatar_url without .png>/`
- `jsonl`：校验首行包含 `user_name`、`name` 或 `chat_metadata` 后原样写入。
- `json` 当前支持：
  - SillyTavern 聊天数组
  - Oobabooga `data_visible`
  - Agnai `messages`
  - Kobold Lite `savedsettings` + `actions`
- 导入文件名格式：

```text
<character_name> - <timestamp> imported.jsonl
```

成功：

```json
{
  "res": true,
  "fileNames": ["Assistant - 2026-05-02 @07h 00m 00s imported.jsonl"]
}
```

失败：

```json
{ "error": true }
```

当前未支持：CAI Tools `histories`、RisuAI `risuChat`、Chub Chat swipe flatten 的完整兼容转换。

### 8.6 `POST /api/chats/export`

用途：导出普通聊天或群聊。在 OHOS 中不返回浏览器下载内容，统一先写入应用私有目录，再唤起 ShareKit。

请求：

```json
{
  "is_group": false,
  "avatar_url": "Assistant.png",
  "file": "chat.jsonl",
  "exportfilename": "chat.txt",
  "format": "txt"
}
```

`format` 当前支持：

- `jsonl`：原始 JSONL 文本
- 其他值按 `txt` 处理：跳过 `is_system` 消息，输出 `name: message`

私有导出路径：

```text
<context.filesDir>/exports/chats/<exportfilename>
```

成功响应同其他 ShareKit 导出：

```json
{
  "ok": true,
  "shared": true,
  "file_name": "chat.txt",
  "path": "/data/storage/el2/base/haps/entry/files/exports/chats/chat.txt",
  "uri": "file://com.esoteric.tavernnext/...",
  "content_type": "text/plain"
}
```

与原 Node 后端差异：原接口返回 `{ message, result }` 并由浏览器下载；OHOS 版按迁移要求改为“私有目录 + ShareKit”，前端导出按钮已适配为优先使用 ShareKit JSON 响应，仍保留对旧 `{ result }` 响应的兼容。

### 8.7 `POST /api/chats/search`

请求：

```json
{
  "query": "hello world",
  "avatar_url": "Assistant.png",
  "group_id": null
}
```

行为：

- `group_id` 非空时，先读取 `groups/*.json` 找到对应群组，再扫描其 `chats[]`。
- 否则扫描 `chats/<avatar_url without .png>/*.jsonl`。
- 查询会按空白拆词，所有词都需要出现在聊天文件名、消息 `mes` 或消息 `name` 中。

响应：

```json
[
  {
    "file_name": "chat",
    "file_size": "1.5 KB",
    "message_count": 8,
    "last_mes": "2026-05-02T00:00:00.000Z",
    "preview_message": "last message"
  }
]
```

当前是本地基础搜索，不含原版完整 metadata 开关、复杂 preview buffer 和损坏聊天提示。

### 8.8 `POST /api/chats/group/get`

请求：

```json
{
  "id": "group-chat-id"
}
```

读取：

```text
data/default-user/group chats/<id>.jsonl
```

成功返回 JSON 对象数组；文件不存在返回 `[]`。

### 8.9 `POST /api/chats/group/save`

请求：

```json
{
  "id": "group-chat-id",
  "chat": []
}
```

写入 `data/default-user/group chats/<id>.jsonl`，格式与普通聊天相同。成功返回：

```json
{ "ok": true }
```

### 8.10 `POST /api/chats/group/delete`

请求：

```json
{
  "id": "group-chat-id"
}
```

删除 `data/default-user/group chats/<id>.jsonl`。成功返回：

```json
{ "ok": true }
```

### 8.11 `POST /api/chats/group/import`

请求：`multipart/form-data`，上传字段名为 `avatar`。

行为：

- 当前只接受 SillyTavern JSONL。
- 写入 `data/default-user/group chats/<timestamp>.jsonl`。
- 返回新群聊 id。

成功：

```json
{
  "res": "2026-05-02 @07h 00m 00s"
}
```

### 8.12 `POST /api/chats/group/info`

请求：

```json
{
  "id": "group-chat-id"
}
```

返回聊天摘要：

```json
{
  "match": true,
  "file_id": "group-chat-id",
  "file_name": "group-chat-id.jsonl",
  "file_size": "1.5 KB",
  "chat_items": 8,
  "mes": "last message",
  "last_mes": "2026-05-02T00:00:00.000Z"
}
```

### 8.13 `POST /api/chats/recent`

请求：

```json
{
  "max": 100,
  "pinned": [
    {
      "file_name": "chat.jsonl",
      "avatar": "Assistant.png"
    },
    {
      "file_name": "group-chat.jsonl",
      "group": "1234567890"
    }
  ]
}
```

行为：

收集三类聊天文件：

1. 角色聊天：扫描 `characters/*.png`，对每个角色读取 `chats/<png without .png>/*.jsonl`。
2. 群聊：扫描 `groups/*.json`，读取其中 `chats[]`，映射到 `group chats/<chat>.jsonl`。
3. 根聊天：扫描 `chats/*.jsonl`。

排序：

- 请求中的 pinned 聊天排在前面。
- 其他按文件修改时间倒序。
- 实际返回数量为 `max + pinned.length`。

响应字段：

```ts
type RecentChatResponse = {
  file_id: string;
  file_name: string;
  file_size: string;
  chat_items: number;
  mes: string;
  last_mes: string;
  avatar: string;
  group: string;
  match: true;
};
```

示例：

```json
[
  {
    "file_id": "chat",
    "file_name": "chat.jsonl",
    "file_size": "1.5 KB",
    "chat_items": 8,
    "mes": "last message",
    "last_mes": "2026-05-02T00:00:00.000Z",
    "avatar": "Assistant.png",
    "group": "",
    "match": true
  }
]
```

细节：

- 空文件返回 `mes="[The chat is empty]"`。
- 最后一行如果没有 `name`、`character_name`、`chat_metadata`，当前视为无效并跳过。
- `chat_items` 取 `rows.length - 1`，用于排除第一行 metadata。
- `last_mes` 优先取最后一行 `send_date`，否则用文件修改时间 ISO 字符串。
- `file_size` 使用简化格式：`B`、`KB`、`MB`、`GB`、`TB`，小数保留一位。

### 8.14 聊天阶段待完善细节

这一节专门记录聊天记录管理阶段已经基础可用、但还没有完全对齐原 SillyTavern Node 后端的部分。后续做聊天增强时优先对照这里。

#### 8.14.1 保存完整性和备份

当前 `POST /api/chats/save` 和 `POST /api/chats/group/save` 只做最小写入：

- 接收 `force` 字段，但不执行原版 `chat_metadata.integrity` 校验。
- 没有实现原版 `IntegrityMismatchError`。
- 已按 `backups/chat_*.jsonl` 写聊天备份，并实现：
  - `POST /api/backups/chat/get`
  - `POST /api/backups/chat/download`
  - `POST /api/backups/chat/delete`
- 备份清理目前按单聊天前缀保留最近 50 条。
- 仍未实现原版节流备份逻辑和全局最大备份数量策略。

后续需要对齐原版 `trySaveChat()`、`backupChat()`、`removeOldBackups()` 和前端强制覆盖确认流程。

#### 8.14.2 导入格式

当前 `POST /api/chats/import` 支持：

- SillyTavern JSONL 原样导入
- SillyTavern JSON 数组
- Oobabooga `data_visible`
- Agnai `messages`
- Kobold Lite `savedsettings` + `actions`

仍需补齐：

- CAI Tools `histories.histories`
- RisuAI `type === "risuChat"`
- Chub Chat 的 `msg` / `swipes` flatten 细节
- 多聊天 JSON 导入时的批量文件名稳定生成
- 导入失败时更贴近原版的错误类型和日志
- group import 目前只接受 SillyTavern JSONL，原版也是较窄支持，但仍需确认前端所有 group import 场景。

#### 8.14.3 搜索和聊天摘要

当前 `POST /api/chats/search` 是基础本地搜索：

- 按空白拆词。
- 匹配文件名、消息 `mes`、消息 `name`。
- 返回 `file_name`、`file_size`、`message_count`、`last_mes`、`preview_message`。

仍需补齐：

- 原版 `getChatInfo()` 的 `withMetadata` 开关。
- `chat_metadata` 读取和返回。
- 原版 matcher 的滑动 buffer 行为。
- 损坏/空聊天文件的警告与跳过细节。
- preview message 对最后消息和匹配消息的更精确选择。
- `POST /api/characters/chats` 的 `last_mes` 目前仍取最后消息文本，后续要改为更接近原版 `send_date` / mtime 语义。
- `POST /api/chats/recent` 目前是基础扫描，仍需对齐原版 pinned、metadata、空文件、损坏文件、preview message 的完整行为。

#### 8.14.4 导出行为

当前 `POST /api/chats/export` 已按 OHOS 迁移规则改为：

```text
<context.filesDir>/exports/chats/<exportfilename>
```

然后唤起 ShareKit。与原版差异：

- 原版返回 `{ message, result }`，前端用浏览器下载。
- OHOS 版返回 ShareKit JSON，包括 `path`、`uri`、`file_name`、`content_type`。
- 前端导出按钮已兼容 ShareKit 响应，不再要求 `result`。

仍需补齐：

- 如果 ShareKit 失败，前端需要更明确展示“文件已写入私有目录但分享面板打开失败”。
- 导出文件名冲突策略目前是覆盖同名私有导出文件，后续可考虑保留历史或追加序号。
- `txt` 导出当前只处理 `name: message`，还没有完全复刻原版对 `extra.display_text`、不可打印消息、隐藏 prompt、换行和边界异常的全部细节。

#### 8.14.5 群聊联动

当前群聊文件接口已基础可用：

- `POST /api/chats/group/get`
- `POST /api/chats/group/save`
- `POST /api/chats/group/delete`
- `POST /api/chats/group/import`
- `POST /api/chats/group/info`

仍需补齐：

- 删除群聊文件时，当前只删 `group chats/<id>.jsonl`；前端会负责更新 `groups/<id>.json` 中的 `chats[]`，但后端还没有做一致性兜底。
- 重命名群聊文件通过 `POST /api/chats/rename` 的 `is_group=true` 路径完成；后端只改文件名，不主动更新 group JSON。
- 群组最近聊天统计和 `groups/all` 的 `chat_size` / `date_last_chat` 仍是基础扫描。
- 群聊导入后是否自动写回 group JSON 仍由前端处理，后端没有事务式保证。

#### 8.14.6 数据结构约束

所有聊天相关后续改动必须继续遵守：

- 普通聊天只写：

```text
data/default-user/chats/<character internal name>/<file_name>.jsonl
```

- 群聊只写：

```text
data/default-user/group chats/<chat id>.jsonl
```

- 聊天导出只写：

```text
<context.filesDir>/exports/chats/
```

- 不允许为了 OHOS 分享、缓存、导出或临时转换，在 `data/default-user/` 下新增非原版目录或文件。

## 9. 世界书接口

世界书存储：

```text
data/default-user/worlds/<name>.json
```

### 9.1 `POST /api/worldinfo/list`

扫描 `worlds/*.json`。

响应：

```json
[
  {
    "file_id": "World",
    "name": "World",
    "extensions": {}
  }
]
```

`name` 优先取文件 JSON 中的 `name` 字段，否则用文件名去扩展名。

### 9.2 `POST /api/worldinfo/get`

请求：

```json
{
  "name": "World"
}
```

行为：

- `name` 为空返回 `400` 空 body。
- 自动确保 `.json` 扩展名。
- 文件不存在返回空世界书：

```json
{
  "entries": {}
}
```

- 文件存在则返回解析后的 JSON；解析失败也回退为空世界书。

### 9.3 `POST /api/worldinfo/edit`

请求：

```json
{
  "name": "World",
  "data": {
    "entries": {}
  }
}
```

行为：

- `name` 不能为空。
- `data` 必须是对象，不能是数组。
- `data.entries` 必须存在。
- 写入 `worlds/<name>.json`。

错误：

```text
World file must have a name and data object
```

或：

```text
Is not a valid world info file
```

成功：

```json
{ "ok": true }
```

### 9.4 `POST /api/worldinfo/delete`

请求：

```json
{
  "name": "World"
}
```

行为：

- `name` 为空返回 `400` 空 body。
- 删除 `worlds/<name>.json`。
- 删除不存在文件也返回成功。

成功：

```json
{ "ok": true }
```

## 10. 群组接口

群组文件：

```text
data/default-user/groups/<id>.json
```

群聊文件：

```text
data/default-user/group chats/<chat id>.jsonl
```

### 10.1 群组响应结构

```ts
type GroupResponse = {
  id: string;
  name: string;
  members: unknown[];
  avatar_url: string;
  allow_self_responses: boolean;
  activation_strategy: number;
  generation_mode: number;
  disabled_members: unknown[];
  fav: boolean;
  chat_id: string;
  chats: unknown[];
  auto_mode_delay: number;
  generation_mode_join_prefix: string;
  generation_mode_join_suffix: string;
  date_added: number;
  create_date: string;
  chat_size: number;
  date_last_chat: number;
};
```

### 10.2 `POST /api/groups/all`

行为：

- 扫描 `groups/*.json`。
- 解析每个群组。
- 扫描 `group chats/*.jsonl`，如果文件名去扩展名出现在群组 `chats[]` 内，则累加 `chat_size` 并更新 `date_last_chat`。
- `date_added` 为群组 JSON 创建时间。
- `create_date` 为创建时间 ISO 字符串。

响应：`GroupResponse[]`

### 10.3 `POST /api/groups/create`

请求字段：

```ts
type CreateGroupRequest = {
  name?: string;
  members?: unknown[];
  avatar_url?: string;
  allow_self_responses?: boolean;
  activation_strategy?: number;
  generation_mode?: number;
  disabled_members?: unknown[];
  fav?: boolean;
  chat_id?: string;
  chats?: unknown[];
  auto_mode_delay?: number;
  generation_mode_join_prefix?: string;
  generation_mode_join_suffix?: string;
};
```

行为：

- `id` 使用当前 `Date.now()` 字符串。
- `name` 默认 `New Group`。
- `chat_id` 默认 `id`。
- `chats` 为空时自动加入 `id`。
- 写入 `groups/<id>.json`。

成功返回完整 `GroupResponse`。

### 10.4 `POST /api/groups/edit`

请求：

```json
{
  "id": "1234567890",
  "...": "完整群组对象"
}
```

行为：

- `id` 为空返回 `400` 空 body。
- 将整个请求 body 写入 `groups/<id>.json`。

成功：

```json
{ "ok": true }
```

### 10.5 `POST /api/groups/delete`

请求：

```json
{
  "id": "1234567890"
}
```

行为：

- `id` 为空返回 `400` 空 body。
- 读取 `groups/<id>.json`。
- 删除其中 `chats[]` 对应的 `group chats/<chat>.jsonl`。
- 删除群组 JSON 文件。

成功：

```json
{ "ok": true }
```

## 11. 背景、头像、图片、文件、sprites 和缩略图

本阶段已把媒体相关接口从 `SillyTavernCore` 拆到 `MediaService.ets`。图片解码、裁剪、缩放、打包、缩略图和平均色计算使用 Harmony 官方 `@kit.ImageKit`；sprite zip 解包使用 Harmony 官方 `@kit.BasicServicesKit` 的 `zlib.decompressFile`。MediaKit 当前未接入，因为本阶段没有音视频播放、录制或转码，只需要按原版保存和列出媒体文件。

### 11.1 `POST /api/backgrounds/all`

扫描：

```text
data/default-user/backgrounds/
```

支持原版常用图片扩展，包括 `.png`、`.jpg`、`.jpeg`、`.gif`、`.webp`、`.bmp`、`.jfif`、`.tif`、`.tiff`、`.apng`。返回背景文件名、动画标记和缩略图配置：

```json
{
  "images": [
    {
      "filename": "bg.png",
      "isAnimated": false
    }
  ],
  "config": {
    "width": 160,
    "height": 90
  }
}
```

### 11.2 背景增删改

已对齐原版接口和旧路由重定向目标：

- `POST /api/backgrounds/upload` / `POST /downloadbackground`
- `POST /api/backgrounds/delete` / `POST /delbackground`
- `POST /api/backgrounds/rename` / `POST /renamebackground`
- `POST /api/backgrounds/folders`

上传使用 multipart 字段 `avatar`，返回上传后的文件名文本。删除和重命名会同步清理或迁移 `image-metadata.json`，并让对应缩略图缓存失效。

`POST /api/backgrounds/folders` 读取 `image-metadata.json`，返回虚拟文件夹列表和 `imageFolderMap`：

```json
{
  "folders": [],
  "imageFolderMap": {}
}
```

### 11.3 用户头像

已实现：

- `POST /api/avatars/get` / `POST /getuseravatars`
- `POST /api/avatars/upload` / `POST /uploaduseravatar`
- `POST /api/avatars/delete` / `POST /deleteuseravatar`

上传使用 multipart 字段 `avatar`，支持 `overwrite_name`，支持 query `crop`。裁剪和 resize 行为按原版 `applyAvatarCropResize()` 对齐：无 crop 时保留原图尺寸并转 PNG；有 crop 时先裁剪，`want_resize=true` 时输出标准 `512x768`，否则输出裁剪尺寸。删除会清理 persona 缩略图缓存。

### 11.4 聊天图片和媒体文件

已实现：

- `POST /api/images/upload` / `POST /uploadimage`
- `POST /api/images/list`
- `POST /api/images/list/:folder`
- `POST /listimgfiles/:folder`
- `POST /api/images/folders`
- `POST /api/images/delete`
- `GET /user/images/<folder>/<file>`

上传请求保持原版 JSON base64 形态：

```json
{
  "image": "<base64>",
  "format": "png",
  "filename": "optional.png",
  "ch_name": "optional-character-folder"
}
```

`format` 使用原版 `MEDIA_EXTENSIONS`：`bmp`、`png`、`jpg`、`webp`、`jpeg`、`jfif`、`gif`、`mp4`、`avi`、`mov`、`wmv`、`flv`、`webm`、`3gp`、`mkv`、`mpg`、`mp3`、`wav`、`ogg`、`flac`、`aac`、`m4a`、`aiff`。列表接口支持原版 bit flag：图片 `1`，视频 `2`，音频 `4`。

### 11.5 通用文件附件

已实现：

- `POST /api/files/sanitize-filename`
- `POST /api/files/upload`
- `POST /api/files/delete`
- `POST /api/files/verify`
- `GET /user/files/<file>`

上传使用原版 JSON 字段 `{ "name": "...", "data": "<base64>" }`，文件名校验对齐 `assets.validateAssetFileName()` 的核心规则：只允许字母数字、`_`、`-`、`.`，拒绝不安全扩展和点开头文件名。`verify` 对空 `urls: []` 返回 `{}`。

### 11.6 Sprites

已实现：

- `GET /api/sprites/get?name=<character-or-subfolder>`
- `POST /api/sprites/upload`
- `POST /api/sprites/upload-zip`
- `POST /api/sprites/delete`
- `GET /characters/<character>/<sprite-file>`

单张 sprite 上传使用 multipart 字段 `avatar`，body 包含 `name`、`label`、可选 `spriteName`。zip 上传会使用 Harmony `zlib.decompressFile` 解包，递归收集图片，忽略 `__MACOSX`，并按原版逻辑用同 basename 覆盖旧 sprite。

### 11.7 `GET /thumbnail?type=<type>&file=<file>`

已实现真实缩略图生成和缓存，尺寸与原版默认值一致：

- `type=bg`：源文件 `backgrounds/<file>`，缩略图目录 `thumbnails/bg`，目标面积 `160x90`
- `type=avatar`：源文件 `characters/<file>`，缩略图目录 `thumbnails/avatar`，固定 `96x144`
- `type=persona`：源文件 `User Avatars/<file>`，缩略图目录 `thumbnails/persona`，固定 `96x144`

GIF、APNG、动画 WebP 和视频类扩展跳过缩略图生成，按原版回退到源文件。源文件 mtime 新于缓存 ctime 时会重新生成。

### 11.8 图片元数据

已实现并读写 `data/default-user/image-metadata.json`：

- `POST /api/image-metadata/all`
- `POST /api/image-metadata`
- `POST /api/image-metadata/cleanup`
- `POST /api/image-metadata/folders/get`
- `POST /api/image-metadata/folders/create`
- `POST /api/image-metadata/folders/update`
- `POST /api/image-metadata/folders/delete`
- `POST /api/image-metadata/folders/assign`
- `POST /api/image-metadata/folders/unassign`
- `POST /api/image-metadata/folders/set-thumbnails`

metadata 包含 `hash`、`aspectRatio`、`isAnimated`、`dominantColor`、`folderIds`、`addedTimestamp`、`thumbnailResolution`、`mtime`。`hash` 使用 Harmony crypto 侧封装的 SHA-256；尺寸、动画判断和平均色由 ImageKit 及文件头检测完成。

### 11.9 数据文件 fallback

以下路径会从 `data/default-user/` 返回真实文件：

- `GET /characters/<file>` -> `characters/<file>`
- `GET /User Avatars/<file>` -> `User Avatars/<file>`
- `GET /backgrounds/<file>` -> `backgrounds/<file>`
- `GET /user/images/<path>` -> `user/images/<path>`
- `GET /user/files/<path>` -> `user/files/<path>`

路径会拒绝空段、`..` 和空字符。不存在返回 `404`。

## 12. Secrets、账号和扩展接口

### 12.1 `POST /api/secrets/settings`

当前固定返回：

```json
{
  "allowKeysExposure": false
}
```

### 12.2 `POST /api/secrets/read`

读取并返回 `data/default-user/secrets.json` 中的密钥状态。当前 ArkTS 版使用 SillyTavern 新版多值结构：

- 每个 key 的值为 `null` 或 `SecretValue[]`。
- `SecretValue` 字段包括 `id`、`value`、`label`、`active`。
- `allowKeysExposure=false` 时，普通密钥会被遮罩，只保留末尾 3 个字符。
- `libre_url`、`lingva_url`、`oneringtranslator_url`、`deeplx_url` 属于可导出 URL key，读取状态时直接返回明文。
- 如果发现旧版平铺 `secrets.json`，会迁移为数组结构，并将旧文件复制到 `default-user/backups/secrets_migration_<timestamp>.json`。

示例响应片段：

```json
{
  "api_key_openai": [
    {
      "id": "4fc14470-5603-45a1-8fd6-e6183efd5c57",
      "value": "*******lue",
      "label": "Codex",
      "active": true
    }
  ],
  "libre_url": null
}
```

### 12.3 `POST /api/secrets/write`

请求：

```json
{
  "key": "api_key_openai",
  "value": "sk-...",
  "label": "Default"
}
```

行为：
- `key` 不能为空，`value` 必须是字符串。
- 同一个 key 下已有值会被标记为 `active=false`。
- 新值生成本地 UUID，写入 `data/default-user/secrets.json`，并设为 active。

成功响应：

```json
{
  "id": "<uuid>"
}
```

### 12.4 `POST /api/secrets/delete`

请求：

```json
{
  "key": "api_key_openai",
  "id": "optional-secret-id"
}
```

行为：
- `key` 不能为空。
- 传 `id` 时删除指定值；不传 `id` 时删除 active 值。
- 删除后如果仍有其他值但没有 active，会把第一个值设为 active。
- key 下没有剩余值时，会从 `secrets.json` 中移除该 key。

成功返回 `204 No Content`。

### 12.5 `POST /api/secrets/find`

请求：

```json
{
  "key": "libre_url",
  "id": "optional-secret-id"
}
```

行为：
- `key` 不能为空。
- `allowKeysExposure=false` 时，只允许查找 `libre_url`、`lingva_url`、`oneringtranslator_url`、`deeplx_url`。
- 不传 `id` 时返回 active 值。

成功响应：

```json
{
  "value": "https://example.invalid"
}
```

普通非导出密钥在当前配置下返回 `403`。

### 12.6 `POST /api/secrets/view`

在 `allowKeysExposure=false` 时固定返回 `403`。如果后续允许密钥暴露，会返回所有 active 密钥明文。

### 12.7 `POST /api/secrets/rotate`

请求：

```json
{
  "key": "api_key_openai",
  "id": "<secret-id>"
}
```

行为：将同一个 key 下指定 `id` 的值设为 active，其他值设为 inactive。成功返回 `204 No Content`。

### 12.8 `POST /api/secrets/rename`

请求：

```json
{
  "key": "api_key_openai",
  "id": "<secret-id>",
  "label": "New Label"
}
```

行为：修改指定 secret 的 `label`。成功返回 `204 No Content`。

### 12.9 账号数据存储与密码算法

账号记录写入 `<context.filesDir>/data/_storage/`，key 格式为：

```text
user:<handle>
avatar:<handle>
```

实际文件名为 key 的 SHA-256 hex，因此兼容前端的 local database 用法，同时不把账号索引文件放进 `data/default-user/`。SHA-256、随机 salt、scrypt 密码派生均使用 Harmony 官方 `cryptoFramework`：

- SHA-256：`cryptoFramework.createMd('SHA256')`
- scrypt：`cryptoFramework.createKdf('SCRYPT')`
- 参数：`N=16384`、`r=8`、`p=1`、`keySize=64`、`maxMemory=32 MiB`

### 12.10 `POST /api/users/list`

返回所有启用用户的公开视图：

```json
[
  {
    "handle": "default-user",
    "name": "User",
    "created": 1777682705836,
    "avatar": "/img/default-user.png",
    "password": false
  }
]
```

### 12.11 `POST /api/users/login`

请求：

```json
{
  "handle": "default-user",
  "password": "optional"
}
```

行为：
- 用户不存在或密码不匹配返回 `403`。
- 用户未设置密码时，只校验 handle。
- 密码使用 SillyTavern 兼容 scrypt 派生值比较。

成功响应：

```json
{
  "handle": "default-user"
}
```

注意：当前没有建立 session，也不会改变后续核心数据接口使用的 `default-user` 目录。

### 12.12 `GET /api/users/me`

返回默认用户公开视图，并附加 `admin` 字段。当前固定代表 `default-user`。

### 12.13 管理员用户接口

当前注册并实现：

- `POST /api/users/get`：返回所有用户的管理员视图，包含 `admin`、`enabled`。
- `POST /api/users/create`：创建用户，handle 会 slugify，密码可选。
- `POST /api/users/delete`：删除用户记录；`purge=true` 时删除对应 `data/<handle>/` 目录。不能删除 `default-user`。
- `POST /api/users/enable`
- `POST /api/users/disable`：不能禁用 `default-user`。
- `POST /api/users/promote`
- `POST /api/users/demote`：不能降权 `default-user`。
- `POST /api/users/slugify`

新建用户时会创建一套 SillyTavern 用户目录结构，但当前核心角色、聊天、设置接口仍固定使用 `default-user`。

### 12.14 用户资料接口

当前注册并实现：

- `POST /api/users/logout`：返回 `204`，不清理 session。
- `POST /api/users/change-avatar`：记录头像 data URL；空字符串表示清除。暂不处理 multipart 上传。
- `POST /api/users/change-name`
- `POST /api/users/change-password`
- `POST /api/users/reset-settings`：校验默认用户密码后重置 `default-user/settings.json` 为 `{}`。
- `POST /api/users/reset-step1`：生成本地 4 位重置码并直接返回，供 OHOS 本地恢复流程使用。
- `POST /api/users/reset-step2`：校验重置码和密码后清空并重建 `data/default-user/` 的基础文件。
- `POST /api/users/recover-step1`：为指定用户生成本地 4 位恢复码并直接返回。
- `POST /api/users/recover-step2`：用恢复码为指定用户设置新密码。

恢复码和重置码只存在内存中，进程重启后失效。

### 12.15 `POST /api/users/backup`

用途：导出整个 SillyTavern `data/` 目录。

请求：

```json
{
  "handle": "default-user"
}
```

行为：
- 校验 handle 对应用户存在。
- 使用 Harmony 官方 `@kit.BasicServicesKit` 的 `zlib.compressFile(...)` 压缩目录。
- 输入目录固定为 `<context.filesDir>/data`。
- 输出写入 `<context.filesDir>/exports/users/tavernnext-data-<timestamp>.zip`。
- 压缩完成后通过 ShareKit 打开系统分享面板。

成功响应：

```json
{
  "ok": true,
  "shared": true,
  "file_name": "tavernnext-data-20260502-085214.zip",
  "path": "/data/storage/el2/base/haps/entry/files/exports/users/tavernnext-data-20260502-085214.zip",
  "uri": "file://com.esoteric.tavernnext/data/storage/el2/base/haps/entry/files/exports/users/tavernnext-data-20260502-085214.zip",
  "content_type": "application/zip"
}
```

与原 Node 后端差异：原前端期望浏览器下载 zip blob；OHOS 版后端压缩私有文件后唤起 ShareKit。当前新增的扩展页“数据导出/恢复”入口已经适配为读取 JSON 结果并提示用户；rawfile `user.js` 中账号弹窗自带的备份按钮仍保留原 blob 下载逻辑，后续如果继续使用那处入口也需要改成 OHOS JSON/ShareKit 结果处理。

### 12.16 `POST /api/users/restore-data`

用途：从 zip 导入 SillyTavern / TauriTavern `data/` 内容。

请求为 `multipart/form-data`，文件字段优先读取：

```text
archive
```

兼容字段：

```text
file
```

行为：
- 只接受文件名以 `.zip` 结尾的上传。
- 使用 Harmony 官方 `@kit.BasicServicesKit` 的 `zlib.decompressFile(...)` 解压。
- 上传 zip 和解压目录写入 `<context.filesDir>/_restore/restore-<timestamp>/`。
- 支持三种 zip 结构：
  - 解压后直接是 `default-user/`、`_storage/`、`cookie-secret.txt` 等 data 内容。
  - 解压后包含一层 `data/` 目录。
  - 解压后直接是某个用户根目录，例如包含 `settings.json`、`characters/`、`chats/`、`extensions/`、`User Avatars/` 等；此时会被归一化为 `data/default-user/`。
- 只有检测到 data 根目录或用户根目录特征时，才认为是可恢复的 TavernNext/SillyTavern 备份。
- 合并前先把当前 `<context.filesDir>/data` 复制到 `<context.filesDir>/_restore/previous-data-<timestamp>` 作为回滚备份。
- 当前导入支持两种模式：`incremental` 增量导入对齐 TauriTavern 的 overlay 思路，把识别出的 data/user-root 内容覆盖合并到现有 `<context.filesDir>/data`；同路径文件覆盖，同路径目录递归合并，zip 中不存在的文件不会被删除。`clean` 干净导入会先把当前 data 目录重置为刚安装后的默认状态，再执行相同的 overlay 合并。
- 合并失败时会删除残缺 data 并尝试把旧 data 移回原位置。
- 恢复成功后调用 `DataDirectories.initialize()` 和 `ensureDefaultUserFiles()` 补齐基础目录、`settings.json`、`image-metadata.json`、`secrets.json`、`stats.json`、`content.log`、`cookie-secret.txt`，并重建默认用户记录，然后清理本次临时目录与旧数据临时备份。
- 这个差异是为了兼容 TauriTavern 导出的不完整 data archive：TauriTavern 本身是 overlay 导入，缺少某些配置文件时会保留已有配置；TavernNext 早期整目录替换会把这些兜底文件删除，可能导致导入完成后前端或后端服务读取缺失文件时闪退。

成功响应：

```json
{
  "ok": true,
  "restored": true,
  "mode": "incremental",
  "message": "Data directory restored."
}
```

当前前端入口：扩展抽屉内新增 `数据导出/恢复` 折叠栏，包含：

- `导出 data 压缩包`：调用 `POST /api/users/backup`。
- `导入 data 压缩包`：先让用户选择“增量导入”或“干净导入”，再按对应风险弹窗确认；确认后调用 `POST /api/users/restore-data-picker`，由 ArkTS 后端唤起 Harmony 文件选择器选择 zip。

### 12.16.1 `POST /api/users/restore-data-picker`

用途：OHOS 前端真实入口。避免让大 zip 通过 WebView `<input type=file>` 和 HTTP multipart 传给本地后端。

请求：

```json
{
  "handle": "default-user",
  "mode": "incremental"
}
```

当前实现不依赖请求体中的 handle，只恢复当前默认 `data/`。`mode` 支持 `incremental` 和 `clean`，缺省为 `incremental`。

行为：
- ArkTS 后端使用 `@kit.CoreFileKit` 的 `picker.DocumentViewPicker` 唤起系统文件选择器。
- 只允许选择一个 `.zip` 文件。
- 使用 `fileIo` 分块复制所选文件到 `<context.filesDir>/_restore/restore-<timestamp>/upload.zip`。
- 后续解压、识别、归一化、按模式合并和回滚逻辑与 `POST /api/users/restore-data` 共用。
- 用户取消选择时返回 `{ "ok": false, "cancelled": true }`。

已验证的非破坏性错误路径：

- 非 zip 内容上传会返回 `400 {"error":"Failed to decompress backup zip"}`。
- 可解压但不是 data 备份的 zip 会返回 `400 {"error":"The zip archive does not look like a TavernNext data backup"}`。
- 已在模拟器里用 50MB 级 SillyTavern data 备份验证：后端 picker 选择文件后可恢复，避免了前端传输造成的卡死/闪退。

### 12.17 `GET /api/extensions/discover`

### 12.18 `POST /api/extensions/discover`

扫描扩展目录并返回可用扩展。当前来源包括：

- rawfile 内置系统扩展：`public/scripts/extensions/<name>`
- 用户本地扩展：`data/default-user/extensions/<name>`，返回为 `third-party/<name>`
- 用户本地第三方容器：`data/default-user/extensions/third-party/<name>`，返回为 `third-party/<name>`
- 用户根目录兼容路径：`data/default-user/public/scripts/extensions/third-party/<name>`、`data/default-user/scripts/extensions/third-party/<name>`
- data 根目录兼容路径：`data/extensions/<name>`、`data/extensions/third-party/<name>`、`data/public/scripts/extensions/third-party/<name>`、`data/scripts/extensions/third-party/<name>`
- 应用私有全局扩展：`<context.filesDir>/extensions/global/<name>`，返回为 `third-party/<name>`
- 应用私有全局兼容路径：`<context.filesDir>/data/globalExtensions/<name>`
- rawfile 第三方扩展：`public/scripts/extensions/third-party/<name>`

扫描时会跳过没有 `manifest.json` 的 `third-party` 容器目录，避免把容器本身当成插件。

示例响应：

```json
[
  {
    "type": "system",
    "name": "quick-reply"
  },
  {
    "type": "local",
    "name": "third-party/my-extension"
  }
]
```

### 12.19 第三方扩展静态资源

fallback 会优先为以下路径提供本地/全局/rawfile 第三方扩展文件：

```text
GET /scripts/extensions/third-party/<extension>/<file>
```

查找顺序：
1. 本地扩展兼容根：`data/default-user/extensions`、`data/default-user/extensions/third-party`、`data/default-user/public/scripts/extensions/third-party`、`data/default-user/scripts/extensions/third-party`、`data/extensions`、`data/extensions/third-party`、`data/public/scripts/extensions/third-party`、`data/scripts/extensions/third-party`
2. 全局扩展兼容根：`<context.filesDir>/extensions/global`、`data/globalExtensions`、`data/public/scripts/extensions/third-party`
3. `public/scripts/extensions/third-party/<extension>/<file>`

路径会拒绝空路径、`.`、`..` 和空字符。

### 12.20 扩展管理接口

当前已接入 native `.so` + `libgit2`，ArkTS 负责 SillyTavern HTTP API 兼容、路径选择和错误响应，native 层负责受限 Git 操作。native module 名为 `libtavern_git.so`，由 `entry/src/main/cpp/git_native.cpp` 导出，当前编译进 HAP 的 ABI 包括 `arm64-v8a` 和 `x86_64`。

扩展管理接口的路径解析会复用 `discover` 和第三方静态资源的兼容根：优先按请求里的 `global` 查本地或全局根，如果没有找到，会再查另一侧兼容根。Git 管理动作会优先选择带 `.git` 的真实仓库目录，避免把备份里解压出的非 Git 插件目录传给 native；从 SillyTavern data 备份导入、或插件前端缓存的 local/global 类型与真实目录不一致时，`version/update/branches/switch/delete/move` 仍会落到实际存在的插件目录。新安装仍只写入 `data/default-user/extensions/<name>` 或 `<context.filesDir>/extensions/global/<name>`。

能力目标不是完整 Git 客户端，而是覆盖 SillyTavern 第三方扩展最常见的安装/更新场景：GitHub、GitLab、Gitee、Bitbucket 等平台上的公开 HTTPS 仓库。当前优先保证 clone/install、version/status、update、branches、switch 这些前端常用动作可用。

- `POST /api/extensions/install`：按 URL basename 生成扩展目录名，clone 到本地或全局扩展目录，读取 `manifest.json` 后返回 `version`、`author`、`display_name`、`extensionPath`、`folderName`。默认 `depth=1`，支持请求体里的 `branch`；安装前会检查同 scope 的兼容根里是否已存在同名目录，避免导入备份后重复安装覆盖。
- `POST /api/extensions/version`：解析实际插件目录后打开仓库，fetch origin，返回 `currentBranchName`、`currentCommitHash`、`isUpToDate`、`remoteUrl`。如果目录不是 Git 仓库，会在 ArkTS 侧拦截并按原版兼容返回空 branch/commit 且 `isUpToDate=true`。
- `POST /api/extensions/update`：解析实际插件目录后 fetch origin 并只执行 fast-forward 更新，返回 `shortCommitHash`、`currentCommitHash`、`currentBranchName`、`extensionPath`、`isUpToDate`、`remoteUrl`。
- `POST /api/extensions/branches`：必要时 unshallow，并把 origin fetch refspec 扩展为全部远程分支，然后返回本地和 `origin/*` 分支数组。
- `POST /api/extensions/switch`：支持切换本地分支；传入 `origin/<branch>` 时，如果本地分支不存在，会从远程分支创建同名本地分支后 checkout。
- `POST /api/extensions/move`：在 `default-user/extensions` 和 `<filesDir>/extensions/global` 之间移动目录。
- `POST /api/extensions/delete`：删除本地或全局扩展目录。
- `POST /api/extensions/repair-git`：手动扫描本地/全局插件目录中缺少 `.git` 且存在 `manifest.json` 的第三方插件，按 scope 到 `data/_tauritavern/extension-sources/{local|global}` 查找来源记录，用记录里的 remote URL、reference 和 installed commit 重建 `.git`。返回 `succeeded[]` 与 `failedDetails[]`，失败会包含原因，例如缺少来源记录、缺少 remote URL、缺少 commit id 或 native Git 重建错误。前端插件页的 `重建插件 Git 信息` 按钮会调用该接口并弹窗展示结果。

TLS 处理：

- `libgit2` 使用 mbedTLS 编译，应用内打包 `rawfile/certs/cacert.pem`。
- 后端启动时把证书复制到 `<context.filesDir>/_certs/cacert.pem`，所有 Git fetch/clone/status 操作都会把该路径传给 native 层，默认不关闭证书校验。

已验证：

- `hvigor assembleHap --mode module -p module=entry@default -p product=default` 构建成功。
- `hdc install -r` 可安装到 x86_64 DevEco 模拟器，`GET /health` 正常。
- 使用 `hdc fport` 后，通过 HTTP API 验证 `Extension-Blip` 的 `discover`、`version`、`branches`、`update` 和 `switch` 均可用，`version` 返回 GitHub remote 和真实 commit。

仍暂缓：

- 私有仓库认证和 credential helper。
- SSH remote。
- submodule。
- 非 fast-forward merge、rebase、冲突处理。
- 执行 Git hooks。

## 13. Tokenizer 接口

### 13.1 MikTik native tokenizer

以下路由已接入 native `libtavern_tokenizer.so`：

- `POST /api/tokenizers/openai/encode`
- `POST /api/tokenizers/openai/decode`
- `POST /api/tokenizers/openai/count`
- `POST /api/tokenizers/gpt2/encode`
- `POST /api/tokenizers/gpt2/decode`
- `POST /api/tokenizers/llama/encode`
- `POST /api/tokenizers/llama/decode`
- `POST /api/tokenizers/llama3/encode`
- `POST /api/tokenizers/llama3/decode`
- `POST /api/tokenizers/mistral/encode`
- `POST /api/tokenizers/mistral/decode`
- `POST /api/tokenizers/yi/encode`
- `POST /api/tokenizers/yi/decode`
- `POST /api/tokenizers/gemma/encode`
- `POST /api/tokenizers/gemma/decode`
- `POST /api/tokenizers/jamba/encode`
- `POST /api/tokenizers/jamba/decode`
- `POST /api/tokenizers/nerdstash/encode`
- `POST /api/tokenizers/nerdstash/decode`
- `POST /api/tokenizers/nerdstash_v2/encode`
- `POST /api/tokenizers/nerdstash_v2/decode`
- `POST /api/tokenizers/claude/encode`
- `POST /api/tokenizers/claude/decode`
- `POST /api/tokenizers/deepseek/encode`
- `POST /api/tokenizers/deepseek/decode`
- `POST /api/tokenizers/qwen2/encode`
- `POST /api/tokenizers/qwen2/decode`
- `POST /api/tokenizers/command-r/encode`
- `POST /api/tokenizers/command-r/decode`
- `POST /api/tokenizers/command-a/encode`
- `POST /api/tokenizers/command-a/decode`
- `POST /api/tokenizers/nemo/encode`
- `POST /api/tokenizers/nemo/decode`

native 链路：

```text
TokenizerService.ets
  -> libtavern_tokenizer.so NAPI module
    -> native/tavern_tokenizer_ffi Rust staticlib
      -> third_party/miktik TokenizerRegistry
```

当前 Rust bridge 启用 MikTik `openai`、`huggingface`、`sentencepiece` features。支持的 canonical tokenizer 包括 `o1`、`gpt-4o`、`gpt-4`、`gpt-4-32k`、`gpt-3.5-turbo`、`gpt-3.5-turbo-0301`、`gpt2`、原版 `TEXT_COMPLETION_MODELS` 中的旧 OpenAI text/code/embedding 模型、`claude`、`deepseek`、`gemma`、`llama`、`llama3`、`mistral`、`yi`、`jamba`、`nerdstash`、`nerdstash_v2`、`qwen2`、`command-r`、`command-a`、`nemo`；模型 alias 由 MikTik/ArkTS 共同解析，空模型按原版默认走 OpenAI tokenizer。

内置 tokenizer 资源：

- `native/tavern_tokenizer_ffi/resources/tokenizers/claude.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/deepseek.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/gemma.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/llama.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/llama3.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/mistral.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/yi.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/jamba.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/nerdstash.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/nerdstash_v2.model.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/qwen2.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/command-r.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/command-a.json.gz`
- `native/tavern_tokenizer_ffi/resources/tokenizers/nemo.json.gz`

这些资源来自 SillyTavern 本地 `src/tokenizers` 和 SillyTavern-Tokenizers 仓库；OHOS 侧选择全部 gzip 内置，首次使用时由 Rust bridge 懒加载解压并注册到 MikTik `TokenizerRegistry`。这和 TauriTavern 的“部分内置、部分首次下载缓存”思路一致，但为了移动端稳定性先避免运行时下载 tokenizer。

encode 请求：

```json
{
  "text": "Hello world"
}
```

encode 响应示例：

```json
{
  "ids": [13225, 2375],
  "count": 2,
  "chunks": ["Hello", " world"]
}
```

decode 请求：

```json
{
  "ids": [13225, 2375]
}
```

decode 响应：

```json
{
  "text": "Hello world",
  "chunks": ["Hello", " world"]
}
```

`POST /api/tokenizers/openai/count` 按原版 chat message 规则统计：普通模型每条 message 加 `3`，`name` 加 `1`，末尾加 reply priming `3`；`gpt-3.5-turbo-0301` 使用每条 message `4`、`name` 为 `-1`，并保留原版 legacy 修正。

`POST /api/tokenizers/openai/count` 对非 OpenAI native 模型保持原版分支：

- Claude、DeepSeek、Llama3、Qwen2、Command-R、Command-A、Nemo：先按原版 `convertClaudePrompt(..., false, '', false, false, '', false)` 语义转成 Claude-style prompt，再用 web tokenizer 计数。
- Llama、Mistral、Yi、Gemma、Jamba、Nerdstash、Nerdstash v2：按原版 SentencePiece 分支，把 messages 中的 values flatten 后用 `\n\n` 拼接，再计数。

`POST /api/backends/chat-completions/bias` 也会使用同一套 native tokenizer。请求体必须是数组，数组项使用 `{ "text": "...", "value": number }`；`text` 可以是普通文本，也可以是原始 token 数组字符串如 `[1,2,3]`。Claude tokenizer 按原版返回空对象。

### 13.2 兼容/暂缓 tokenizer

`POST /api/tokenizers/encode` 这个无模型旧兼容入口仍按字节估算；它不是原版具体模型 tokenizer。除此之外，SillyTavern 已注册的本地 tokenizer 模型路由当前都已接入 native。

仍需关注的边界：

- 特殊 token 和非法 token id 的错误返回是否与 Node/WASM 完全一致。
- SentencePiece chunks 当前使用 native token pieces；decode 响应仍按单 token decode 聚合，和原版展示高度接近但仍需用更多样本文本比对。
- 全部 tokenizer 资源内置会增加 HAP 体积；如后续包体压力明显，可改为 TauriTavern 式首次下载缓存。

## 14. 未注册接口和占位响应

当前没有专门注册为 `501` 的模型/vector 主路径。`/api/vector/*`、`/api/backends/chat-completions/*`、`/api/openai/generate` 已有实际处理逻辑。

仍会返回 `501 Not Implemented` 的情况是：请求路径没有命中任何已注册路由，也没有被静态资源或数据文件 fallback 处理。此时 `HttpServer` 返回：

响应：

```json
{
  "error": "not_implemented",
  "path": "<request path>"
}
```

## 15. 当前已验证行为

已经在 DevEco 模拟器和 `hdc` 上验证：

- 构建命令 `hvigor assembleHap` 成功。
- 应用可安装、启动。
- `GET /health` 可从宿主机通过 `hdc fport tcp:8000 tcp:8000` 访问。
- SillyTavern 前端 rawfile 资源可加载。
- WebView 进入欢迎页，角色列表页和角色创建页可打开。
- `GET /api/extensions/discover` 可返回 rawfile 系统扩展，并扫描本地/全局第三方扩展目录。
- `POST /api/chats/recent` 在空数据目录返回 `[]`。
- `POST /api/ping` 返回 `{ "ok": true }`。
- 临时角色创建、列表读取、删除流程已通过 HTTP API 验证。
- `POST /api/users/create`、`POST /api/users/login` 已通过 HTTP API 验证，正确密码返回 `200`，错误密码返回 `403`。
- `POST /api/secrets/write`、`POST /api/secrets/read`、`POST /api/secrets/delete` 已通过 HTTP API 验证。
- `POST /api/users/backup` 已通过 HTTP API 验证，能够调用 Harmony `zlib.compressFile` 生成 zip，并通过 ShareKit 返回分享结果。
- `POST /api/users/restore-data` 已通过非破坏性 HTTP API 验证，坏 zip 和非 data zip 都会返回 `400`，不会覆盖当前 `data/`。
- `POST /api/users/restore-data-picker` 已在模拟器验证：后端唤起 Harmony 文件选择器，选择 50MB 级 SillyTavern data 备份后可以恢复，避免 WebView 上传卡死。
- 扩展抽屉的 `数据导出/恢复` 折叠栏已能在 rawfile HTML 中加载，导出调用 `users/backup`，导入会先确认覆盖，再调用后端 picker。
- 第三方扩展 Git 已通过 native `libgit2` 验证：`Extension-Blip` 的 `version`、`branches`、`update`、`switch origin/main` 均可用。
- OpenAI/OpenAI-compatible chat-completions 已通过 mock OpenAI 服务验证：状态检查、非流式生成、流式 SSE 生成均可用。
- 媒体上传回归已验证：背景、用户头像、聊天图片、附件、sprites、sprite zip、thumbnail、image-metadata 基础流程可用。

常用验证命令：

```powershell
$env:DEVECO_SDK_HOME='E:\Huawei\DevEco Studio\sdk'
& 'E:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default

& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' install -r .\entry\build\default\outputs\default\entry-default-signed.hap
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell aa force-stop com.esoteric.tavernnext
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.esoteric.tavernnext
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' fport tcp:8000 tcp:8000

curl.exe -i http://127.0.0.1:8000/health
curl.exe -i -X POST http://127.0.0.1:8000/api/ping
curl.exe -i http://127.0.0.1:8000/api/extensions/discover

$json = '{"handle":"default-user"}'
$path = Join-Path $env:TEMP 'tavernnext-backup.json'
Set-Content -LiteralPath $path -Value $json -NoNewline -Encoding ascii
curl.exe -i -H "Content-Type: application/json" --data-binary "@$path" http://127.0.0.1:8000/api/users/backup

$badZip = Join-Path $env:TEMP 'tavernnext-bad.zip'
Set-Content -LiteralPath $badZip -Value 'bad zip' -NoNewline -Encoding ascii
curl.exe -i -F "archive=@$badZip;type=application/zip" http://127.0.0.1:8000/api/users/restore-data
```

UI 截图：

```powershell
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell snapshot_display -f /data/local/tmp/tavernnext.jpeg
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' file recv /data/local/tmp/tavernnext.jpeg .\tavernnext.jpeg
```

模拟点击：

```powershell
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell uitest uiInput click <x> <y>
```

## 16. 已知限制和后续对齐点

当前实现目标是“让 SillyTavern 前端先在手机 WebView 中跑起来”，不是完整后端替代。已知限制：

- 已有本地账号兼容 API 和密码校验；多用户系统明确暂缓，当前固定使用 `default-user`，不支持真实多用户会话、cookie-session、当前用户切换、权限中间件和真实 CSRF。
- multipart 解析已支持，角色卡 JSON/PNG 导入、头像上传、背景上传、sprites 上传、聊天导入、世界书导入已接入；仍需补齐 CharX/BYAF/Risu sprites 等更复杂导入格式。
- Chat-completions provider 主路径已覆盖 OpenAI/OpenAI-compatible、OpenRouter、DeepSeek、Moonshot、Z.AI、NanoGPT、Chutes、Groq、SiliconFlow、Claude、Gemini/MakerSuite、Vertex AI、Cohere，支持常用 payload builder、状态检查、非流式归一化、关键流式转换、prompt cache、取消和 LLM API 文件日志；其他外部服务仍未完整对齐。
- SillyTavern 本地 tokenizer 路由已接入 native MikTik；上下文裁剪和模型精确 token 计数已覆盖 GPT-2、Llama/Llama 3、Mistral、Yi、Gemma、Jamba、Nerdstash、Qwen2、Command、Nemo、Claude、DeepSeek 和 OpenAI/tiktoken。剩余是特殊 token/chunks/包体积等边界优化。
- Vector 已有本地 JSON 索引、批量 remote embedding provider 调用和 hash fallback；OpenAI-compatible、Cohere、Ollama、Extras、NomicAI、Google/MakerSuite、Vertex 等常用请求形状已补，但还不是原版 `vectra.LocalIndex` 等价实现。
- 背景、头像、聊天图片、附件、sprites、缩略图和 `image-metadata` 已接入本地文件实现；其中图片处理依赖 Harmony `ImageKit`，与 Node/Jimp 在极端格式上的像素级结果可能存在细微差异。
- `extensions/discover` 已扫描 rawfile 系统扩展和本地/全局第三方扩展目录；扩展 Git 已支持 HTTPS 公共仓库，但私有仓库认证、SSH、submodule、merge 冲突处理和 hooks 仍暂缓。
- `users/backup` 已使用 Harmony zlib 生成 zip 并调用 ShareKit；扩展页新入口已适配 OHOS JSON/ShareKit 结果，但 rawfile `user.js` 账号弹窗里的备份按钮仍保留浏览器 blob 下载逻辑。
- `users/restore-data` 和 `users/restore-data-picker` 已有 zip 解压和覆盖恢复逻辑，后端 picker 已在模拟器用 50MB 级备份验证；HTTP multipart 恢复入口主要保留为调试兼容。
- `settings/get` 的 Kobold/NovelAI/OpenAI/TextGen 预设已按原版返回 JSON 文件原文字符串数组；settings snapshots、presets、themes、moving UI、assets、content import 和聊天备份管理接口已接入基础兼容，仍有原版节流、config 白名单、完整校验等细节差异。
- `characters/chats` 的 `last_mes` 当前不是 `send_date`，后续需要与 Node 版 `getChatInfo()` 完全对齐。
- 静态前端资源内的 `global.d.ts` 被 rawfile 打包会触发 hvigor source warning，但不影响运行。

## 17. 缺失接口和功能清单

这一节按 SillyTavern 原后端能力归类，记录当前 ArkTS 版还没有实现、仅占位、或只做了最小兼容的部分。后续每完成一个大阶段都应单独 commit，方便回滚。

### 17.1 角色卡相关

当前 ArkTS 已实现：

- `POST /api/characters/all`
- `POST /api/characters/get`
- `POST /api/characters/create`
- `POST /api/characters/edit`
- `POST /api/characters/duplicate`
- `POST /api/characters/rename`
- `POST /api/characters/edit-avatar`，基础版：使用上传 PNG 替换底图，保留角色卡元数据
- `POST /api/characters/edit-attribute`
- `POST /api/characters/merge-attributes`，基础版：递归合并字段并做最小卡片校验
- `POST /api/characters/delete`
- `POST /api/characters/chats`
- `POST /api/characters/import`，当前支持 `json` 和 `png`
- `POST /api/characters/export`，当前支持 `json` 和 `png`，并通过私有目录 + ShareKit 分享
- PNG 角色卡 `tEXt/chara` 元数据读写

仍缺失：

- 创建角色时直接上传角色卡头像、裁剪、resize
- 编辑角色卡头像时的真实 crop/resize/格式转换；当前 `edit-avatar` 只支持上传 PNG bytes 作为新底图
- 角色卡缩略图重建接口；当前已能在 `GET /thumbnail` 请求时生成缓存，但还没有单独的批量重建/清理入口
- 完整 Tavern Card V1/V2/V3 校验器；当前 `merge-attributes` 只做最小结构校验
- Risu sprites 导入
- CharX 附带资产导入
- BYAF 附带聊天、背景、图片导入

特别说明：原 SillyTavern 支持角色卡 JSON 导入，当前 ArkTS 已完成 JSON 和 PNG 的最小可用导入。原接口是：

```http
POST /api/characters/import
```

原接口通过 `multipart/form-data` 上传文件，上传字段来自全局 multer，字段名为：

```text
avatar
```

关键 body 字段：

```json
{
  "file_type": "json",
  "preserved_name": "optional-name"
}
```

原版支持的导入格式：

- `json`
- `png`
- `yaml`
- `yml`
- `charx`
- `byaf`

建议优先实现顺序：

1. 角色卡创建/编辑头像的完整图片处理：create/edit-avatar 路径里的裁剪、resize、JPEG/WebP 转 PNG。
2. 完整 Tavern Card 校验器。
3. `yaml`、`charx`、`byaf`。
4. 缩略图生成、重建和缓存对齐。

### 17.2 聊天相关

当前 ArkTS 已实现：

- `POST /api/chats/get`
- `POST /api/chats/save`
- `POST /api/chats/delete`
- `POST /api/chats/rename`
- `POST /api/chats/export`，OHOS 版通过私有目录 + ShareKit 分享
- `POST /api/chats/import`，基础版：支持 JSONL、SillyTavern JSON 数组、Ooba、Agnai、Kobold Lite
- `POST /api/chats/search`，基础版：按文件名、消息文本和消息名本地搜索
- `POST /api/chats/group/get`
- `POST /api/chats/group/save`
- `POST /api/chats/group/delete`
- `POST /api/chats/group/import`，基础版：只接受 SillyTavern JSONL
- `POST /api/chats/group/info`
- `POST /api/chats/recent`
- `POST /api/backups/chat/get`
- `POST /api/backups/chat/download`
- `POST /api/backups/chat/delete`

仍缺失：

- 聊天导入的完整格式兼容：
  - CAI Tools `histories`
  - RisuAI `risuChat`
  - Chub Chat swipe flatten 的完整转换
  - 多聊天 JSON 导入时的批量文件名稳定生成
  - 导入错误类型与原版日志细节
- 聊天保存完整性校验和强制覆盖确认；当前 `force` 字段接收但不做 integrity slug 校验
- 聊天保存节流备份和原版全局最大备份数量策略；当前每次保存备份，按单聊天前缀保留 50 条
- 群聊文件和 `groups/<id>.json` 的后端一致性兜底；当前主要依赖前端更新 `chats[]` 和 `chat_id`
- 群聊导入后自动写回 group JSON 的事务式保障
- 聊天导出 ShareKit 失败时的前端提示细化
- 聊天导出文件名冲突策略；当前私有导出目录同名覆盖
- 文本导出对 `extra.display_text`、隐藏 prompt、不可打印消息和换行边界的完整对齐

兼容差异：

- `POST /api/chats/recent` 已能返回最近聊天数组，但只实现本地扫描和基础字段。
- `POST /api/characters/chats` 的 `last_mes` 当前取最后消息文本，原版更接近 `send_date` / mtime 语义，后续需要对齐。
- `POST /api/chats/search` 已实现基础搜索和 preview message，但没有原版完整 metadata 读取开关、match buffer 细节和损坏聊天提示。
- `POST /api/chats/export` 已按 OHOS 要求改为 ShareKit 分享，不再返回大段 `result` 供浏览器下载。
- `POST /api/chats/group/info` 已返回基础摘要，但还没有完整复刻原版 `getChatInfo()` 的 metadata 与损坏文件处理。

### 17.3 背景、头像、图片、文件和 sprites

当前 ArkTS 已实现：

- `POST /api/backgrounds/all`
- `POST /api/backgrounds/folders`
- `POST /api/backgrounds/upload`
- `POST /api/backgrounds/delete`
- `POST /api/backgrounds/rename`
- `POST /api/avatars/get`
- `POST /api/avatars/upload`
- `POST /api/avatars/delete`
- `POST /api/images/upload`
- `POST /api/images/delete`
- `POST /api/images/folders`
- `POST /api/images/list`
- `POST /api/images/list/:folder`
- `POST /listimgfiles/:folder`
- `POST /api/files/upload`
- `POST /api/files/delete`
- `POST /api/files/verify`
- `POST /api/files/sanitize-filename`
- `POST /api/image-metadata/all`
- `POST /api/image-metadata`
- `POST /api/image-metadata/cleanup`
- `POST /api/image-metadata/folders/get`
- `POST /api/image-metadata/folders/create`
- `POST /api/image-metadata/folders/update`
- `POST /api/image-metadata/folders/delete`
- `POST /api/image-metadata/folders/assign`
- `POST /api/image-metadata/folders/unassign`
- `POST /api/image-metadata/folders/set-thumbnails`
- `GET /api/sprites/get`
- `POST /api/sprites/upload`
- `POST /api/sprites/upload-zip`
- `POST /api/sprites/delete`
- `GET /thumbnail`
- `GET /characters/*`
- `GET /User Avatars/*`
- `GET /backgrounds/*`
- `GET /user/images/*`
- `GET /user/files/*`
- `POST /api/assets/get`
- `POST /api/assets/download`
- `POST /api/assets/delete`
- `POST /api/assets/character`
- `GET /assets/*`

兼容差异和后续增强：

- 头像上传、背景缩略图、persona 缩略图和 metadata 平均色已用 ImageKit 实现；极端格式的解码/缩放结果可能不与 Jimp 像素级完全一致。
- GIF、APNG、动画 WebP 和视频类缩略图按原版跳过处理并回退源文件。
- assets download 的通用 URL 域名白名单当前内置在 ArkTS 后端，尚未读取原版 config `whitelistImportDomains`。
- MediaKit 暂未接入。当前媒体阶段只保存、列出、读取音视频文件；音视频转码、录制、播放不是原版这些后端接口的职责。

### 17.4 设置、预设、主题和 UI 配置

当前 ArkTS 已实现：

- `POST /api/settings/get`
- `POST /api/settings/save`
- 启动阶段所需的基础预设目录读取
- `POST /api/settings/get-snapshots`
- `POST /api/settings/make-snapshot`
- `POST /api/settings/load-snapshot`
- `POST /api/settings/restore-snapshot`
- `POST /api/presets/save`
- `POST /api/presets/delete`
- `POST /api/presets/restore`
- `POST /api/themes/save`
- `POST /api/themes/delete`
- `POST /api/moving-ui/save`
- `POST /api/quick-reply/save`
- `POST /api/quick-reply/delete`
- 旧路径兼容：`/savequickreply`、`/deletequickreply`、`/savetheme`、`/savemovingui`
- 启动阶段所需的 Comfy workflow 本地列表读取：`POST /api/sd/comfy/workflows`

仍缺失：

- Comfy workflow 完整管理：
  - `POST /api/sd/comfy/save-workflow`
  - `POST /api/sd/comfy/delete-workflow`
  - `POST /api/sd/comfy/rename-workflow`

兼容差异：

- settings snapshots 固定使用当前单用户前缀 `settings_default-user_`，与多用户系统一起暂缓真实用户 handle 切换。
- presets restore 会从 rawfile `default/content/index.json` 查找默认预设；已覆盖 kobold/koboldhorde/novel/textgenerationwebui/openai/instruct/context/sysprompt/reasoning。
- Horde 启动阶段兼容桩已返回离线状态和空模型/worker 数组；真实 Horde 网络代理和生成仍未实现。

### 17.5 世界书

当前 ArkTS 已实现：

- `POST /api/worldinfo/list`
- `POST /api/worldinfo/get`
- `POST /api/worldinfo/edit`
- `POST /api/worldinfo/import`
- `POST /api/worldinfo/delete`
- 旧路径兼容：`/importworldinfo`

兼容差异：

- 世界书导入支持 multipart `avatar` 字段，兼容 `file` 或首个上传文件，并支持前端传入 `convertedData`。
- 校验目前与原版主路径一致检查 JSON 中存在 `entries`，但尚未实现更细的世界书 schema 校验、导入前备份和更多格式转换兜底。

### 17.6 群组

当前 ArkTS 已实现：

- `POST /api/groups/all`
- `POST /api/groups/create`
- `POST /api/groups/edit`
- `POST /api/groups/delete`

仍缺失：

- 群组头像上传和资源处理
- 更完整的群组聊天统计和最近聊天字段对齐

群聊消息相关接口在 `chats` 模块中已有基础版：`group/get`、`group/save`、`group/delete`、`group/import`、`group/info`。剩余主要是群组 JSON 与聊天文件之间的事务式一致性、导入后自动写回和统计字段对齐。

### 17.7 Secrets、扩展和账号

当前 ArkTS 已实现：

- `POST /api/secrets/settings`
- `POST /api/secrets/read`
- `POST /api/secrets/write`
- `POST /api/secrets/delete`
- `POST /api/secrets/find`
- `POST /api/secrets/view`
- `POST /api/secrets/rename`
- `POST /api/secrets/rotate`
- `POST /api/users/list`
- `POST /api/users/login`
- `POST /api/users/recover-step1`
- `POST /api/users/recover-step2`
- `GET /api/users/me`
- `POST /api/users/get`
- `POST /api/users/logout`
- `POST /api/users/create`
- `POST /api/users/delete`
- `POST /api/users/enable`
- `POST /api/users/disable`
- `POST /api/users/promote`
- `POST /api/users/demote`
- `POST /api/users/slugify`
- `POST /api/users/change-avatar`
- `POST /api/users/change-name`
- `POST /api/users/change-password`
- `POST /api/users/backup`，使用 Harmony `zlib.compressFile` 压缩 `<filesDir>/data`，再通过 ShareKit 分享
- `POST /api/users/restore-data`，使用 Harmony `zlib.decompressFile` 解压 zip，确认是 data/user-root 备份后 overlay 合并到 `<filesDir>/data`
- `POST /api/users/reset-settings`
- `POST /api/users/reset-step1`
- `POST /api/users/reset-step2`
- `GET /api/extensions/discover`
- `POST /api/extensions/discover`
- `POST /api/extensions/version`，native `libgit2` 查询 branch、commit、remote 和 up-to-date 状态
- `POST /api/extensions/install`，native `libgit2` clone HTTPS 公共仓库并读取 manifest
- `POST /api/extensions/update`，native `libgit2` fetch 并执行 fast-forward 更新
- `POST /api/extensions/delete`
- `POST /api/extensions/move`
- `POST /api/extensions/switch`，切换本地分支或从 `origin/<branch>` 创建本地分支
- `POST /api/extensions/branches`，列出本地和远程分支
- `POST /api/extensions/repair-git`，从 TauriTavern 来源记录手动重建导入插件缺失的 `.git`
- 扫描 rawfile 系统扩展、`default-user/extensions`、`<filesDir>/extensions/global`
- 提供 `/scripts/extensions/third-party/*` 的本地/全局/rawfile fallback 静态资源

仍缺失：

- secrets：
  - 真实密钥暴露开关配置；当前 `allowKeysExposure=false`
  - `view` 和非导出 key 的 `find` 在当前配置下固定受限
  - 更完整的错误格式与原版日志细节
- extensions：
  - manifest 基础读取已用于 install 响应；完整 manifest 校验、依赖检查和更细的前端兼容逻辑仍需补齐
  - 私有 Git 仓库认证、SSH、submodule
  - 非 fast-forward merge 冲突处理
- 用户账号：
  - 多用户系统明确暂缓：真实登录 session、cookie-session、当前用户切换和权限中间件当前不做
  - `enable_accounts=true` 模式下的完整前端流程当前不做
  - 核心角色、聊天、设置接口固定使用 `default-user`
  - 头像 multipart 上传和裁剪；当前只记录 data URL
  - 通过邮件或外部通道恢复密码；当前恢复码只在本地响应中直接返回
  - `user.js` 账号弹窗里的 `users/backup` 前端 OHOS JSON/ShareKit 结果适配；扩展页新入口已经适配

当前设计是默认用户优先的本地兼容模式；账号接口用于满足前端账号弹窗、密码校验和数据备份流程，不计划在当前阶段发展成完整多用户运行模型。

### 17.8 Tokenizer 和向量

当前 ArkTS 已实现：

- OpenAI/tiktoken native tokenizer：`/api/tokenizers/openai/encode`、`decode`、`count` 已通过 MikTik 真实 encode/decode/count，并覆盖 GPT-2 和原版旧 OpenAI text/code/embedding 模型。
- SillyTavern 本地 tokenizer native 路由：`/api/tokenizers/claude/*`、`deepseek/*`、`gemma/*`、`llama/*`、`llama3/*`、`mistral/*`、`yi/*`、`jamba/*`、`nerdstash/*`、`nerdstash_v2/*`、`qwen2/*`、`command-r/*`、`command-a/*`、`nemo/*` 已使用 MikTik `huggingface/sentencepiece` 后端和内置 gzip tokenizer 资源；`openai/count` 的这些模型会按原版 SillyTavern 分支计数。
- `POST /api/backends/chat-completions/bias`：OpenAI、DeepSeek、Gemma 等 native 可用模型使用 MikTik token ids，Claude 返回空对象，原始 token 数组字符串按原版直接展开。
- `POST /api/tokenizers/remote/kobold/count`：转发到 Kobold/KoboldCpp `tokencount`。
- `POST /api/tokenizers/remote/textgenerationwebui/encode`：按 tabby/koboldcpp/llamacpp/vllm/aphrodite 等 API 类型转发远程 encode/tokenize。
- `/api/vector/insert`、`list`、`delete`、`query`、`query-multi`、`purge`、`purge-all`。
- vector 索引写入 `data/default-user/vectors/<source>/<collectionId>/<model>/index.json`。
- embedding 支持 OpenAI-compatible、Mistral、TogetherAI、OpenRouter、ElectronHub、NanoGPT、SiliconFlow、Chutes、NomicAI、llamacpp、vllm、ollama、extras、cohere、MakerSuite/Google、Vertex AI 等常用 endpoint；insert 会按 10 条一批请求远端；请求失败或未配置时回退到本地 hash vector。

仍缺失或不完善：

- tokenizer 边界仍需继续比对：
  - 特殊 token、异常 token id、极端 Unicode 文本的结果是否与原版完全一致
  - SentencePiece/web tokenizer chunks 展示在更多样本文本下是否完全一致
  - 全部 gzip tokenizer 资源内置后的 HAP 体积取舍
- 原版 `vectra.LocalIndex` 等价索引、性能优化、大数据量索引格式和精确排序行为。
- 各 embedding provider 的完整错误透传、前端配置字段边界和真实服务回归；Vertex embedding full service account OAuth 仍未接入。

### 17.9 模型代理和外部服务

当前 ArkTS 已实现的最小模型代理：

- `POST /api/backends/chat-completions/generate`
- `POST /api/backends/chat-completions/status`
- `POST /api/openai/generate`
- `POST /api/backends/text-completions/status`
- `POST /api/backends/text-completions/generate`
- `POST /api/novelai/status`
- `POST /api/novelai/generate`
- `POST /api/horde/status`
- `POST /api/horde/text-models`
- `POST /api/horde/text-workers`
- `POST /api/horde/sd-models`
- `POST /api/horde/generate-text`
- `POST /api/horde/task-status`
- `POST /api/horde/cancel-task`
- `POST /api/horde/user-info`
- `GET/POST /api/dev/llm-api-logs`
- `GET/POST /api/dev/llm-api-logs/preview`
- `GET/POST /api/dev/llm-api-logs/raw`
- `GET/POST /api/dev/llm-api-logs/settings`
- `GET/POST /api/dev/llm-api-logs/keep`
- `GET/POST /api/dev/llm-api-logs/stream-enabled`
- `GET /api/dev/llm-api-logs/stream`
- `POST /api/sd/ping`
- `POST /api/sd/models`
- `POST /api/sd/samplers`
- `POST /api/sd/schedulers`
- `POST /api/sd/upscalers`
- `POST /api/sd/vaes`
- `POST /api/sd/generate`

当前范围：

- chat-completions 主路径支持 `chat_completion_source=openai` 和 `custom`。
- `custom` 可配置 OpenAI-compatible 端点；DeepSeek、Groq、Mistral、xAI、OpenRouter 等专门 provider source 尚未在入口处放行，后续需要逐项启用并验证差异。
- `status` 使用 `<base>/models`。
- `generate` 使用 `<base>/chat/completions`。
- API key 使用 `proxy_password` 或本地 `api_key_openai` secret；缺少 key 且没有 reverse proxy 时返回 `{ "error": true }`。
- 非流式响应透传 OpenAI JSON。
- 流式响应以 `text/event-stream` 透传上游 SSE 分块。
- 请求体会清理 `chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_*`、`bypass_status_check` 等内部字段，只转发 OpenAI 接受的 `messages/model/temperature/max_tokens/max_completion_tokens/stream/presence_penalty/frequency_penalty/top_p/stop/logit_bias/seed/n/user/tools/tool_choice/logprobs/response_format` 等字段。
- `logprobs` 数字会转换为 OpenAI chat API 的 `logprobs=true` 和 `top_logprobs=<n>`。
- `json_schema` 会转换为 OpenAI `response_format: { type: "json_schema", json_schema: ... }`。
- text-completions 基础代理会按 `api_type` 查询模型或透传 `/v1/completions` / KoboldCpp `/api/v1/generate`。
- NovelAI、Horde、Stable Diffusion 当前是基础 HTTP 代理/查询，不代表完整原版 provider 行为。
- LLM API logs 写入 `data/_cache/llm-api-logs/`，保存 index/meta/request raw/response raw/readable 预览；默认 keep=5，可通过 settings/keep 调整，最大 100；`/stream` 使用 HTTP SSE 推送 `llm-api-log` 事件，前端扩展抽屉的 `LLM API Logs` 面板可查看、复制、启停 Live。

仍缺失或未完整对齐的大类：

- OpenRouter 等 OpenAI-compatible provider 的错误格式、headers、模型列表、流式细节逐项验证。
- Claude / Anthropic 完整 payload builder 和 stream 事件转换。
- Google / Gemini 完整 payload builder、安全设置、工具调用和 stream 事件转换。
- NovelAI 完整参数转换、错误格式和流式/非流式差异。
- Horde 完整排队、取消、worker/model 过滤和错误兼容。
- Kobold / KoboldCpp / TextGenerationWebUI 的完整 text-completions 行为。
- Stable Diffusion 完整 txt2img/img2img/options/progress/upscale 等接口。
- LLM API logs 与 TauriTavern 差异：OHOS 走 HTTP SSE，不是 Tauri event bus；订阅清理依赖心跳/发送失败；日志 UI 是 OHOS rawfile 面板，不是原版 SillyTavern 内建功能。
- Azure
- Minimax
- Volcengine
- 各类语音生成、语音识别、图片生成、视频生成
- caption image
- translate：
  - Bing
  - DeepL
  - DeepLX
  - Google
  - Libre
  - Lingva
  - OneRing
  - Yandex
- search：
  - SerpAPI
  - Serper
  - SearXNG
  - Tavily
  - transcript
  - visit
  - KoboldCpp
  - ZAI
- classify：
  - label 列表
  - 文本分类

这些接口大多需要网络权限、密钥管理、流式响应、错误透传和前端中断控制，建议在本地数据 API 稳定后再分阶段实现。

### 17.10 统计、备份、数据维护和内容导入

当前 ArkTS 已实现：

- `POST /api/stats/get`
- `POST /api/stats/update`
- `POST /api/stats/recreate`
- `POST /api/users/backup`：压缩整个 `<filesDir>/data` 并通过 ShareKit 导出。
- `POST /api/users/restore-data`：上传 zip，解压到私有临时目录，校验 data 结构后 overlay 合并到 `<filesDir>/data`。
- 扩展抽屉新增 `数据导出/恢复` 折叠栏，提供 data 导出和 data zip 导入恢复入口。
- `POST /api/content/importURL` / `POST /api/content/importUUID`：支持 Chub/CharacterHub 角色和 lorebook、Pygmalion、JanitorAI、AICC、Risu、Perchance `.gz` 和内置白名单通用 URL；同时兼容旧文档写法 `/api/content-manager/importURL` / `importUUID`。
- `POST /api/backups/chat/get`
- `POST /api/backups/chat/download`
- `POST /api/backups/chat/delete`

仍缺失：

- data-maid：
  - `POST /api/data-maid/report`
  - `POST /api/data-maid/delete`
  - `POST /api/data-maid/finalize`
  - `GET /api/data-maid/view`
- master import/export 相关能力；当前只覆盖整个 `data/` zip 导出/恢复，不覆盖原版内容管理器的细粒度导入导出

兼容差异：

- content import 的通用 URL 白名单仍是 ArkTS 内置列表，尚未读取原版 config；部分站点受 Cloudflare 或远端接口变化影响时会按原版一样返回下载失败。
- Perchance 头像支持 base64 和 URL，并尽量用 ImageKit 转 PNG；极端非图片或远端阻断时回退透明 PNG。

### 17.11 建议阶段划分

建议后续按以下大阶段推进，并在每个阶段完成后提交 Git commit：

1. 角色导入导出阶段：
   - 已完成：`characters/import` 支持 JSON 和 PNG
   - 已完成：`characters/export` 支持 JSON 和 PNG
   - 已完成：导出写入 `<context.filesDir>/exports/characters` 并唤起 ShareKit
   - 已完成：补文档和基础测试
2. 角色管理补全阶段：
   - 已完成：duplicate
   - 已完成：rename
   - 已完成：edit-attribute
   - 已完成：merge-attributes 基础版
   - 已完成：edit-avatar 基础版
   - 待补：角色卡头像 create/edit-avatar 的完整 crop/resize/格式转换
   - 待补：完整 Tavern Card 校验器
3. 聊天管理阶段：
   - 已完成：delete
   - 已完成：rename
   - 已完成：export
   - 已完成：import 基础版
   - 已完成：group chat get/save/delete/import/info 基础版
4. 账号、密钥和扩展本地兼容阶段：
   - 已完成：secrets 多值结构、write/read/delete/find/rotate/rename 基础版
   - 已完成：users 本地 CRUD、密码校验、重置/恢复码基础版
   - 已完成：data zip 导出和恢复，使用 Harmony zlib 与 ShareKit
   - 已完成：扩展发现扫描本地/全局/rawfile，扩展移动/删除
   - 已完成：第三方扩展 Git 安装、版本、更新、分支列表、分支切换，使用 native `libgit2`
   - 暂缓：真实 session、当前用户切换等多用户系统
   - 待补：私有 Git 仓库认证、manifest 完整解析
5. 媒体上传阶段：
   - 已完成：avatars upload/delete
   - 已完成：backgrounds upload/delete/rename
   - 已完成：images upload/list/delete/folders，含旧路由兼容
   - 已完成：files upload/delete/verify/sanitize
   - 已完成：sprites upload/upload-zip/delete/get
   - 已完成：thumbnails 生成和缓存
   - 已完成：image-metadata 与背景虚拟文件夹
   - 已完成：assets get/download/delete/character 和 `/assets/*` 静态读取
   - 已完成：content importURL/importUUID 基础兼容
6. 设置与预设阶段：
   - 已完成：presets save/delete/restore
   - 已完成：themes save/delete
   - 已完成：quick replies
   - 已完成：moving UI save
   - 已完成：settings snapshots
   - 待补：Comfy workflow save/delete/rename
7. 模型连接最小阶段：
   - 已完成：OpenAI chat-completions 最小代理
   - 已完成：支持非流式 JSON 和流式 SSE 透传
   - 已完成：text-completions、NovelAI、Horde、Stable Diffusion 的基础 HTTP 代理/查询路由
   - 已完成：LLM API logs 文件日志、keep 配置、SSE 订阅和前端查看面板
   - 待补：OpenAI-compatible provider 差异、请求取消、错误细节完全对齐
8. 高级能力阶段：
   - 已完成：vectors 最小本地 JSON 索引和 embedding/hash fallback
   - 待补：vectors 原版等价索引和性能优化
   - 已完成：SillyTavern 本地 tokenizer 路由 native 化，包括 OpenAI/tiktoken、GPT-2、Claude、DeepSeek、Gemma、Llama/Llama 3、Mistral、Yi、Qwen2、Command、Nemo、Nerdstash、Jamba 等
   - 待补：tokenizer 特殊 token/chunks/包体积边界优化
   - 图片、语音、翻译、搜索等外部能力
