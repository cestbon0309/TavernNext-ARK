# LAN Sync 双向互传实施规划

本文档用于规划在 `tavernnext-ohos` 中实现与 `TarvenNext` **行为完全一致** 的 LAN Sync（局域网同步）功能。

约束：

- 目标行为必须与 TarvenNext 当前 LAN Sync 保持一致
- 先规划，不在本文档内直接落实现
- 本文档在 `LAN_SYNC_COMPAT_ANALYSIS.md` 基础上，进一步补充：
  - 要实现的功能点
  - 鸿蒙可用 API
  - 详细文件落点
  - 高风险目录的真实用途与映射分析

---

## 1. 目标定义

需要实现的不是“类似同步”，而是与 TarvenNext 的 **LAN Sync** 完全一致的：

- 配对 URI
- 二维码配对
- 用户确认配对
- HMAC 签名
- manifest 扫描
- diff 计算
- pull / push 语义
- Mirror / Incremental 模式
- 进度事件
- 完成后刷新行为
- 已配对设备列表

不在第一阶段目标内：

- TT-Sync v2（HTTPS + spki pinning）
- 自动设备发现（mDNS / zeroconf）
- 与 TarvenNext 不一致的“增强版同步”

---

## 2. 需要实现的功能清单

### 2.1 服务端生命周期

必须实现：

- 启动 LAN Sync server
- 停止 LAN Sync server
- 查询状态
- 保存本地监听端口
- 获取设备可广播局域网地址列表
- 支持前端选择广播地址

### 2.2 配对

必须实现：

- 生成 Pair URI
- 生成二维码显示内容
- 配对 session（5 分钟过期）
- 通过 Pair URI 发起配对
- 服务端收到配对请求后发前端事件
- 前端弹窗 Allow / Deny
- 用户确认后生成 `pair_secret`
- 本地保存 paired device

### 2.3 请求签名

必须实现：

- `sha256_base64url(body)`
- canonical string：
  - `METHOD + "\\n" + PATH + "\\n" + body_hash`
- HMAC-SHA256(base64url)
- `derive_pair_secret(pair_code, source_device_id, target_device_id)`

### 2.4 同步模式

必须实现：

- `Incremental`
- `Mirror`
- session override
- persistent default
- Mirror 风险提示

### 2.5 manifest 与 diff

必须实现：

- 扫描白名单 scope
- 生成：
  - `relative_path`
  - `size_bytes`
  - `modified_ms`
- 计算：
  - `download`
  - `delete`
  - `files_total`
  - `bytes_total`

### 2.6 文件传输

必须实现：

- `GET /v1/sync/file/*path`
- 文件字节流下载
- 写入本地 sync root
- Mirror 模式删除多余文件

### 2.7 Pull / Push 语义

必须严格对齐 TarvenNext：

- Pull：本地主动拉取对端文件
- Push：本地只通知对端执行 `POST /v1/sync/pull`

不能改成：

- Push 直接上传文件

### 2.8 前端行为

必须实现：

- Sync 面板
- 状态区
- 地址选择
- 配对二维码与 URI
- 粘贴 URI 配对
- 扫码按钮
- 已配对设备列表
- Pull / Push / Remove
- 模式切换按钮
- 进度弹窗
- 错误弹窗
- Pull 完成后刷新

---

## 3. 鸿蒙可用 API 与现有基础

### 3.1 本地 TCP 服务端

可用能力：

- `@kit.NetworkKit`
- `socket.TCPSocketServer`

现有基础：

- [HttpServer.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/HttpServer.ets)

结论：

- 可以直接复用现有 HTTP server 机制实现 LAN Sync server
- 不需要新引入底层服务端库

### 3.2 HTTP 客户端

可用能力：

- `@kit.NetworkKit`
- `http.createHttp()`

现有基础：

- [RemoteHttpClient.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/RemoteHttpClient.ets)

结论：

- 可直接承接：
  - `POST /v1/pair`
  - `POST /v1/sync/plan`
  - `GET /v1/sync/file/*path`
  - `POST /v1/sync/pull`
