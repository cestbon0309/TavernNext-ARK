# 启动耗时调试锚点

本文档记录 TavernNext OHOS 启动耗时调试锚点。后续新增、删除或调整启动锚点时，需要同步更新本文档。

## 调试接口

- `GET /api/ohos/backend/status`：返回原生后端启动状态和耗时。
- `GET /api/ohos/startup/report`：返回完整启动耗时报告。
- `POST /api/ohos/startup/frontend`：SillyTavern 前端启动完成后上报 `firstLoadInit()` 分段耗时。

`/api/ohos/startup/report` 返回结构：

```json
{
  "backend": {
    "running": true,
    "url": "http://127.0.0.1:8000",
    "dataRoot": "/data/storage/el2/base/haps/entry/files/data",
    "message": "ArkTS backend is listening. init=12ms listen=134ms total=146ms.",
    "initDurationMs": 12,
    "listenDurationMs": 134,
    "startupDurationMs": 146,
    "listenTimings": [
      {
        "label": "server.listen",
        "durationMs": 133,
        "elapsedMs": 134
      }
    ]
  },
  "httpRequests": [],
  "frontend": {
    "reportedAtMs": 0,
    "totalDurationMs": 0,
    "steps": []
  }
}
```

## 后端锚点

文件：`entry/src/main/ets/backend/BackendService.ets`

- `DataDirectories.initialize`：创建 data、exports、restore、cache、default-user 等目录和基础文件。
- `DefaultContentSeeder.seedDefaultUser`：首次启动时复制默认内容。
- `DataDirectories.ensureDefaultUserFiles`：确保 `settings.json`、`image-metadata.json` 等基础文件存在。
- `syncShellThemeFromCurrentSettings`：从当前设置同步壳层背景色。
- `GitService.prepareGitCaBundle`：复制 CA bundle 并初始化 Git 服务。
- `registerRoutes`：注册本地 HTTP 路由。
- `initDurationMs`：`BackendService` 构造阶段总耗时。
- `listenDurationMs`：`HttpServer.start()` 监听 `127.0.0.1:8000` 耗时。
- `startupDurationMs`：`initDurationMs + listenDurationMs`。

文件：`entry/src/main/ets/backend/HttpServer.ets`

- 记录最近 300 个 HTTP 请求。
- 每条请求包含 `method`、`path`、`statusCode`、`handlerDurationMs`、`totalDurationMs`、`finishedAtMs`。
- `handlerDurationMs` 只统计路由处理逻辑。
- `totalDurationMs` 统计解析请求、路由处理、发送响应、关闭连接的总耗时。
- `listenTimings` 记录最近一次 `listenOnce()` 的监听子阶段。
- `constructTCPSocketServerInstance`：构造 TCP server 实例。
- `register socket callbacks`：注册 `connect` 和 `error` 回调。
- `server.listen`：调用 OHOS socket server listen API，绑定 `127.0.0.1:8000` 并等待完成。
- `mark listening`：设置本地 `listening` 状态。

## 前端锚点

文件：`entry/src/main/resources/rawfile/public/script.js`

锚点位于 `firstLoadInit()`，使用 `createStartupTrace()` 记录。

- `csrf-token`
- `create splash overlay`
- `show splash loader`
- `early sync initializers`
- `getClientVersion`
- `initSecrets`
- `readSecretState`
- `initLocales`
- `model and extension sync initializers`
- `initPresetManager`
- `initSystemMessages`
- `getSettings`
- `post-settings sync initializers`
- `getUserAvatars`
- `getCharacters`
- `getBackgrounds`
- `initTokenizers`
- `post-data sync initializers`
- `initPersonas`
- `initSlashCommandAutoComplete`
- `late sync initializers`
- `initScrapers`
- `final sync initializers`
- `APP_INITIALIZED event`
- `hide startup loader`
- `fixViewport`
- `APP_READY event`

每个前端 step 包含：

- `label`：锚点名称。
- `durationMs`：该阶段耗时。
- `elapsedMs`：从 `firstLoadInit()` 开始到该阶段结束的累计耗时。

### `getSettings` 子锚点

文件：`entry/src/main/resources/rawfile/public/script.js`

`getSettings` 目前是最大前端瓶颈，因此已进一步拆分以下子锚点，名称统一带 `getSettings: ` 前缀：

- `fetch /api/settings/get`
- `parse settings response`
- `parse settings json and account controls`
- `setUserControls`
- `SETTINGS_LOADED_BEFORE event`
- `core generation settings`
- `loadKoboldSettings`
- `loadNovelSettings`
- `loadTextGenSettings`
- `loadOpenAISettings`
- `loadHordeSettings`
- `loadPowerUserSettings`
- `apply power user and basic UI settings`
- `SETTINGS_LOADED_AFTER event`
- `main API and persona settings`
- `loadExtensionSettings`
- `EXTENSION_SETTINGS_LOADED event`
- `firstRun hide loader`
- `firstRun onboarding`
- `validateDisabledSamplers`
- `SETTINGS_LOADED event`

