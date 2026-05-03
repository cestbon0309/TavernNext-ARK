# TavernNext OHOS 迁移要求

本文档记录当前 SillyTavern -> HarmonyOS ArkTS 迁移过程中已经明确下来的工程约束。后续实现接口、整理数据结构、接入系统能力时，必须先对照这里的要求。

## 1. data 目录铁律

- `data/` 目录的数据结构必须和原版 SillyTavern 严格一致。
- 任何会被 SillyTavern 原版保存的数据，必须继续写入对应的原版路径和文件格式。
- 不允许在 `data/default-user/` 下新增 OHOS 专用目录、临时文件、分享中转文件或系统交互状态。
- 目录名的大小写、空格和层级必须保持原样，例如：
  - `User Avatars`
  - `group chats`
  - `NovelAI Settings`
  - `OpenAI Settings`
  - `TextGen Settings`
  - `QuickReplies`
- 当前固定为单用户兼容目录：

```text
<context.filesDir>/data/default-user/
```

## 2. 导出与 ShareKit

- 所有导出类能力不能直接把文件写到公共目录，也不能把导出中转文件放入 `data/default-user/`。
- 导出必须先写入应用私有目录：

```text
<context.filesDir>/exports/
```

- 分类导出目录示例：

```text
<context.filesDir>/exports/characters/
<context.filesDir>/exports/chats/
```

- 写入私有导出文件后，必须调用 HarmonyOS 官方 ShareKit，由用户决定保存或分享目标。
- ShareKit 当前采用官方 SDK API：
  - `@kit.ShareKit`：`systemShare.SharedData`、`systemShare.ShareController`
  - `@kit.CoreFileKit`：`fileUri.getUriFromPath(path)`
  - `@kit.ArkData`：`uniformTypeDescriptor`
- 如果 ShareKit 唤起失败，接口可以返回错误，但响应应尽量保留私有导出文件的 `path`、`uri`、`file_name`，方便调试。
- 前端下载逻辑需要适配：OHOS 版导出接口返回 JSON 结果，不走浏览器 Blob 下载。

## 3. 架构边界

- `SillyTavernCore` 负责 SillyTavern 兼容的数据结构、接口行为和本地文件读写。
- `DataDirectories` 只负责创建和暴露目录路径，并保持 `data/` 与 `exports/` 的边界清晰。
- `ShareExportService` 负责私有导出文件写入、文件 URI 生成和 ShareKit 调用。
- `PngCardStore` 负责 PNG 角色卡元数据读写。
- `HttpServer` 只做 HTTP 解析、路由分发和 multipart/json 解析，不塞业务规则。
- OHOS 适配代码不应污染 SillyTavern 数据结构。

## 3.1 Git 能力边界

- ArkTS 后端不手写 Git 协议，也不假设设备里存在系统 `git` 命令。
- 第三方扩展安装、更新、分支切换、版本状态查询应走 native `.so` + `libgit2` 路线。
- ArkTS 只负责 SillyTavern HTTP API 兼容、路径校验、local/global 目录策略和错误响应；native 层只暴露 clone/fetch/pull/checkout/status 等受限能力。管理接口必须复用扩展发现/静态加载的兼容目录解析，并在进入 native 前确认目标是带 `.git` 的真实仓库，保证从 SillyTavern data 备份导入的 `extensions/third-party/<name>`、`public/scripts/extensions/third-party/<name>` 等结构可以被查询版本和删除；如果存在同名 Git clone，则更新动作应优先落到 Git clone。
- Git 目标收敛为常见公开 HTTPS Git 托管平台的基础兼容，例如 GitHub、GitLab、Gitee、Bitbucket；优先保障 SillyTavern 第三方扩展的安装、更新、版本状态、分支列表和分支切换。
- 当前不把 ArkTS 后端做成完整 Git 客户端，复杂仓库工作流不进入主线目标。
- Git 操作的目标路径必须限制在扩展目录内，不能写入 `data/default-user/` 之外的任意位置，也不能执行仓库 hooks。
- 第一阶段已按该路线接入 `libtavern_git.so`，支持 HTTPS 公共仓库 clone/fetch/status/branch/checkout 和 fast-forward 更新。
- private credential、SSH、submodule、merge 冲突处理和 hooks 执行仍后置。
- `libgit2` 使用 mbedTLS，应用内打包 CA bundle，启动时复制到 `<context.filesDir>/_certs/cacert.pem` 后显式传给 native Git；默认不得关闭 TLS 证书校验。

## 3.2 多用户能力边界

- 当前 App 形态不需要多用户系统，默认固定使用 `data/default-user/`。
- `/api/users/*` 只作为本地账号弹窗、密码校验、头像记录和数据备份/恢复兼容层存在。
- 不启用真实 session、cookie-session、当前用户切换、权限中间件和 `enable_accounts=true` 完整流程。
- 后续补功能时不要为了兼容 users 路由而改动核心角色、聊天、设置接口的默认用户路径。

## 4. 工程与调试要求

- 基于用户用 DevEco Studio 创建的空项目继续开发，项目目录为：

```text
tavernnext-ohos/
```

- 优先使用华为官方 SDK/API 声明，避免凭空写不存在的 ArkTS 接口。
- 当前可使用 DevEco 模拟器和 `hdc` 做安装、启动、HTTP API 验证。
- 已配置签名，构建产物可直接安装：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

## 5. 阶段提交要求

- 每完成一个大阶段必须 `git commit`，方便回滚。
- 阶段应尽量边界清楚，例如：
  - 前端启动基线
  - 接口文档整理
  - 角色导入/导出
  - 角色管理
  - 聊天记录管理
  - 媒体上传
  - 设置/预设
  - 模型代理
- 提交前应尽量完成：
  - ArkTS 构建验证
  - 模拟器安装/启动验证
  - 关键 API 烟测
  - 文档同步

## 6. 当前优先级

- 目标是尽可能先让 SillyTavern 前端在手机/模拟器上跑起来。
- 优先补齐前端启动、角色、聊天、设置等本地数据接口。
- OpenAI/OpenAI-compatible chat-completions、OpenAI/tiktoken native tokenizer、第三方扩展 Git 和 vector 最小索引已有可用路径；非 OpenAI tokenizer、完整 provider 适配、原版等价向量索引和复杂外部服务可以继续分阶段后置。
- 所有后续实现必须继续遵守 `data/` 结构兼容和 ShareKit 导出规则。
