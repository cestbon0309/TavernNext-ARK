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

铁律：`<context.filesDir>/data` 只保存 SillyTavern 原版会保存的数据结构和文件。OHOS 适配产生的临时导出、分享中转文件、系统交互状态不能写入 `data/default-user`，也不能在其中新增非原版目录。当前导出文件统一写入：

```text
<context.filesDir>/exports/
  characters/
```

这个 `exports/` 是应用私有目录，专门用于 ShareKit 分享中转，不属于 SillyTavern `data/` 兼容结构。

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
- multipart 解析已支持，角色卡 JSON/PNG 导入已接入；头像上传、背景上传、聊天导入、世界书导入等 multipart 接口仍需补。
- 不支持真实模型代理，底部仍显示“未连接到 API!”。
- 不支持真实 OpenAI / chat-completions 生成。
- 不支持真实 tokenizer，仅按 UTF-8 字节数估算。
- `image-metadata/all` 暂不读取 `image-metadata.json`。
- `extensions/discover` 暂不扫描扩展目录。
- `settings/get` 的预设内容目前是解析后的 JSON 对象，后续可能需要按 Node 版调整为字符串。
- `characters/chats` 的 `last_mes` 当前不是 `send_date`，后续需要与 Node 版 `getChatInfo()` 完全对齐。
- `thumbnail` 当前直接返回源图，不生成或缓存缩略图。
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

- 创建角色时上传头像、裁剪、resize
- 编辑角色时的真实 crop/resize/格式转换；当前 `edit-avatar` 只支持上传 PNG bytes 作为新底图
- 完整缩略图生成与重建；当前仅删除 `thumbnails/avatar/<avatar>` 触发后续重新请求
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

1. 完整图片处理：头像上传、裁剪、resize、JPEG/WebP 转 PNG。
2. 完整 Tavern Card 校验器。
3. `yaml`、`charx`、`byaf`。
4. 缩略图生成、重建和缓存对齐。

### 17.2 聊天相关

当前 ArkTS 已实现：

- `POST /api/chats/get`
- `POST /api/chats/save`
- `POST /api/chats/recent`

仍缺失：

- `POST /api/chats/delete`
- `POST /api/chats/rename`
- `POST /api/chats/export`
- `POST /api/chats/import`
- `POST /api/chats/search`
- `POST /api/chats/group/get`
- `POST /api/chats/group/save`
- `POST /api/chats/group/delete`
- `POST /api/chats/group/import`
- `POST /api/chats/group/info`
- 聊天备份相关接口：
  - `POST /api/backups/chat/get`
  - `POST /api/backups/chat/download`
  - `POST /api/backups/chat/delete`

兼容差异：

- `POST /api/chats/recent` 已能返回最近聊天数组，但只实现本地扫描和基础字段。
- `POST /api/characters/chats` 的 `last_mes` 当前取最后消息文本，原版更接近 `send_date` / mtime 语义，后续需要对齐。
- 当前没有聊天完整性校验、metadata 读取开关、搜索匹配和 preview message 逻辑。

### 17.3 背景、头像、图片和文件

当前 ArkTS 已实现：

- `POST /api/backgrounds/all`
- `POST /api/backgrounds/folders`
- `POST /api/avatars/get`
- `POST /api/image-metadata/all`
- `GET /thumbnail`
- `GET /characters/*`
- `GET /User Avatars/*`
- `GET /backgrounds/*`

仍缺失：

- 背景：
  - `POST /api/backgrounds/upload`
  - `POST /api/backgrounds/delete`
  - `POST /api/backgrounds/rename`
- 用户头像：
  - `POST /api/avatars/upload`
  - `POST /api/avatars/delete`
- 用户图片：
  - `POST /api/images/upload`
  - `POST /api/images/delete`
  - `POST /api/images/folders`
  - `POST /api/images/list/:folder?`
- 通用文件：
  - `POST /api/files/upload`
  - `POST /api/files/delete`
  - `POST /api/files/verify`
  - `POST /api/files/sanitize-filename`
- 缩略图：
  - 真实生成缩略图
  - 写入 `thumbnails/bg`
  - 写入 `thumbnails/avatar`
  - 写入 `thumbnails/persona`
  - 缩略图缓存失效
- 图片元数据：
  - `POST /api/image-metadata/`
  - `POST /api/image-metadata/cleanup`
  - `POST /api/image-metadata/folders/get`
  - `POST /api/image-metadata/folders/create`
  - `POST /api/image-metadata/folders/update`
  - `POST /api/image-metadata/folders/delete`
  - `POST /api/image-metadata/folders/assign`
  - `POST /api/image-metadata/folders/unassign`
  - `POST /api/image-metadata/folders/set-thumbnails`
- 资产：
  - `POST /api/assets/get`
  - `POST /api/assets/download`
  - `POST /api/assets/delete`
  - `POST /api/assets/character`
- sprites：
  - `GET /api/sprites/get`
  - `POST /api/sprites/upload`
  - `POST /api/sprites/upload-zip`
  - `POST /api/sprites/delete`

### 17.4 设置、预设、主题和 UI 配置

当前 ArkTS 已实现：

- `POST /api/settings/get`
- `POST /api/settings/save`
- 启动阶段所需的基础预设目录读取

仍缺失：

- 设置快照：
  - `POST /api/settings/get-snapshots`
  - `POST /api/settings/make-snapshot`
  - `POST /api/settings/load-snapshot`
  - `POST /api/settings/restore-snapshot`
- 预设：
  - `POST /api/presets/save`
  - `POST /api/presets/delete`
  - `POST /api/presets/restore`
