# TavernNext OHOS ArkTS Backend

这个 DevEco 示例工程内置了一个最小可用的 SillyTavern 兼容后端。应用启动后监听：

```text
http://127.0.0.1:8000
```

## 最新进度（2026-05-03）

当前 ArkTS 后端已经可以支撑 SillyTavern 前端进入主界面，并完成默认单用户、本地数据优先的核心流程。首次启动会按原版 SillyTavern 的默认内容清单初始化 `data/default-user/`，包括默认 `settings.json`、背景、角色、头像、主题、预设、QuickReplies 和 Comfy workflows；初始化只在 `content.log` 为空时执行一次，已有用户文件不会被覆盖。

已完成的主要功能：
- 本地 HTTP/1.1 后端、rawfile 静态资源服务、WebView 加载入口。
- settings、角色卡、聊天、群聊、世界书、groups、QuickReplies、Comfy workflow 列表等本地数据 API 的基础兼容。
- 角色卡 PNG `tEXt/chara` 元数据读写，JSON/PNG 角色导入导出，聊天导入导出，data zip 导出/恢复。
- 背景、头像、聊天图片、附件、sprites 和 image-metadata 等媒体上传接口；图片处理已接入 Harmony `ImageKit`，zip 压缩/解压已接入 Harmony `zlib`。
- secrets、users、extensions 的本地兼容接口；当前 App 形态固定使用默认用户，多用户系统明确暂缓。扩展发现已兼容导入备份里常见的 `extensions/third-party/<name>` 和 `public/scripts/extensions/third-party/<name>` 结构，第三方扩展静态资源也会从这些位置优先读取。原版 SillyTavern 和 TauriTavern 都有 local/global 两个作用域，但同名扩展按 local 覆盖 global；TavernNext 对导入备份造成的重复项会以当前 active 目录为准，更新时可把隐藏的同名 Git clone 一次性迁移到 active 目录并移除重复项，避免长期维护两份插件。
- 第三方扩展 Git 第一阶段：native `libtavern_git.so` 基于 `libgit2` + mbedTLS，目标收敛为兼容 GitHub、GitLab、Gitee、Bitbucket 等常见 Git 托管平台的公开 HTTPS 仓库；已支持安装、版本状态、分支列表、分支切换和 fast-forward 更新。
- `/version` 现在返回 SillyTavern 兼容 agent，例如 `SillyTavern:1.17.0:TavernNext-OHOS`，用于通过第三方扩展的 `minimum_client_version` 检查。
- OpenAI chat-completions 最小可用代理：支持 `openai` 和 `custom` 两种来源，`status` 请求 `/v1/models`，`generate` 请求 `/v1/chat/completions`，支持非流式 JSON 和流式 `text/event-stream` 透传。
- Tokenizer native bridge：native `libtavern_tokenizer.so` 基于 Rust `miktik`，已接管 SillyTavern 本地 tokenizer 路由的真实 encode/decode/count，覆盖 OpenAI/tiktoken、GPT-2、旧 OpenAI text/embedding 模型、Claude、DeepSeek、Gemma、Llama/Llama 3、Mistral、Yi、Jamba、Nerdstash/Nerdstash v2、Qwen2、Command-R/Command-A 和 Nemo；`/api/tokenizers/openai/count` 会按原版模型分支分别走 OpenAI chat overhead、Claude-style prompt 计数或 SentencePiece flatten 计数。
- Vector 可用实现：本地 JSON 索引、insert/list/delete/query/query-multi/purge、批量 remote embedding provider 调用和 hash fallback；已对齐 OpenAI-compatible、Cohere、Ollama、Extras、NomicAI、Google/MakerSuite、Vertex 等常用 embedding 请求/响应形状。
- 世界书 multipart 导入、settings snapshots、presets save/delete/restore、themes save/delete、moving UI save、assets get/download/delete/character、content importURL/importUUID、聊天备份 get/download/delete 已补齐基础兼容。
- Provider 调试日志：chat-completion generate 会把请求写到 `data/_cache/llm-api-logs/`，包含 index/meta/request raw/response raw 和 readable 预览；可通过 `/api/dev/llm-api-logs`、`/preview?id=<id>`、`/raw?id=<id>` 查看，支持 keep 配置、HTTP SSE 实时订阅和扩展抽屉里的 `LLM API Logs` 面板。

