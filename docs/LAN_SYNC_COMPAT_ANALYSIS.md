# TarvenNext 局域网同步兼容分析

本文档分析目录 `<TavernNext 工作区>\TarvenNext` 中现有“局域网同步”实现，目标是帮助 `tavernnext-ohos` 兼容其传输方式，实现与该项目的数据互传。

本文只做分析，不包含修改建议落地代码。

## 1. 总览

TarvenNext 里实际上有两套同步：

- `LAN Sync`：局域网内、HTTP 明文地址、二维码配对、HMAC 签名、面向同一 Wi‑Fi 设备互传。
- `TT-Sync`：更正式的 v2 同步，HTTPS + SPKI pinning + `ttsync-contract` crate，协议独立于 LAN Sync。

如果你的目标是“兼容那个项目当前的局域网同步传输方式”，优先需要兼容的是 **LAN Sync**，不是 TT-Sync。

核心入口文件：

- 前端设置面板入口：
  - `src/scripts/tauri/setting/setting-panel/settings-popup.js`
  - `src/scripts/tauri/setting/setting-panel/sync-popup.js`
  - `src/scripts/tauri/setting/setting-panel/pairing-listener.js`
  - `src/scripts/tauri/setting/setting-panel/sync-listeners.js`
- Tauri command：
  - `src-tauri/src/presentation/commands/lan_sync_commands.rs`
- 应用服务：
  - `src-tauri/src/application/services/lan_sync_service.rs`
- LAN Sync 协议实现：
  - `src-tauri/src/infrastructure/lan_sync/server.rs`
  - `src-tauri/src/infrastructure/lan_sync/client.rs`
  - `src-tauri/src/infrastructure/lan_sync/manifest.rs`
  - `src-tauri/src/infrastructure/lan_sync/paths.rs`
  - `src-tauri/src/infrastructure/lan_sync/crypto.rs`
  - `src-tauri/src/infrastructure/lan_sync/store.rs`
  - `src-tauri/src/infrastructure/lan_sync/runtime.rs`

## 2. 前端交互流程

前端所有 Sync UI 都集中在 `sync-popup.js`。

LAN Sync 面板具备这些能力：

- 启动/停止本机 LAN Sync server
- 开启配对（生成 Pair URI + QR SVG）
- 手动粘贴 Pair URI 配对
- 手机扫码 Pair URI 配对
- 列出已配对设备
- 对设备执行：
  - Pull：`lan_sync_sync_from_device`
  - Push：`lan_sync_push_to_device`
- 设置同步模式：
  - `Incremental`
  - `Mirror`

相关 invoke：

- `lan_sync_get_status`
- `lan_sync_start_server`
- `lan_sync_stop_server`
- `lan_sync_enable_pairing`
- `lan_sync_get_pairing_info`
- `lan_sync_request_pairing`
- `lan_sync_confirm_pairing`
- `lan_sync_list_devices`
- `lan_sync_remove_device`
- `lan_sync_sync_from_device`
- `lan_sync_push_to_device`
- `lan_sync_set_sync_mode`
- `lan_sync_clear_sync_mode_override`

相关事件：

- `lan_sync:pair_request`
- `lan_sync:progress`
- `lan_sync:completed`
- `lan_sync:error`

这说明如果 `tavernnext-ohos` 要做到“行为兼容”，至少前端层要能理解并驱动上述状态机。

## 3. 配对 URI 与二维码格式

Pair URI 在 `lan_sync_service.rs` 中构造。

协议格式：

- scheme: `tauritavern://lan-sync/pair`
- query:
  - `v=1`
  - `addr=<http://ip:port>`
  - `pair_code=<random base64url>`
  - `exp=<expires_at_ms>`

示意：

```text
tauritavern://lan-sync/pair?v=1&addr=http%3A%2F%2F192.168.1.12%3A50321&pair_code=...&exp=...
```

几点要点：

- 地址是 **HTTP**，不是 HTTPS。
- `pair_code` 是后续配对签名密钥的根材料。
- 过期时间默认 5 分钟。
- 二维码内容就是这个完整 Pair URI。

