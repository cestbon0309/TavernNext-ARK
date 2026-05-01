# TavernNext OHOS ArkTS Backend

这个 DevEco 示例工程内置了一个最小可用的 SillyTavern 兼容后端。应用启动后监听：

```text
http://127.0.0.1:8000
```

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
- `POST /api/characters/delete`
- `POST /api/characters/chats`
- `POST /api/chats/get`
- `POST /api/chats/save`
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
- `POST /api/image-metadata/all`
- `POST /api/avatars/get`
- `POST /api/secrets/settings`
- `POST /api/secrets/read`
- `GET /api/extensions/discover`
- `POST /api/extensions/discover`
- `POST /api/tokenizers/encode`
- `POST /api/tokenizers/*/encode`

第一版仍是 `enableUserAccounts=false` 的默认单用户模型，`/csrf-token` 返回 `disabled`。

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
- `GET /api/extensions/discover` 返回 `[]`，用于消除前端扩展发现阶段的 404。
- `POST /api/ping` 返回 `{ "ok": true }`，避免空 body 在端口转发链路中被部分客户端识别为 empty reply。
- 已用 HTTP API 做过临时角色创建、列表读取、删除测试；角色卡落盘为 SillyTavern 兼容 PNG 元数据格式，删除后文件不残留。

## 暂缓接口

模型代理、tokenizer、向量索引、图片处理、导入导出和复杂媒体接口暂时返回 `501 not_implemented`，便于前端识别缺口。

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
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell uitest uiInput click 680 1340
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell snapshot_display -f /data/local/tmp/tavernnext.jpeg
& 'E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' file recv /data/local/tmp/tavernnext.jpeg .\tavernnext.jpeg
```