本次确认的模型调用状态：
- 前端 OpenAI/Chat Completion 面板中的 `Streaming` 开关打开后，请求体会发送 `stream: true`。
- ArkTS 侧流式代理已从普通 `http.request()` 切换为 Harmony `requestInStream()`，上游 SSE 会通过 `dataReceive` 分块即时转发给前端。
- 已在虚拟机安装后通过 hdc 端口映射和慢速 mock OpenAI 服务验证：代理返回的 SSE 分块按约 700ms 间隔到达，不再等上游结束后一次性吐出。

仍缺失或不完善的重点：
- 多用户明确暂缓：`/api/users/*` 只满足本地弹窗、密码校验和备份恢复流程；当前不做真实 session、cookie-session、当前用户切换和权限中间件。
- 模型 provider 已覆盖 OpenAI/OpenAI-compatible、OpenRouter、DeepSeek、Moonshot、Z.AI、NanoGPT、Chutes、Groq、SiliconFlow、Claude、Gemini/MakerSuite、Vertex AI、Cohere 的 chat-completion 主路径、常用 payload builder、非流式归一化和关键流式转换；text-completions、NovelAI、Horde、Stable Diffusion 等已有基础代理或查询路由，但还没有完整对齐原版 provider 行为。
- Tokenizer 本地路由已基本全量 native：剩余风险主要是特殊 token、异常 token id、chunks 展示和全部资源内置导致的 HAP 体积取舍。
- Vector 仍不完善：embedding provider 请求形状已明显补齐，但本地索引仍是 JSON + 全量 cosine scan，不是原版 `vectra.LocalIndex` 性能/持久化等价实现；Transformers 本地 embedding 仍是 hash fallback。
- 第三方扩展 Git 当前只要求覆盖常见公开 HTTPS 仓库的插件安装/更新流程；私有仓库认证、SSH、submodule、非 fast-forward merge 冲突处理和 hooks 执行不作为当前目标，仍暂缓。
- 管理类接口剩余差异：聊天备份目前每次保存都会写入并按单聊天前缀保留 50 条，尚未实现原版节流、全局最大数量和完整 integrity slug 校验；content import 的通用 URL 域名白名单仍是内置列表；data-maid、master import/export 和 Comfy workflow save/delete/rename 仍未完成。

## 数据目录兼容

运行时数据根目录必须严格对应 SillyTavern 的 `data/`：

```text
<context.filesDir>/data
```

当前单用户模式使用 SillyTavern 默认用户：

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
    thumbnails/bg
    thumbnails/avatar
    thumbnails/persona
    worlds
    user/images
    user/files
    user/workflows
    User Avatars
    groups
    group chats
    chats
    characters
    backgrounds
    NovelAI Settings
    KoboldAI Settings
    OpenAI Settings
    TextGen Settings
    themes
    movingUI
    extensions
    instruct
    context
    QuickReplies
    assets/bgm
    assets/ambient
    assets/blip
    assets/live2d
    assets/vrm
    assets/character
    assets/temp
    vectors
    backups
    sysprompt
    reasoning