- 需要在现有封装上增加少量定制：
  - 自定义签名 header
  - 原始 bytes 下载
  - 大 body JSON 支持

### 3.3 文件系统

可用能力：

- `@kit.CoreFileKit`
- `fileIo`

现有基础：

- [FileStore.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/FileStore.ets)

结论：

- manifest 扫描、字节落盘、删除文件都可直接复用现有封装

### 3.4 数据目录模型

现有基础：

- [DataDirectories.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/DataDirectories.ets)

结论：

- 当前项目已具备完整的 ST 兼容数据目录结构
- 适合作为 LAN Sync `sync_root`

### 3.5 二维码显示

SDK 已确认有：

- ArkUI `QRCode`

结论：

- 可选用原生二维码显示
- 但若追求与 TarvenNext 前端行为接近，也可以继续在网页端显示 SVG / data URL

### 3.6 扫码

SDK 已确认有：

- `@ohos.scan`
- 在 `@kit.BasicServicesKit` 中导出 `scan`

结论：

- 有原生扫码能力
- 推荐通过原生桥暴露给 WebView 前端

### 3.7 构建与调试能力

已验证：

- DevEco Studio 路径存在：`E:\\Huawei\\DevEco Studio`
- OpenHarmony SDK 路径存在：
  - `E:\\Huawei\\DevEco Studio\\sdk\\default\\openharmony`
  - `C:\\Users\\Cestbon\\AppData\\Local\\OpenHarmony\\Sdk\\23`
- `hvigorw.bat` 存在
- `hdc.exe` 存在
- `hdc list targets` 已连通目标：
  - `127.0.0.1:5555`
  - `192.168.50.236:38775`

结论：

- 实现后可直接本地构建 + hdc 安装 + 调试验证

---

## 4. 建议新增 / 修改的文件

### 4.1 后端协议与运行时

建议新增目录：

- `entry/src/main/ets/backend/sync/`

建议新增文件：

1. `LanSyncTypes.ets`
   - 定义所有 DTO / enum
2. `LanSyncStore.ets`
   - 管理 `config.json` / `identity.json` / `paired-devices.json`
3. `LanSyncCrypto.ets`
   - HMAC、hash、pair_secret 推导
4. `LanSyncPaths.ets`
   - 白名单 scope / 路径校验 / 排除规则
5. `LanSyncManifest.ets`
   - manifest 扫描与 diff
6. `LanSyncRuntime.ets`
   - pairing session、mode override、cache、事件
7. `LanSyncClient.ets`
   - pull / pair / plan / file download / trigger push
8. `LanSyncServer.ets`
   - `/v1/*` 路由处理
9. `LanSyncService.ets`
   - 对外业务入口

### 4.2 后端接入

建议修改：

1. [BackendService.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/BackendService.ets)
   - 初始化 `LanSyncService`
   - 注册 LAN Sync route
   - 注册给网页前端调用的管理接口

2. [HttpServer.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/HttpServer.ets)
   - 视需要增强：
     - wildcard path 处理
     - 更大 body 支持
     - 更稳的 bytes 响应

3. [HttpTypes.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/HttpTypes.ets)
   - 视需要补充状态码/stream 辅助

### 4.3 前端网页层

建议新增：

1. `entry/src/main/resources/rawfile/public/scripts/ohos-lan-sync.js`
   - 前端 API 封装
   - 事件监听
   - popup 控制

2. `entry/src/main/resources/rawfile/public/css/lan-sync.css`
   - Sync 面板样式

3. 视情况新增模板：
   - `entry/src/main/resources/rawfile/public/scripts/templates/lanSyncPopup.html`

建议修改：

4. [script.js](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/resources/rawfile/public/script.js)
   - 接入 Sync 入口

5. [popup.js](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/resources/rawfile/public/scripts/popup.js)
   - 若要复用现有 popup 体系，可能需要少量接入

### 4.4 原生桥

建议新增：

1. `entry/src/main/ets/backend/LanSyncNativeBridge.ets`
   - 扫码桥
   - 可能的系统分享/权限辅助