要兼容该项目，`tavernnext-ohos` 至少要能：

- 生成完全相同语义的 Pair URI
- 解析这个 Pair URI
- 从中提取 `addr / pair_code / exp`

## 4. 设备身份与本地存储

LAN Sync 本地状态保存在：

- `default-user/user/lan-sync/config.json`
- `default-user/user/lan-sync/identity.json`
- `default-user/user/lan-sync/paired-devices.json`

其中：

- `config.json`
  - `port`
  - `sync_mode`
- `identity.json`
  - `device_id`
  - `device_name`
- `paired-devices.json`
  - `device_id`
  - `device_name`
  - `pair_secret`
  - `last_known_address`
  - `paired_at_ms`
  - `last_sync_ms`

注意：

- `device_id` 是 UUID。
- `device_name` 默认 `"TauriTavern"`。
- `pair_secret` 是后续所有 LAN Sync HTTP 请求签名用的共享密钥。

## 5. 配对握手协议

### 5.1 被配对方

启动 LAN server 后暴露：

- `POST /v1/pair`

请求体结构：

```json
{
  "target_device_id": "uuid",
  "target_device_name": "device-name",
  "target_port": 50321
}
```

签名头：

- `X-TT-Signature`

签名算法：

- key = `pair_code.as_bytes()`
- canonical = `METHOD + "\n" + PATH + "\n" + sha256_base64url(body)`
- HMAC-SHA256
- base64url(no padding)

这里 PATH 固定是：

```text
/v1/pair
```

### 5.2 配对确认

服务端收到请求后不会立即接受，而是：

- 发前端事件 `lan_sync:pair_request`
- 用户在弹窗里 Allow / Deny
- 前端调用 `lan_sync_confirm_pairing`

如果用户允许，服务端会生成 `pair_secret`：

```text
derive_pair_secret(pair_code, source_device_id, target_device_id)
```

实现方式：

- HMAC-SHA256
- key = `pair_code`
- message 依次拼：
  - `"TT-LANSYNC-PAIR-SECRET"`
  - `source_device_id`
  - `target_device_id`
- 输出 base64url

### 5.3 配对响应

响应体：

```json
{
  "source_device_id": "uuid",
  "source_device_name": "device-name"
}
```

请求方拿到响应后，用相同规则推导 `pair_secret`，并保存到本地 paired devices。

### 5.4 兼容要求

如果 `tavernnext-ohos` 想与它互配对，必须兼容：

- Pair URI 解析
- `POST /v1/pair`
- `X-TT-Signature` 签名算法
- `derive_pair_secret()` 推导规则
- 同样的 request / response JSON 结构

## 6. 同步模式

LAN Sync 有两种模式：

- `Incremental`
- `Mirror`

含义：

- `Incremental`：只下载缺失/变化文件，不删除目标多余文件
- `Mirror`：在增量基础上，额外删除目标端存在但源端不存在的文件

前端把 `Mirror` 标记为高风险，会专门弹警告。

兼容时你的项目至少要理解这两个模式，并且 Mirror 删除语义要对齐。

## 7. 同步传输协议

### 7.1 本机作为服务端暴露的 HTTP 路由

`server.rs` 中 LAN Sync server 暴露：

- `GET /v1/status`
- `POST /v1/pair`
- `POST /v1/sync/pull`
- `POST /v1/sync/plan`
- `GET /v1/sync/file/*path`

### 7.2 状态检查

`GET /v1/status`

返回：

```json
{ "ok": true }
```

这个接口非常简单，主要是可达性探测。

### 7.3 Pull / Push 的真实语义

#### Pull

前端点击“从对端拉取”后，本地调用：

- `lan_sync_sync_from_device`

实现逻辑在 `client.rs::merge_sync_from_device()`：

1. 扫描本地 sync scope，生成 `target_manifest`
2. 请求对端 `POST /v1/sync/plan`
3. 对端返回 diff plan
4. 逐个 `GET /v1/sync/file/<relative_path>` 下载
5. 如果 Mirror 模式，执行 delete 列表

所以 `pull` 的本质是：

