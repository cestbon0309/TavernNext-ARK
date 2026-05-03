# TavernNext-ARK

TavernNext-ARK 是一个将 SillyTavern 移植到 HarmonyOS 的 ArkTS 工程。项目保留 SillyTavern 前端体验，把原版 Node.js 后端使用ArkTS重写。



## 下载地址

一、前往Release页面下载预编译的二进制文件（或自行编译）

二、前往https://github.com/likuai2010/auto-installer/releases/tag/3.1.0  下载小白调试助手

三、连接手机至电脑，在小白调试助手上登录你的华为账号。建议申请开发者资格，这样单次签名的有效期会延长到90天，否则只有14天有效期。

四、签名并安装



## 当前进度

目前已实现常用的几乎所有功能，包括插件、预设、世界书。

插件部分酒馆助手已适配。







## 目录结构

```text
<repo>/
  AppScope/                         HarmonyOS 应用级配置
  entry/                            主 HarmonyOS 模块
    src/main/ets/                   ArkTS 应用、WebView 和后端代码
    src/main/cpp/                   Git/tokenizer native NAPI 模块
    src/main/resources/rawfile/     内置 SillyTavern 前端和默认内容
  native/tavern_tokenizer_ffi/      Rust MikTik FFI 桥接层
  third_party/libgit2/              Git native 依赖
  third_party/mbedtls/              libgit2 HTTPS/TLS 依赖
  third_party/miktik/               tokenizer 依赖
  scripts/                          本地开发辅助脚本
```

重要运行时目录：

```text
<app filesDir>/data                 SillyTavern 兼容运行时数据
<app filesDir>/exports              导出和分享中转目录
<app filesDir>/_restore             data 恢复临时工作目录
```

## 环境要求

推荐开发环境：

- Windows。
- DevEco Studio。
- HarmonyOS SDK `6.0.0(20)`。
- DevEco 命令行工具，包括 `hvigorw`、`hdc`、CMake 和 OpenHarmony native toolchain。
- Git，且支持 submodule。
- Rust toolchain，确保 `cargo` 在 `PATH` 中可用。
- Rust OHOS targets：

```powershell
rustup target add x86_64-unknown-linux-ohos
rustup target add aarch64-unknown-linux-ohos
```

Deveco Studio模拟器需要 `x86_64-unknown-linux-ohos`，真机需要 `aarch64-unknown-linux-ohos`。

## 获取源码

推荐直接带 submodule 克隆：

```powershell
git clone --recurse-submodules <repo-url> TavernNext
cd TavernNext
git submodule update --init --recursive
```

如果已经普通克隆过，再执行：

```powershell
git submodule update --init --recursive
```

native Git 和 tokenizer 依赖这些子模块：

```text
third_party/libgit2
third_party/mbedtls
third_party/miktik
```

## 签名配置与隐私

`build-profile.json5` 是 HarmonyOS 构建所需文件，但真实签名材料路径和密码不能提交到公开仓库。

仓库里应该只保存脱敏模板。脱敏值示例：

```text
<local-ohos-cert.cer>
<local-ohos-profile.p7b>
<local-ohos-keystore.p12>
<local-key-password>
<local-store-password>
```