```

角色卡按 SillyTavern 原格式保存为 `characters/<internal-name>.png`。PNG 中写入 `tEXt` 元数据，关键字为 `chara`，内容是 base64 UTF-8 JSON；读取时兼容优先读取 `ccv3`，没有 `ccv3` 再读 `chara`。

首次启动会从 `rawfile/default/content` 导入原版默认内容，包括默认 `settings.json`、23 张背景、Seraphina、Eldoria、`user-default.png`、主题、预设、QuickReplies 和 Comfy workflows。导入逻辑复用原版 `content.log`：`content.log` 为空时执行一次，之后不再重复初始化；目标文件已存在时不会覆盖用户文件。

## 已实现接口

- `GET /`
- `GET /health`
- `GET /csrf-token`
- `POST /api/settings/get`
- `POST /api/settings/save`
- `POST /api/characters/all`
- `POST /api/characters/get`
- `POST /api/characters/create`
- `POST /api/characters/edit`
- `POST /api/characters/edit-avatar`
- `POST /api/characters/edit-attribute`
- `POST /api/characters/merge-attributes`
- `POST /api/characters/duplicate`
- `POST /api/characters/rename`
- `POST /api/characters/delete`
- `POST /api/characters/chats`
- `POST /api/characters/import`
- `POST /api/characters/export`
- `POST /api/chats/get`
- `POST /api/chats/save`
- `POST /api/chats/delete`
- `POST /api/chats/rename`
- `POST /api/chats/import`
- `POST /api/chats/export`
- `POST /api/chats/search`
- `POST /api/chats/group/get`
- `POST /api/chats/group/save`
- `POST /api/chats/group/delete`
- `POST /api/chats/group/import`
- `POST /api/chats/group/info`
- `POST /api/chats/recent`
- `POST /api/worldinfo/list`
- `POST /api/worldinfo/get`
- `POST /api/worldinfo/edit`
- `POST /api/worldinfo/delete`
- `POST /api/groups/all`
- `POST /api/groups/create`
- `POST /api/groups/edit`
- `POST /api/groups/delete`
- `GET /version`
- `GET /thumbnail`
- `GET /characters/*`
- `GET /User Avatars/*`
- `GET /backgrounds/*`
- `POST /api/ping`
- `POST /api/backgrounds/all`
- `POST /api/backgrounds/folders`
- `POST /api/backgrounds/upload`
- `POST /api/backgrounds/delete`
- `POST /api/backgrounds/rename`
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
- `POST /api/avatars/get`
- `POST /api/avatars/upload`
- `POST /api/avatars/delete`
- `POST /api/images/upload`
- `POST /api/images/list`
- `POST /api/images/list/:folder`
- `POST /api/images/folders`
- `POST /api/images/delete`
- `POST /api/files/sanitize-filename`
- `POST /api/files/upload`
- `POST /api/files/delete`
- `POST /api/files/verify`
- `GET /api/sprites/get`
- `POST /api/sprites/upload`
- `POST /api/sprites/upload-zip`
- `POST /api/sprites/delete`
- `POST /api/secrets/settings`
- `POST /api/secrets/read`
- `POST /api/secrets/write`
- `POST /api/secrets/delete`
- `POST /api/secrets/find`
- `POST /api/secrets/view`
- `POST /api/secrets/rotate`
- `POST /api/secrets/rename`
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
- `POST /api/users/change-password`
- `POST /api/users/backup`
- `POST /api/users/restore-data`
- `POST /api/users/restore-data-picker`
- `POST /api/users/reset-settings`
- `POST /api/users/change-name`
- `POST /api/users/reset-step1`
- `POST /api/users/reset-step2`
- `GET /api/extensions/discover`
- `POST /api/extensions/discover`
- `POST /api/extensions/install`
- `POST /api/extensions/update`
- `POST /api/extensions/branches`
- `POST /api/extensions/switch`
- `POST /api/extensions/move`
- `POST /api/extensions/version`
- `POST /api/extensions/delete`
- `POST /api/extensions/repair-git`
- `POST /api/tokenizers/encode`
- `POST /api/tokenizers/*/encode`
- `POST /api/backends/chat-completions/status`
- `POST /api/backends/chat-completions/generate`
- `POST /api/openai/generate`
- `POST /api/quick-reply/save`
- `POST /api/quick-reply/delete`
- `POST /api/sd/comfy/workflows`
- `POST /api/horde/status`
- `POST /api/horde/text-models`
- `POST /api/horde/text-workers`
- `POST /api/horde/sd-models`

当前仍是默认用户优先的本地兼容模型，`/csrf-token` 返回 `disabled`。账号 API 已能满足本地弹窗、密码校验和备份恢复基础流程；多用户系统明确暂缓，不启用真实 session、cookie-session、当前用户切换和权限中间件。

`POST /api/settings/get` 中 Kobold/NovelAI/OpenAI/TextGen 预设按原版返回 JSON 文件原文字符串数组；主题、moving UI、QuickReplies、instruct/context/sysprompt/reasoning 返回解析后的对象数组。

模型连接当前已完成 OpenAI/OpenAI-compatible chat-completions 的最小可用路径：`status` 会请求 `/v1/models`，`generate` 会请求 `/v1/chat/completions`，支持非流式 JSON 和流式 `text/event-stream` 透传。ArkTS 侧会清理 `chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_*`、`bypass_status_check` 等内部字段，只把 OpenAI 接受的 `messages/model/temperature/max_tokens/max_completion_tokens/stream/penalties/top_p/stop/logit_bias/seed/n/user/tools/tool_choice/logprobs/response_format` 等字段发给上游。text-completions、NovelAI、Horde、Stable Diffusion 已有基础代理或查询路由，但 provider 专属 payload、错误格式、请求取消和流式事件转换仍未完整对齐。

媒体上传阶段已接入 Harmony 官方 API：头像裁剪/resize、缩略图、图片尺寸和平均色使用 `@kit.ImageKit`，sprite zip 解包使用 `@kit.BasicServicesKit` 的 `zlib.decompressFile`。MediaKit 暂未接入，因为当前后端接口只需要保存、列出和读取音视频文件，不涉及播放、录制或转码。

## 前端移植状态

当前已经把 SillyTavern 的 `public/` 前端资源复制到：

```text
entry/src/main/resources/rawfile/public
```

注意：`public/lib.js` 必须使用 SillyTavern webpack 构建后的产物，不能直接覆盖为源码入口文件，否则 WebView 会报 `Failed to resolve module specifier "lodash"`。当前 rawfile 中的 `lib.js` 来自：

```text
SillyTavern/dist/_webpack/d2f8920b496f6d16/output/lib.js
```

页面入口 `entry/src/main/ets/pages/Index.ets` 使用 `Web` 组件加载 `http://127.0.0.1:8000`，并开启 JavaScript、DOM storage、database、图片加载、mixed mode 和 online cache。错误浮层只在主框架加载失败时显示，避免子资源 404 误报为整页失败。