建议修改：

2. [Index.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/pages/Index.ets)
   - 注入扫码 JS bridge
   - 前端调用原生扫码
   - 回传 Pair URI

---

## 5. 高风险目录用途分析

这是当前兼容的第一大风险点。

### 5.1 TarvenNext 中几个特殊目录的真实用途

#### A. `default-user/extensions`

TarvenNext 用途：

- **local third-party extensions** 的实际安装目录

证据：

- `docs/CurrentState/ThirdPartyExtensions.md`
  - `local third-party 扩展：data/default-user/extensions/<folder>`
- `file_system.rs`
  - `default-user/extensions` 是默认用户数据目录的一部分
- `lan_sync/paths.rs`
  - `default-user/extensions` 被纳入 LAN Sync scope

说明：

- 这是用户级、本地级的第三方扩展安装目录
- 也是扩展代码本体实际存放位置

#### B. `extensions/third-party`

TarvenNext 用途：

- **global third-party extensions** 的实际安装目录

证据：

- `docs/CurrentState/ThirdPartyExtensions.md`
  - `global third-party 扩展：data/extensions/third-party/<folder>`
- `file_system.rs`
  - `global_extensions = root.join("extensions").join("third-party")`
- `lan_sync/paths.rs`
  - `extensions/third-party` 被纳入 LAN Sync scope

说明：

- 这是全局共享的第三方扩展安装目录
- 与 local 扩展并列

#### C. `_tauritavern/extension-sources/local`
#### D. `_tauritavern/extension-sources/global`

TarvenNext 用途：

- **扩展来源元数据目录**
- 不存扩展代码本体，存扩展来源与更新信息

证据：

- `docs/CurrentState/ThirdPartyExtensions.md`
  - `扩展来源元数据：data/_tauritavern/extension-sources/{local|global}/`
- `file_system.rs`
  - `extension_sources -> local/global`
- `file_extension_repository/source_store.rs`
  - 元数据包含：
    - `host`
    - `repo_path`
    - `reference`
    - `remote_url`
    - `installed_commit`

说明：

- 这是“扩展来源数据库”
- 用于：
  - update
  - version
  - move local/global
  - 迁移旧 metadata
- 不是浏览器直接读取的资源目录

### 5.2 TarvenNext 为什么把这些目录纳入 LAN Sync

原因很直接：

- 如果只同步 `default-user/extensions/<folder>` 或 `extensions/third-party/<folder>` 里的代码本体，
  目标设备仍然缺失“这个扩展来自哪里、当前追踪哪个 branch、安装 commit 是什么”的元数据。
- 那么扩展虽然能运行，但：
  - update/version/move 等行为会不完整
  - 与 TarvenNext 的扩展管理行为不一致

所以它把两类内容都同步：

- 扩展代码本体
- 扩展来源元数据

这就是为什么 LAN Sync scope 里既有：

- `default-user/extensions`
- `extensions/third-party`

又有：

- `_tauritavern/extension-sources/local`
- `_tauritavern/extension-sources/global`

---

## 6. 当前项目目录结构对照分析

### 6.1 当前项目已有的相关目录

从 [DataDirectories.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/DataDirectories.ets) 看，当前项目已有：

- `default-user/extensions`
- `default-user/backgrounds`
- `default-user/chats`
- `default-user/characters`
- `default-user/groups`
- `default-user/group chats`
- `default-user/worlds`
- `default-user/themes`
- `default-user/user`
- `default-user/User Avatars`
- `default-user/OpenAI Settings`
- `default-user/settings.json`

这部分与 TarvenNext 的 ST 数据目录相当接近。

### 6.2 当前项目的全局扩展目录

当前项目定义的是：

- `globalExtensionsRoot = <filesDir>/extensions/global`

而 TarvenNext 的 global third-party 目录是：

- `data/extensions/third-party`

这两者 **不一致**。

### 6.3 当前项目的扩展来源元数据目录

当前项目里没有看到与 TarvenNext 等价的：

- `_tauritavern/extension-sources/local`
- `_tauritavern/extension-sources/global`