### 扩展加载子锚点

文件：`entry/src/main/resources/rawfile/public/scripts/extensions.js`

`loadExtensionSettings` 内部已进一步拆分以下子锚点，名称统一带 `extensions: ` 前缀：

- `apply stored settings`
- `EXTENSIONS_FIRST_LOAD event`
- `discoverExtensions`
- `store discovered extensions`
- `getManifests`
- `autoUpdateExtensions`
- `activateExtensions`
- `connectToApi`

`activateExtensions` 内部还会记录单个扩展的资源加载耗时，名称格式为 `extension <name>: <stage>`：

- `locale`：加载扩展本地化文件。
- `script`：加载扩展 JS 入口。
- `style`：加载扩展 CSS。
- `activate total`：该扩展 locale、script、style 完成的总耗时。
- `import hook module activate`：动态导入扩展 hook 模块。
- `run hook activate`：执行扩展 `activate` hook。

## 当前虚拟机样本

测试环境：当前连接的 HarmonyOS 虚拟机，端口映射 `tcp:8000 -> tcp:8000`。

构建命令：

```powershell
$env:DEVECO_SDK_HOME='<DevEco SDK 路径>'
& '<DevEco Studio 路径>\tools\hvigor\bin\hvigorw.bat' assembleHap --no-daemon --mode module -p module=entry@default -p product=default
```

当前三次样本摘要：

| 样本 | 后端启动 | 前端总耗时 | 最大前端阶段 |
|------|----------|------------|--------------|
| 1 | 1035ms | 2716ms | `getSettings` 1396ms |
| 2 | 638ms | 2537ms | `getSettings` 1368ms |
| 3 | 146ms | 2470ms | `getSettings` 1298ms |

后端 listen 细拆复测样本：

| 样本 | 外部 wall-clock | 后端 init | 后端 listen | `server.listen` |
|------|-----------------|-----------|-------------|-----------------|
| 1 | 833ms | 19ms | 336ms | 330ms |
| 2 | 795ms | 15ms | 293ms | 277ms |
| 3 | 779ms | 21ms | 272ms | 265ms |
| 4 | 748ms | 15ms | 272ms | 264ms |
| 5 | 808ms | 16ms | 301ms | 294ms |
| 6 | 871ms | 18ms | 285ms | 277ms |
| 7 | 779ms | 21ms | 301ms | 288ms |
| 8 | 841ms | 16ms | 296ms | 289ms |

结论：后端构造阶段通常只有十几毫秒；`listenDurationMs` 主要由 OHOS `socket.TCPSocketServer.listen()` 消耗，约 260ms 到 330ms。外部从 `aa start` 到宿主机 curl 可访问的 wall-clock 通常约 0.75s 到 0.87s，包含 Ability 启动、调度、HDC 端口转发和轮询间隔，不等同于后端内部启动耗时。

稳定瓶颈：

- `getSettings`：约 1.3s，是最大前端瓶颈。
- `getCharacters`：约 0.36s 到 0.52s，是第二瓶颈。
- `hide startup loader`：约 0.28s 到 0.29s，是固定可感知延迟。
- `/api/settings/get` 后端 handler 约 19ms，说明 `getSettings` 慢点主要在前端处理/扩展加载，不在后端 settings 读取。
- `/api/characters/all` 后端 handler 约 0.32s 到 0.46s，说明角色列表读取本身有优化空间。

进一步细拆后确认：

- `getSettings: loadExtensionSettings` 约 1.1s 到 1.2s。
- `extensions: activateExtensions` 约 1.0s 到 1.1s，是 `getSettings` 内部最大子瓶颈。
- `third-party/ST-Prompt-Template` 激活约 543ms，其中 `script` 约 534ms。
- `third-party/JS-Slash-Runner` 激活约 126ms，其中 `script` 约 126ms。
- `quick-reply` 激活约 136ms，其中 `script` 约 136ms。
- `ST-Prompt-Template/dist/index.js` 约 5.08MB，`ST-Prompt-Template/libs/faker.mjs` 约 3.86MB。后端请求耗时只有几十到两百毫秒，主要慢在 WebView 的模块加载、解析和执行。

## 维护规则

- 新增启动阶段耗时锚点时，必须在本文档同步说明锚点含义。
- 调整 `firstLoadInit()` 顺序时，必须重新跑 `/api/ohos/startup/report` 并更新样本。
- 若调试接口准备长期保留，需要避免暴露敏感路径；当前接口只服务本机 `127.0.0.1:8000`。
- 若启动性能稳定后需要移除锚点，建议至少保留 `/api/ohos/backend/status` 和请求耗时采样接口，便于后续回归定位。