扩展抽屉中新增了 `数据导出/恢复` 折叠栏：导出会调用 `POST /api/users/backup`，使用 Harmony `zlib.compressFile` 压缩 `<context.filesDir>/data` 并唤起 ShareKit；导入不再由前端读取 zip 后上传，而是先让用户选择“增量导入”或“干净导入”，再调用 `POST /api/users/restore-data-picker`，由 ArkTS 后端唤起 Harmony `DocumentViewPicker` 选择 zip，并使用 `zlib.decompressFile` 解压。增量导入是当前默认安全路径：识别到 data 根或 user-root 备份后，同路径文件覆盖，zip 中不存在的运行时兜底文件不会被删除；干净导入会先把当前 data 目录重置为刚安装后的默认状态，再执行同样的 overlay 合并。两种模式成功后都会重新补齐 `settings.json`、`image-metadata.json`、`secrets.json`、`stats.json`、`content.log`、`cookie-secret.txt` 和默认用户记录。保留 `POST /api/users/restore-data` 作为 HTTP multipart 调试兼容入口。

## 已验证

在 DevEco 模拟器中已验证：

- `hvigor assembleHap` 构建成功，并使用已有签名生成 `entry-default-signed.hap`。
- `hdc install -r`、`aa force-stop`、`aa start` 可以安装启动应用。
- `hdc fport tcp:8000 tcp:8000` 后，宿主机可访问设备内 ArkTS 后端。
- `GET /health` 返回 `dataRoot=/data/storage/el2/base/haps/entry/files/data`。
- `GET /`、`GET /script.js`、`GET /img/logo.png` 可以由 rawfile 静态服务返回。
- WebView 中 SillyTavern 前端已进入 `app_initialized` / `app_ready` 后的欢迎页。
- 手机截图确认首页、角色列表页、角色创建页可以打开。
- `POST /api/chats/recent` 返回最近聊天数组，当前空数据目录返回 `[]`。
- `GET /api/extensions/discover` 可返回 rawfile 系统扩展，并扫描本地/全局第三方扩展目录。
- `POST /api/ping` 返回 `{ "ok": true }`，避免空 body 在端口转发链路中被部分客户端识别为 empty reply。
- 已用 HTTP API 做过临时角色创建、列表读取、删除测试；角色卡落盘为 SillyTavern 兼容 PNG 元数据格式，删除后文件不残留。
- `POST /api/users/create`、`POST /api/users/login` 已通过 HTTP API 验证，正确密码返回 `200`，错误密码返回 `403`。
- `POST /api/secrets/write`、`POST /api/secrets/read`、`POST /api/secrets/delete` 已通过 HTTP API 验证。
- `POST /api/users/backup` 已通过 HTTP API 验证，能够生成 data zip 并通过 ShareKit 返回分享结果。
- `POST /api/users/restore-data` 已通过非破坏性 HTTP API 验证，坏 zip 和非 data zip 都会返回 `400`，不会覆盖当前 `data/`。
- `POST /api/users/restore-data-picker` 已在虚拟机中验证可由后端唤起文件选择器，并可恢复导入的 SillyTavern data/user-root 备份；导入后的 `extensions/third-party` 插件能被发现和加载。导入策略已从整目录替换改为可选模式：增量导入 overlay 合并，避免 TauriTavern 导出的 zip 缺少部分配置文件时把 TavernNext 的兜底配置一并删除；干净导入则先重建默认 data，再 overlay 导入，用于用户明确想清空现有数据的场景。插件页新增手动 `重建插件 Git 信息` 按钮，调用 `POST /api/extensions/repair-git` 扫描已安装插件中缺少 `.git` 的目录，并从 `_tauritavern/extension-sources/{local|global}` 读取来源信息安全重建仓库元数据；重建不会替换插件目录，会保留插件自行存放的配置和数据，结果会列出成功项和失败原因。
- 扩展抽屉的 `数据导出/恢复` 折叠栏已能在 rawfile HTML 中加载。
- `GET /api/extensions/discover` 已验证能发现导入备份中的 `third-party/JS-Slash-Runner` 和 `third-party/ST-Prompt-Template`；`/scripts/extensions/third-party/.../manifest.json`、`dist/index.js`、`dist/index.css` 静态资源可正常返回；`JS-Slash-Runner` 的 `minimum_client_version=1.12.13` 可通过当前 `/version` 响应启用。扩展 `version/update/branches/switch/delete/move` 现在以发现/静态加载的 active 目录为准；如果 active local 是备份导入的非 Git 旧目录，而隐藏的 global 同名目录是可更新 Git clone，则更新时会迁移 Git clone 到 active local 并清理重复目录，后续只保留一份会被加载和更新的插件。
- 第三方扩展 Git 已在 x86_64 模拟器通过 native `libgit2` 验证：`POST /api/extensions/version` 可读取 `Extension-Blip` 的 `main`、GitHub remote 和真实 commit；`branches` 返回本地与 `origin/main`；`update` 返回 up-to-date；`switch origin/main` 返回 `204`。
- 媒体上传回归已通过 hdc 端口映射和 curl 验证：背景上传/列表/缩略图/删除、用户头像上传裁剪/缩略图/删除、聊天图片上传/列表/旧路由兼容/静态读取/删除、附件上传/verify/读取/删除、sprites 单张上传/zip 上传/读取/删除、`image-metadata` 文件夹创建/assign/delete/cleanup，以及 `m4a` 音频媒体列表。
- OpenAI chat-completions 最小代理已通过本机 mock OpenAI 服务验证：状态检查、非流式生成、流式 SSE 生成均可用，且上游请求体不会包含 `reverse_proxy`、`proxy_password`、`custom_*` 等内部字段。
- Tokenizer native bridge 已在 x86_64 模拟器验证：`encode?model=gpt-4o` 对 `Hello world` 返回 `[13225,2375]`；Claude encode 返回 `[10002,2253]`，DeepSeek encode 返回 `[19923,2058]`，Gemma encode 返回 `[2405,545,513,483,706]`；新增的 `gpt2`、`llama`、`llama3`、`mistral`、`yi`、`jamba`、`nerdstash`、`nerdstash_v2`、`qwen2`、`command-r`、`command-a`、`nemo` 均已通过 HTTP encode/decode/count 验证；`openai/encode?model=llama-3.3-70b`、`qwen2.5-coder`、`command-r-plus`、`text-davinci-003` 等 alias 已能按原版分流；`openai/count` 已验证未知 custom model 的默认 OpenAI fallback；chat-completions `bias` 支持文本和原始 token 数组，Claude 按原版返回空对象。

