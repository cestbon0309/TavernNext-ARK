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
- secrets、users、extensions 的本地兼容接口；目前仍是默认用户优先，不启用真实多用户 session。扩展发现已兼容导入备份里常见的 `extensions/third-party/<name>` 和 `public/scripts/extensions/third-party/<name>` 结构，第三方扩展静态资源也会从这些位置优先读取。
- 第三方扩展 Git 第一阶段：native `libtavern_git.so` 基于 `libgit2` + mbedTLS，已支持 HTTPS 公共仓库安装、版本状态、分支列表、分支切换和 fast-forward 更新。
- `/version` 现在返回 SillyTavern 兼容 agent，例如 `SillyTavern:1.17.0:TavernNext-OHOS`，用于通过第三方扩展的 `minimum_client_version` 检查。
- OpenAI chat-completions 最小可用代理：支持 `openai` 和 `custom` 两种来源，`status` 请求 `/v1/models`，`generate` 请求 `/v1/chat/completions`，支持非流式 JSON 和流式 `text/event-stream` 透传。

本次确认的模型调用状态：
- 前端 OpenAI/Chat Completion 面板中的 `Streaming` 开关打开后，请求体会发送 `stream: true`。
- ArkTS 侧流式代理已从普通 `http.request()` 切换为 Harmony `requestInStream()`，上游 SSE 会通过 `dataReceive` 分块即时转发给前端。
- 已在虚拟机安装后通过 hdc 端口映射和慢速 mock OpenAI 服务验证：代理返回的 SSE 分块按约 700ms 间隔到达，不再等上游结束后一次性吐出。

仍缺失或不完善的重点：
- 多用户暂缓：`/api/users/*` 只满足本地弹窗和备份流程，尚无真实 session、cookie-session、当前用户切换和权限中间件。
- 模型 provider 暂缓：OpenRouter、Claude、Gemini、NovelAI、Kobold/TextGen、Horde、Stable Diffusion 等真实代理还未完整对齐；目前只完成 OpenAI/OpenAI-compatible 最小链路。
- Tokenizer 仍是估算接口：尚未接入 MikTik/native tokenizer，也没有完整 OpenAI/Claude/Llama/Qwen/Gemma 等 encode/decode/count。
- Vector 仍未完成：向量 insert/query/delete/list/purge、embedding 调用和本地持久化索引都还需要后续实现。
- 第三方扩展 Git 仍有后续项：私有仓库认证、SSH、submodule、非 fast-forward merge 冲突处理和 hooks 执行暂缓。
- settings snapshots、presets、themes、moving UI、assets/content-manager、聊天备份等管理类接口仍有缺口。

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

当前仍是默认用户优先的本地兼容模型，`/csrf-token` 返回 `disabled`。账号 API 已能满足本地弹窗和密码校验基础流程，但还没有真实 session、cookie-session、当前用户切换和权限中间件。

`POST /api/settings/get` 中 Kobold/NovelAI/OpenAI/TextGen 预设按原版返回 JSON 文件原文字符串数组；主题、moving UI、QuickReplies、instruct/context/sysprompt/reasoning 返回解析后的对象数组。

模型连接当前只完成 OpenAI chat-completions 的最小可用路径：`status` 会请求 `/v1/models`，`generate` 会请求 `/v1/chat/completions`，支持非流式 JSON 和流式 `text/event-stream` 透传。ArkTS 侧会清理 `chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_*`、`bypass_status_check` 等内部字段，只把 OpenAI 接受的 `messages/model/temperature/max_tokens/max_completion_tokens/stream/penalties/top_p/stop/logit_bias/seed/n/user/tools/tool_choice/logprobs/response_format` 等字段发给上游。OpenRouter、Claude、Gemini、Text completions、Horde、Stable Diffusion 等真实 provider 代理仍暂缓。

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

扩展抽屉中新增了 `数据导出/恢复` 折叠栏：导出会调用 `POST /api/users/backup`，使用 Harmony `zlib.compressFile` 压缩 `<context.filesDir>/data` 并唤起 ShareKit；导入不再由前端读取 zip 后上传，而是弹窗确认覆盖后调用 `POST /api/users/restore-data-picker`，由 ArkTS 后端唤起 Harmony `DocumentViewPicker` 选择 zip，再使用 `zlib.decompressFile` 解压并覆盖 data 目录。保留 `POST /api/users/restore-data` 作为 HTTP multipart 调试兼容入口。

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
- `POST /api/users/restore-data-picker` 已在虚拟机中验证可由后端唤起文件选择器，并可恢复导入的 SillyTavern data/user-root 备份；导入后的 `extensions/third-party` 插件能被发现和加载。
- 扩展抽屉的 `数据导出/恢复` 折叠栏已能在 rawfile HTML 中加载。
- `GET /api/extensions/discover` 已验证能发现导入备份中的 `third-party/JS-Slash-Runner` 和 `third-party/ST-Prompt-Template`；`/scripts/extensions/third-party/.../manifest.json`、`dist/index.js`、`dist/index.css` 静态资源可正常返回；`JS-Slash-Runner` 的 `minimum_client_version=1.12.13` 可通过当前 `/version` 响应启用。
- 第三方扩展 Git 已在 x86_64 模拟器通过 native `libgit2` 验证：`POST /api/extensions/version` 可读取 `Extension-Blip` 的 `main`、GitHub remote 和真实 commit；`branches` 返回本地与 `origin/main`；`update` 返回 up-to-date；`switch origin/main` 返回 `204`。
- 媒体上传回归已通过 hdc 端口映射和 curl 验证：背景上传/列表/缩略图/删除、用户头像上传裁剪/缩略图/删除、聊天图片上传/列表/旧路由兼容/静态读取/删除、附件上传/verify/读取/删除、sprites 单张上传/zip 上传/读取/删除、`image-metadata` 文件夹创建/assign/delete/cleanup，以及 `m4a` 音频媒体列表。
- OpenAI chat-completions 最小代理已通过本机 mock OpenAI 服务验证：状态检查、非流式生成、流式 SSE 生成均可用，且上游请求体不会包含 `reverse_proxy`、`proxy_password`、`custom_*` 等内部字段。

## 暂缓接口

OpenAI chat-completions 已有最小可用代理，第三方扩展 Git 已有 HTTPS 公共仓库最小可用路径；除此之外的模型代理、真实 tokenizer、向量索引、预设/主题细节、内容管理器、assets 管理和复杂外部服务接口仍未完整实现。部分导入导出已经接入 ShareKit 或 zlib：角色导入/导出、聊天导入/导出、data zip 导出/恢复、sprite zip 导入。

## 构建与调试

命令行构建：

```powershell
$env:DEVECO_SDK_HOME='E:\Huawei\DevEco Studio\sdk'
& 'E:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default
```

安装、启动和端口映射：

```powershell
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' install -r .\entry\build\default\outputs\default\entry-default-signed.hap
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell aa force-stop com.esoteric.tavernnext
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.esoteric.tavernnext
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' fport tcp:8000 tcp:8000
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

& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell uitest uiInput click 680 1340
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell snapshot_display -f /data/local/tmp/tavernnext.jpeg
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' file recv /data/local/tmp/tavernnext.jpeg .\tavernnext.jpeg
```