- **本地发起**
- 对端根据“它的源清单”和“我的目标清单”算差异
- 我从对端下载需要的文件

#### Push

前端点击“推送到对端”后，本地调用：

- `lan_sync_push_to_device`

它不是直接上传文件，而是：

- 给对端发 `POST /v1/sync/pull`

也就是说：

- **Push 实际上是请求对端主动执行一次 Pull**

这一点很关键。  
如果你想完全兼容 TarvenNext 的交互语义，`push_to_device` 不一定需要做“上传 API”，而要支持“通知对方来拉”。

### 7.4 认证头

除 `/v1/status` 外，同步接口都要签名。

头部：

- `X-TT-Device-Id`
- `X-TT-Signature`

签名算法：

- key = `pair_secret.as_bytes()`
- canonical = `METHOD + "\n" + PATH + "\n" + sha256_base64url(body)`
- HMAC-SHA256 -> base64url

注意：

- `GET /v1/sync/file/<path>` 的 PATH 必须是完整 canonical path
- body 为空时签的是空 body 的 hash

## 8. Manifest 与 Diff Plan

### 8.1 Manifest 结构

```json
{
  "entries": [
    {
      "relative_path": "default-user/chats/foo.jsonl",
      "size_bytes": 1234,
      "modified_ms": 1710000000000
    }
  ]
}
```

### 8.2 Diff Plan 结构

```json
{
  "download": [
    {
      "relative_path": "...",
      "size_bytes": 1234,
      "modified_ms": 1710000000000
    }
  ],
  "delete": [
    "default-user/chats/bar.jsonl"
  ],
  "files_total": 12,
  "bytes_total": 34567
}
```

### 8.3 Diff 规则

`diff_manifests(source, target)` 的含义是：

- `download`
  - source 里有，target 里没有
  - 或 size / modified_ms 不一致
- `delete`
  - target 里有，source 里没有

这里没有内容 hash，比的是：

- `relative_path`
- `size_bytes`
- `modified_ms`

这意味着如果你要兼容它，最稳妥的做法是：

- 你的 manifest 也生成这三个字段
- 且 `modified_ms` 语义与它保持一致（文件 mtime 毫秒时间戳）

## 9. 同步范围（非常重要）

LAN Sync 不是全目录同步，而是白名单 scope。

允许目录：

- `default-user/chats`
- `default-user/characters`
- `default-user/groups`
- `default-user/group chats`
- `default-user/worlds`
- `default-user/themes`
- `default-user/user`
- `default-user/User Avatars`
- `default-user/OpenAI Settings`
- `default-user/extensions`
- `default-user/backgrounds`
- `extensions/third-party`
- `_tauritavern/extension-sources/local`
- `_tauritavern/extension-sources/global`

允许文件：

- `default-user/settings.json`

排除：

- `default-user/user/lan-sync`

几个关键点：

- 路径必须使用 `/`
- 不允许绝对路径
- 不允许 `.` / `..`
- 不允许 scope 外文件
- 不允许同步自己的 LAN Sync 状态目录
- symlink 明确不支持

如果 `tavernnext-ohos` 要兼容互传，必须先决定：

1. 你要不要完全照搬这套 scope
2. 还是只做协议兼容，但做路径映射

如果目标是“直接与它互传且不出错”，建议兼容层至少支持它发送出来的这些 `relative_path`。

## 10. 文件传输行为

文件下载接口：

- `GET /v1/sync/file/<relative_path>`

响应：

- `Content-Type: application/octet-stream`
- `Content-Length: <file size>`
- body = 原始文件流

下载端根据 `relative_path` 写回本地 `sync_root`。

并发：

- 移动端默认并发更低
- 桌面并发更高
- `sync_transfer.rs` 中给了公共并发策略

这说明 LAN Sync 本质是：

- manifest 比对
- file-by-file 拉取
- 非 bundle 模式
- 非压缩归档模式

## 11. 前端事件与用户体验语义

LAN Sync 的用户可见事件：

- `lan_sync:pair_request`
  - 用于对端弹确认框