也就是说：

- 你当前项目有扩展安装目录
- 但没有独立的“扩展来源元数据仓库”目录模型

### 6.4 当前项目的 third-party 资源暴露方式

[ExtensionsService.ets](/C:/Users/Cestbon/Desktop/TavernNext/TavernNext/tavernnext-ohos/entry/src/main/ets/backend/ExtensionsService.ets) 显示：

- 它已经接受 `third-party/<name>` 命名
- 已经能从多个 root 提供 `/scripts/extensions/third-party/*`

并且 local/global root 探测里实际上兼容了多种路径：

- local roots 包括：
  - `defaultUser.extensions`
  - `defaultUser.extensions/third-party`
  - `data/extensions`
  - `data/extensions/third-party`
  - 若干 legacy/public/scripts 路径
- global roots 包括：
  - `globalExtensionsRoot`
  - `data/globalExtensions`
  - `data/public/scripts/extensions/third-party`

这说明当前项目在“第三方扩展资源查找”上已经比较宽松，**但目录语义没有 TarvenNext 那么清晰统一**。

---

## 7. 风险结论与映射建议

### 7.1 风险结论

当前实现 LAN Sync 完全兼容时，最大的目录兼容风险有两个：

1. **Global third-party 根目录不一致**
   - TarvenNext: `data/extensions/third-party`
   - 当前项目: `<filesDir>/extensions/global`

2. **缺少 extension source metadata 目录**
   - TarvenNext: `data/_tauritavern/extension-sources/{local|global}`
   - 当前项目: 目前没有等价建模

### 7.2 若要求“行为完全一致”，建议映射策略

建议不要只做“协议兼容”，而要做 **目录语义兼容**。

最低建议：

#### A. 在当前项目中新增 TarvenNext 兼容目录模型

建议在数据目录模型中显式引入：

- `data/extensions/third-party`
- `data/_tauritavern/extension-sources/local`
- `data/_tauritavern/extension-sources/global`

理由：

- 这样最容易做到和 TarvenNext 完全一致
- 不需要在 LAN Sync 层临时做复杂路径重写
- 扩展代码本体和扩展来源元数据都能对齐

#### B. 保留现有目录，但做桥接/双写映射

如果不想破坏当前项目已有扩展逻辑，可以考虑：

- 对 `extensions/global` 与 `data/extensions/third-party` 做桥接
- 但这会增加实现复杂度

### 7.3 推荐方案

若优先目标是“与 TarvenNext 完全互传且后续维护最简单”，推荐：

- **引入 TarvenNext 的目录语义**
- 然后在当前项目扩展管理层适配这些目录

而不是：

- 在 LAN Sync 传输层临时把路径硬改来回映射

---

## 8. 实现顺序建议

### Phase 1：目录与状态建模对齐

先做：

- `LanSyncStore`
- `LanSyncPaths`
- 新的扩展来源元数据目录模型
- global third-party 目录对齐方案

### Phase 2：协议层实现

再做：

- `LanSyncCrypto`
- `LanSyncManifest`
- `LanSyncServer`
- `LanSyncClient`
- `LanSyncService`

### Phase 3：前端与扫码桥

最后做：

- Sync popup
- 二维码
- 扫码桥
- 进度/完成/错误事件

### Phase 4：构建与双向验证

使用：

- `hvigorw.bat`
- `hdc`

验证：

- 配对
- Pull
- Push
- Mirror delete
- 扩展目录互传
- 扩展来源元数据互传

---

## 9. 本阶段结论

要实现与 TarvenNext **完全一致** 的 LAN Sync，当前项目不是“完全不能做”，而是需要先解决目录语义问题：

- ST 兼容主数据目录大部分已经对齐
- 第三方扩展目录和扩展来源元数据目录尚未完全对齐

因此，真正开工实现前，必须先把这两个问题纳入设计：

1. 是否引入 `data/extensions/third-party`
2. 是否引入 `data/_tauritavern/extension-sources/{local|global}`

如果不引入，后面虽然也能“协议互通”，但会偏离“行为完全一致”的目标。
