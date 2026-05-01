# TavernNext ArkTS 接口细节

本文档描述 `tavernnext-ohos` 当前 ArkTS 后端的实际接口行为。它不是 SillyTavern Node.js 后端的完整替代说明，而是截至当前工程状态已经实现、已经占位、以及需要保持兼容的数据约定。

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

前端通过 OHOS `Web` 组件加载这个地址。当前模型是本机单用户、无登录、无真实 CSRF 校验：

- 固定用户目录：`data/default-user/`
- `GET /csrf-token` 固定返回 `{ "token": "disabled" }`
- `enable_accounts` 固定为 `false`
- 当前不实现多用户 session、cookie-session、账号接口和权限中间件

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
- `data/default-user/settings.json`：不存在时写 `{}`。
- `data/default-user/secrets.json`：不存在时写 `{}`。
- `data/default-user/stats.json`：不存在时写 `{}`。
- `data/default-user/content.log`：不存在时写空字符串。
- `data/default-user/image-metadata.json`：不存在时写 `{}`。

必须保持这些目录名大小写和空格与 SillyTavern 一致，例如 `User Avatars`、`group chats`、`NovelAI Settings`。

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
  "agent": "TavernNext-OHOS",
  "pkgVersion": "1.0.0-ohos",
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
  koboldai_settings: object[];
  koboldai_setting_names: string[];
  novelai_settings: object[];
  novelai_setting_names: string[];
  openai_settings: object[];
  openai_setting_names: string[];
  textgenerationwebui_presets: object[];
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

已知兼容差异：当前预设数组返回解析后的 JSON 对象。原 SillyTavern 某些路径可能期望字符串数组；如果后续前端在某个 loader 对元素执行 `JSON.parse(item)`，这里需要改为返回文件原文字符串。

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

### 7.7 `POST /api/characters/delete`

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

### 7.8 `POST /api/characters/chats`

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

### 8.3 `POST /api/chats/recent`

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

## 11. 背景、头像、缩略图和数据文件

### 11.1 `POST /api/backgrounds/all`

扫描：

```text
data/default-user/backgrounds/
```

支持扩展名：

- `.png`
- `.jpg`
- `.jpeg`
- `.gif`
- `.webp`
- `.bmp`

响应：

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

### 11.2 `POST /api/backgrounds/folders`

当前固定返回：

```json
{
  "folders": [],
  "imageFolderMap": {}
}
```

### 11.3 `POST /api/image-metadata/all`

当前固定返回：

```json
{
  "version": 1,
  "images": {},
  "folders": []
}
```

注意：虽然初始化创建了 `image-metadata.json`，当前接口还没有读取该文件。

### 11.4 `POST /api/avatars/get`

扫描：

```text
data/default-user/User Avatars/
```

支持扩展名同背景。响应是文件名数组：

```json
[
  "persona.png"
]
```

### 11.5 `GET /thumbnail?type=<type>&file=<file>`

当前不生成缩略图，只直接返回源文件。

映射：

- `type=avatar`：`characters/<file>`
- `type=persona`：`User Avatars/<file>`
- `type=bg`：`backgrounds/<file>`

文件不存在或 type 不支持返回 `404` 空 body。

响应 content type：

- `.png`：`image/png`
- `.jpg` / `.jpeg`：`image/jpeg`
- `.gif`：`image/gif`
- `.webp`：`image/webp`
- `.svg`：`image/svg+xml`
- 其他：`application/octet-stream`

### 11.6 数据文件 fallback

以下路径会从 `data/default-user/` 返回真实文件：

- `GET /characters/<file>` -> `characters/<file>`
- `GET /User Avatars/<file>` -> `User Avatars/<file>`
- `GET /backgrounds/<file>` -> `backgrounds/<file>`

文件名经过安全化处理。不存在返回 `404`。

## 12. Secrets 和扩展接口

### 12.1 `POST /api/secrets/settings`

当前固定返回：

```json
{
  "allowKeysExposure": false
}
```

### 12.2 `POST /api/secrets/read`

当前固定返回：

```json
{}
```

不会读取 `secrets.json`。

### 12.3 `GET /api/extensions/discover`

### 12.4 `POST /api/extensions/discover`

当前固定返回：

```json
[]
```

这是为了满足前端 `public/scripts/extensions.js` 的 GET 请求。暂不扫描 `default-user/extensions/`。

## 13. Tokenizer 接口

以下路由共用同一个估算实现：

- `POST /api/tokenizers/encode`
- `POST /api/tokenizers/gpt2/encode`
- `POST /api/tokenizers/openai/encode`
- `POST /api/tokenizers/llama/encode`
- `POST /api/tokenizers/mistral/encode`
- `POST /api/tokenizers/yi/encode`
- `POST /api/tokenizers/llama3/encode`
- `POST /api/tokenizers/gemma/encode`
- `POST /api/tokenizers/jamba/encode`
- `POST /api/tokenizers/qwen2/encode`
- `POST /api/tokenizers/command-r/encode`

请求：

```json
{
  "text": "hello world"
}
```

算法：

```text
tokens = ceil(utf8ByteLength(text) / 3.35)
```

响应：

```json
{
  "ids": [],
  "count": 4,
  "token_count": 4,
  "chunks": []
}
```

这是启动阶段和 UI Token 计数的占位实现，不是真 tokenizer。

## 14. 暂缓接口

以下接口已注册，但返回 `501 Not Implemented`：

- `POST /api/vector/query`
- `POST /api/backends/chat-completions/generate`
- `POST /api/openai/generate`

响应：

```json
{
  "error": "not_implemented",
  "message": "<name> is outside the first ArkTS local-data milestone."
}
```

其中 `<name>` 当前分别为：

- `Vector index`
- `Model proxy`
- `OpenAI proxy`

## 15. 当前已验证行为

已经在 DevEco 模拟器和 `hdc` 上验证：

- 构建命令 `hvigor assembleHap` 成功。
- 应用可安装、启动。
- `GET /health` 可从宿主机通过 `hdc fport tcp:8000 tcp:8000` 访问。
- SillyTavern 前端 rawfile 资源可加载。
- WebView 进入欢迎页，角色列表页和角色创建页可打开。
- `GET /api/extensions/discover` 返回 `[]`。
- `POST /api/chats/recent` 在空数据目录返回 `[]`。
- `POST /api/ping` 返回 `{ "ok": true }`。
- 临时角色创建、列表读取、删除流程已通过 HTTP API 验证。

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

- 不支持账号、登录、多用户、session 和真实 CSRF。
- 不支持 multipart 上传，因此角色导入、头像上传、背景上传等仍需补。
- 不支持真实模型代理，底部仍显示“未连接到 API!”。
- 不支持真实 OpenAI / chat-completions 生成。
- 不支持真实 tokenizer，仅按 UTF-8 字节数估算。
- `image-metadata/all` 暂不读取 `image-metadata.json`。
- `extensions/discover` 暂不扫描扩展目录。
- `settings/get` 的预设内容目前是解析后的 JSON 对象，后续可能需要按 Node 版调整为字符串。
- `characters/chats` 的 `last_mes` 当前不是 `send_date`，后续需要与 Node 版 `getChatInfo()` 完全对齐。
- `thumbnail` 当前直接返回源图，不生成或缓存缩略图。
- 静态前端资源内的 `global.d.ts` 被 rawfile 打包会触发 hvigor source warning，但不影响运行。