## 暂缓接口

OpenAI chat-completions、SillyTavern 本地 tokenizer native 化、第三方扩展 Git、vector 最小本地索引、settings snapshots、presets/themes/moving UI、assets/content import、聊天备份和 LLM API logs 已有可用路径；除此之外的完整 provider 适配、tokenizer 边界优化、原版等价 vector index、data-maid、master import/export、Comfy workflow 完整管理和复杂外部服务接口仍未完整实现。多用户系统明确暂缓。部分导入导出已经接入 ShareKit 或 zlib：角色导入/导出、聊天导入/导出、data zip 导出/恢复、sprite zip 导入、Perchance `.gz` content import。

## 构建与调试

命令行构建：

```powershell
$env:DEVECO_SDK_HOME='<DevEco SDK 路径>'
& '<DevEco Studio 路径>\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default
```

安装、启动和端口映射：

```powershell
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' install -r .\entry\build\default\outputs\default\entry-default-signed.hap
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' shell aa force-stop com.esoteric.tavernnext
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.esoteric.tavernnext
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' fport tcp:8000 tcp:8000
```

常用验证命令：

```powershell
curl.exe -i http://127.0.0.1:8000/health
curl.exe -i -X POST http://127.0.0.1:8000/api/ping
curl.exe -i http://127.0.0.1:8000/api/extensions/discover
curl.exe -i -X POST http://127.0.0.1:8000/api/chats/recent -H "Content-Type: application/json" -d "{\"max\":10,\"pinned\":[]}"

$json = '{"handle":"default-user"}'
$path = Join-Path $env:TEMP 'tavernnext-backup.json'
Set-Content -LiteralPath $path -Value $json -NoNewline -Encoding ascii
curl.exe -i -H "Content-Type: application/json" --data-binary "@$path" http://127.0.0.1:8000/api/users/backup

$badZip = Join-Path $env:TEMP 'tavernnext-bad.zip'
Set-Content -LiteralPath $badZip -Value 'bad zip' -NoNewline -Encoding ascii
curl.exe -i -F "archive=@$badZip;type=application/zip" http://127.0.0.1:8000/api/users/restore-data

& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' shell uitest uiInput click 680 1340
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' shell snapshot_display -f /data/local/tmp/tavernnext.jpeg
& '<DevEco SDK 路径>\default\openharmony\toolchains\hdc.exe' file recv /data/local/tmp/tavernnext.jpeg .\tavernnext.jpeg
```