- 主题：
  - `POST /api/themes/save`
  - `POST /api/themes/delete`
- moving UI：
  - `POST /api/moving-ui/save`
- Quick Replies：
  - `POST /api/quick-replies/save`
  - `POST /api/quick-replies/delete`

兼容差异：

- `settings/get` 中预设内容当前返回解析后的 JSON 对象数组；原版部分前端路径可能期望字符串数组，后续要按实际前端调用点对齐。

### 17.5 世界书

当前 ArkTS 已实现：

- `POST /api/worldinfo/list`
- `POST /api/worldinfo/get`
- `POST /api/worldinfo/edit`
- `POST /api/worldinfo/delete`

仍缺失：

- `POST /api/worldinfo/import`
- 世界书导入时的文件上传解析
- 更完整的世界书校验、备份和兼容转换

### 17.6 群组

当前 ArkTS 已实现：

- `POST /api/groups/all`
- `POST /api/groups/create`
- `POST /api/groups/edit`
- `POST /api/groups/delete`

仍缺失：

- 群聊消息相关接口在 `chats` 模块中尚未实现：
  - `POST /api/chats/group/get`
  - `POST /api/chats/group/save`
  - `POST /api/chats/group/delete`
  - `POST /api/chats/group/import`
  - `POST /api/chats/group/info`
- 群组头像上传和资源处理
- 更完整的群组聊天统计和最近聊天字段对齐

### 17.7 Secrets、扩展和账号

当前 ArkTS 已实现：

- `POST /api/secrets/settings`
- `POST /api/secrets/read`
- `GET /api/extensions/discover`
- `POST /api/extensions/discover`

仍缺失：

- secrets：
  - `POST /api/secrets/write`
  - `POST /api/secrets/delete`
  - `POST /api/secrets/find`
  - `POST /api/secrets/view`
  - `POST /api/secrets/rename`
  - `POST /api/secrets/rotate`
- extensions：
  - `POST /api/extensions/version`
  - `POST /api/extensions/install`
  - `POST /api/extensions/update`
  - `POST /api/extensions/delete`
  - `POST /api/extensions/move`
  - `POST /api/extensions/switch`
  - `POST /api/extensions/branches`
  - 扫描 `default-user/extensions`
  - 解析 manifest
  - 第三方扩展安装和更新
- 用户账号：
  - `POST /api/users/list`
  - `POST /api/users/login`
  - `POST /api/users/recover-step1`
  - `POST /api/users/recover-step2`
  - `GET /api/users/me`
  - `POST /api/users/logout`
  - `POST /api/users/change-avatar`
  - `POST /api/users/change-name`
  - `POST /api/users/change-password`
  - `POST /api/users/reset-settings`
  - 管理员用户创建、删除、启用、禁用、升降权等接口

当前设计仍是单用户模式，所以账号相关可以后置。

### 17.8 Tokenizer 和向量

当前 ArkTS 已实现：

- 多个 `/api/tokenizers/*/encode` 的估算接口
- `POST /api/vector/query` 注册为 `501`

仍缺失：

- tokenizer decode：
  - `POST /api/tokenizers/*/decode`
- tokenizer count：
  - `POST /api/tokenizers/openai/count`
  - `POST /api/tokenizers/remote/kobold/count`
  - `POST /api/tokenizers/remote/textgenerationwebui/encode`
- 真实 tokenizer：
  - GPT-2
  - OpenAI
  - Claude
  - Llama / Llama 3
  - Mistral
  - Qwen2
  - Gemma
  - Yi
  - DeepSeek
  - Command 系列
  - Nerdstash 等
- vectors：
  - `POST /api/vector/insert`
  - `POST /api/vector/list`
  - `POST /api/vector/delete`
  - `POST /api/vector/purge`
  - `POST /api/vector/purge-all`
  - `POST /api/vector/query`
  - `POST /api/vector/query-multi`
- embedding 模型调用和本地索引持久化

### 17.9 模型代理和外部服务

当前 ArkTS 已注册但未实现：

- `POST /api/backends/chat-completions/generate`
- `POST /api/openai/generate`

仍缺失的大类：

- OpenAI / chat-completions 代理
- OpenRouter
- Claude / Anthropic
- Google / Gemini
- NovelAI
- Horde
- Kobold / KoboldCpp / TextGenerationWebUI 相关远程调用
- Stable Diffusion
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

仍缺失：

- stats：
  - `POST /api/stats/get`
  - `POST /api/stats/update`
  - `POST /api/stats/recreate`
- data-maid：
  - `POST /api/data-maid/report`
  - `POST /api/data-maid/delete`
  - `POST /api/data-maid/finalize`
  - `GET /api/data-maid/view`
- content-manager：
  - `POST /api/content-manager/importURL`
  - `POST /api/content-manager/importUUID`
- backups：
  - 聊天备份读取、下载、删除
- master import/export 相关能力

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
   - 待补：头像 crop/resize/格式转换
   - 待补：完整 Tavern Card 校验器
3. 聊天管理阶段：
   - delete
   - rename
   - export
   - import
   - group chat get/save/delete
4. 媒体上传阶段：
   - avatars upload/delete
   - backgrounds upload/delete/rename
   - thumbnails 生成和缓存
5. 设置与预设阶段：
   - presets
   - themes
   - quick replies
   - moving UI
   - settings snapshots
6. 模型连接最小阶段：
   - 先实现一个可配置的 OpenAI-compatible chat completions proxy
   - 支持非流式，再支持流式
7. 高级能力阶段：
   - vectors
   - tokenizer 真实实现
   - 图片、语音、翻译、搜索等外部能力