开发者克隆后，建议安装本地 Git clean filter 和 pre-commit hook：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-git-hooks.ps1
```

它会在提交 `build-profile.json5` 时尽量替换本地签名路径和密码。即使安装了 hook，也请在提交前检查：

```powershell
git diff --cached
```

如果 DevEco Studio 把 `build-profile.json5` 改成了你的本地签名配置，保留在本地即可。不要发布 `.cer`、`.p7b`、`.p12`、签名密码、API key、用户导入数据或运行时 `data/` 备份。

## 使用 DevEco Studio 编译

1. 用 DevEco Studio 打开 `<repo>`。
2. 确认工程 SDK 为 HarmonyOS `6.0.0(20)`。
3. 在 DevEco Studio 的签名配置里配置本地 debug 或 release 签名。
4. 确认 DevEco 构建环境能找到 `cargo`。如果找不到，把 Rust 的 cargo 目录加入系统 `PATH`，然后重启 DevEco Studio。
5. 按提示同步工程依赖。
6. 构建 `entry` 模块，product 选择 `default`。
7. 构建成功后，HAP 通常输出到：

```text
<repo>/entry/build/default/outputs/default/entry-default-signed.hap
```

构建过程中 CMake 会同时编译两个 native 模块：

- `libtavern_git.so`：基于 `libgit2` 和 `mbedTLS`。
- `libtavern_tokenizer.so`：基于 Rust `miktik` FFI bridge。

第一次 native 构建会比较慢，因为需要编译 Rust 依赖和 native 库。

## 使用命令行编译

下面命令里的路径都需要替换成你本机的实际安装位置，不要把真实路径提交到仓库：

```powershell
cd <repo>
$env:DEVECO_SDK_HOME = '<DevEco SDK path>'
& '<DevEco Studio path>\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default
```

路径形态示例：

```text
<DevEco Studio path>\tools\hvigor\bin\hvigorw.bat
<DevEco SDK path>\default\openharmony\toolchains\hdc.exe
```

构建成功后输出：

```text
<repo>/entry/build/default/outputs/default/entry-default-signed.hap
```

如果提示找不到 Rust 或 `cargo`，检查：

```powershell
cargo --version
rustup target list --installed
```

如果提示找不到 `third_party` 里的文件，重新拉取 submodule：

```powershell
git submodule update --init --recursive
```

如果签名失败，回到 DevEco Studio 配置本地签名后重新构建。不要通过提交真实签名路径或密码来解决签名问题。

## 安装和启动

安装生成的 HAP：

```powershell
& '<DevEco SDK path>\default\openharmony\toolchains\hdc.exe' install -r .\entry\build\default\outputs\default\entry-default-signed.hap
```

启动应用：

```powershell
& '<DevEco SDK path>\default\openharmony\toolchains\hdc.exe' shell aa start -a EntryAbility -b com.esoteric.ark.tavernnext
```

停止应用：

```powershell
& '<DevEco SDK path>\default\openharmony\toolchains\hdc.exe' shell aa force-stop com.esoteric.ark.tavernnext
```

如果连接了多个设备，在 `hdc.exe` 后追加 `-t <device-id>`。

## 后端调试

把设备或模拟器里的本地后端端口映射到宿主机：

```powershell
& '<DevEco SDK path>\default\openharmony\toolchains\hdc.exe' fport tcp:8000 tcp:8000
```

检查后端状态：

```powershell
curl.exe -i http://127.0.0.1:8000/health
curl.exe -i -X POST http://127.0.0.1:8000/api/ping
```

也可以在桌面浏览器打开前端调试：

```text
http://127.0.0.1:8000/
```

常用调试接口：

```powershell
curl.exe -i http://127.0.0.1:8000/api/extensions/discover
curl.exe -i http://127.0.0.1:8000/api/dev/llm-api-logs/settings
curl.exe -N http://127.0.0.1:8000/api/dev/llm-api-logs/stream
```

## 数据导出和恢复

在应用内进入拓展页面，打开 `数据导出/恢复` 区域。

- 导出：压缩 `<app filesDir>/data`，生成 zip 后调用系统分享。
- 恢复：弹窗确认覆盖后，由 ArkTS 后端唤起 HarmonyOS 文件选择器选择 zip，解压、校验 data 结构，然后覆盖当前 `<app filesDir>/data`。

恢复 data zip 会覆盖当前应用数据，请先确认备份来源可信。

## 开发注意事项

- 默认以 SillyTavern 数据兼容为设计约束。
- TavernNext 自己的临时文件不要写进 `<app filesDir>/data/default-user`。
- 导出和恢复中转文件放在 `<app filesDir>/exports` 或 `<app filesDir>/_restore`。
- 平台能力优先使用 HarmonyOS 官方 API，例如 zlib、图片处理、文件选择器和分享。
- native 依赖尽量限制在 `entry/src/main/cpp`、`native/` 和 `third_party/`。
- 为了兼容第三方拓展，优先修复 TavernNext 的兼容层，不要修改用户导入的拓展和脚本。

发布前至少检查：

```powershell
git status --short
git diff --cached
```

公开文档和提交记录中应使用 `<repo>`、`<DevEco Studio path>`、`<DevEco SDK path>`、`<device-id>` 这类占位符，不要出现本机绝对路径、用户名、签名文件路径、密码或 API key。

## 致谢

[SillyTavern](https://github.com/SillyTavern/SillyTavern)

[MikTik](https://github.com/Darkatse/MikTik)