- `lan_sync:progress`
  - phase + files_done + files_total + bytes_done + bytes_total + current_path
- `lan_sync:completed`
  - files_total + bytes_total + files_deleted
- `lan_sync:error`
  - message

完成后：

- 前端会弹完成框
- 然后 `window.location.reload()`

这意味着互通兼容不只是传输成功，还包括：

- 同步完成后本地数据刷新策略
- 是否需要 reload / 重建缓存

## 12. 与 TT-Sync 的区别

不要把 LAN Sync 和 TT-Sync 混在一起。

TT-Sync 的特点：

- 使用 `ttsync-contract`
- `https`
- SPKI pinning
- `Authorization: Bearer <session_token>`
- 有 `/v2/session/open`、plan、bundle、upload/download 等更正式接口

LAN Sync 的特点：

- 轻量
- 纯局域网
- `http`
- HMAC request signing
- Pair URI + QR
- manifest + file 拉取

如果你的目标是兼容“那个项目当前用户能用的局域网同步”，优先实现 LAN Sync 即可。

## 13. 对 `tavernnext-ohos` 的兼容意义

如果要让你的项目和 TarvenNext 互传，最低兼容面建议分三层：

### Level 1：只兼容接收 TarvenNext 推送/拉取

最少需要：

- 能解析 `tauritavern://lan-sync/pair?...`
- 能响应：
  - `POST /v1/pair`
  - `POST /v1/sync/plan`
  - `GET /v1/sync/file/*path`
  - `POST /v1/sync/pull`
- 能生成 TarvenNext 兼容 manifest
- 能按 TarvenNext 的 diff 语义下载/删除

### Level 2：完整双向互传

除了 Level 1，还要：

- 主动请求 TarvenNext 的 `/v1/pair`
- 保存 paired device 状态
- 用 `X-TT-Device-Id` / `X-TT-Signature` 发起：
  - `/v1/sync/plan`
  - `/v1/sync/file/*path`
  - `/v1/sync/pull`

### Level 3：UI 行为兼容

再额外兼容：

- Pairing QR 显示
- 配对确认弹窗
- 进度事件
- 完成后刷新策略
- `Incremental / Mirror` 模式切换

## 14. 最值得先确认的兼容风险

在你真正实现兼容前，建议优先确认这些点：

1. **路径映射风险**
   - TarvenNext 用的是桌面 Tauri 版目录结构
   - `tavernnext-ohos` 的数据目录是否能稳定映射到这些 `relative_path`

2. **mtime 语义风险**
   - TarvenNext diff 依赖 `modified_ms`
   - HarmonyOS 文件时间戳精度/可用性是否一致

3. **文件 scope 风险**
   - 你的项目是否真的拥有这些目录
   - 若缺少部分目录，对端 manifest 应如何处理

4. **安全模型风险**
   - LAN Sync 是 `http + shared secret HMAC`
   - 局域网可信假设较强
   - 若你后续要对外开放，安全等级不如 TT-Sync

5. **刷新与缓存风险**
   - TarvenNext pull 完成后会刷新 runtime caches 并 reload
   - 你的项目如果内部缓存较多，也要有对应刷新边界

## 15. 结论

TarvenNext 的“局域网同步”不是通用网盘协议，而是一套相对简单但完整的：

- Pair URI / QR 配对
- HMAC 鉴权
- manifest diff
- file-by-file download
- optional mirror delete
- local app refresh

如果 `tavernnext-ohos` 要与它互通，最核心要兼容的是：

1. Pair URI 解析与生成
2. `POST /v1/pair`
3. HMAC canonical signing:
   - `METHOD + "\\n" + PATH + "\\n" + sha256_base64url(body)`
4. `derive_pair_secret()` 规则
5. manifest / diff plan JSON 结构
6. `/v1/sync/plan`
7. `/v1/sync/file/*path`
8. `/v1/sync/pull`
9. 相同的 sync scope 与路径合法性约束

如果后面要进入设计阶段，我建议先以 **Level 2 双向互传兼容** 为目标，再决定是否要把 UI 行为也做到接近 TarvenNext。
