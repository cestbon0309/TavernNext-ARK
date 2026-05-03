# 模型调用、Tokenizer、Vector 移植思路

本文记录 SillyTavern 原版、TauriTavern Rust 后端，以及当前 OHOS ArkTS 移植在三块核心功能上的实现思路和可借鉴方案。

当前结论：

- 模型调用表面是 HTTP API，实际核心工作是 provider payload 转换、鉴权配置、流式转发、错误归一化和响应包装。
- Tokenizer 不是普通远程 API，原版大量依赖 Node/WASM/native tokenizer 包和 tokenizer 资源文件；OHOS 侧建议走 native `.so`/NAPI 接 MikTik。
- Vector 分为 embedding provider 调用和本地向量索引两层；TauriTavern 当前没有看到完整 vector index 实现，不能直接照抄。

当前实现状态：

- 已完成 OpenAI chat-completions 最小可用代理：`POST /api/backends/chat-completions/status`、`POST /api/backends/chat-completions/generate`、`POST /api/openai/generate`。
- 当前可用来源是 `openai` 和 `custom`。`status` 会访问 `<base>/models`，`generate` 会访问 `<base>/chat/completions`；custom 来源允许使用 OpenAI-compatible API 端点。
- OpenAI `generate` 支持非流式 JSON 响应和流式 `text/event-stream` 透传；请求体会清理 SillyTavern 内部字段，只转发 OpenAI 接受的字段。
- 2026-05-03 已验证流式链路：前端打开 OpenAI/Chat Completion 的 `Streaming` 后会发送 `stream: true`；ArkTS 后端使用 Harmony `requestInStream()` 监听 `dataReceive`，SSE 分块可以即时到达前端。
- text-completions、NovelAI、Horde、Stable Diffusion 已有基础代理/查询路由；OpenRouter/DeepSeek/Groq/Mistral 等 OpenAI-compatible provider 目前应通过 `custom` 端点使用，专门 source 尚未逐项放行和验证。
- Tokenizer native bridge 已按推荐路线落地：MikTik 作为 Rust FFI staticlib 编译到 OHOS native module，ArkTS 通过 NAPI 调用真实 encode/decode/count；当前已覆盖 SillyTavern 本地 tokenizer 路由，包括 OpenAI/tiktoken、GPT-2、旧 OpenAI text/embedding 模型、Claude、DeepSeek、Gemma、Llama/Llama 3、Mistral、Yi、Jamba、Nerdstash/Nerdstash v2、Qwen2、Command-R/Command-A 和 Nemo。
- Vector 已有 ArkTS 可用实现：本地 JSON 索引、insert/list/delete/query/query-multi/purge、批量 remote embedding provider 调用和 hash fallback；常用 provider 请求形状已补，但还不是原版 `vectra.LocalIndex` 等价实现。
- Claude/Gemini/OpenRouter/DeepSeek/Cohere/Vertex 等 chat-completion provider builder 已按 TauriTavern 逻辑完成常用主路径；tokenizer 当前主要剩余风险是和原版 WASM/Node 实现在极端特殊 token、chunks 展示和大资源包体积上的细节差异。

## 0. 当前落地结论

第一阶段模型调用目标已经达到“最小可用”：用户可以配置 OpenAI 或 OpenAI-compatible 自定义端点/API key，完成模型列表检查、非流式生成和流式生成。这个阶段只解决最常用的 chat-completions 主路径，不试图一次性补齐所有 provider 的差异转换。

下一阶段如果继续模型侧，优先补 OpenAI-compatible 的边界细节：错误响应格式、请求取消、中断后的连接清理、更多 OpenAI 参数、custom headers/body/exclude body 的兼容测试，以及 OpenRouter/DeepSeek/Groq/Mistral 等“基本仍是 OpenAI 形状”的 provider。Claude/Gemini 因为 payload 和流式事件格式差异大，应作为独立 builder 分阶段实现。

## 1. 原版 SillyTavern

### 1.1 路由挂载位置

原版入口在 `SillyTavern/src/server-startup.js`：

- `/api/tokenizers` -> `src/endpoints/tokenizers.js`
- `/api/vector` -> `src/endpoints/vectors.js`
- `/api/horde` -> `src/endpoints/horde.js`
- `/api/sd` -> `src/endpoints/stable-diffusion.js`
- `/api/backends/chat-completions` -> `src/endpoints/backends/chat-completions.js`
- `/api/backends/text-completions` -> `src/endpoints/backends/text-completions.js`

这些路由大多服务前端兼容层，不只是把请求原样代理到外部服务。

### 1.2 模型调用实现方式

#### Chat Completions

文件：`SillyTavern/src/endpoints/backends/chat-completions.js`

主要接口：

- `POST /api/backends/chat-completions/status`
- `POST /api/backends/chat-completions/bias`
- `POST /api/backends/chat-completions/generate`
- `POST /api/backends/chat-completions/process`
- `POST /api/backends/chat-completions/multimodal-models/*`

原版支持的 provider 分支包括 OpenAI、OpenRouter、Claude、Gemini/MakerSuite、VertexAI、Mistral、Cohere、DeepSeek、xAI、AIMLAPI、Groq、Moonshot、Fireworks、NanoGPT、Chutes、Azure OpenAI、Z.AI、SiliconFlow、Custom 等。

关键行为：

- 根据 `chat_completion_source` 选择 endpoint、secret key、headers。
- 对 OpenAI 兼容 provider 构造 `/chat/completions` 或 `/completions` 请求体。
- 删除或转换 SillyTavern 内部字段，例如 `chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_*`。
- `logprobs` 在 chat API 下转换成 `{ logprobs: true, top_logprobs: n }`。
- `json_schema` 转成 provider 支持的 response format 或 tool schema。
- Claude 使用专门转换：messages/system/tools/json_schema/reasoning/prompt caching。
- Gemini/Vertex 使用专门转换：contents/parts/systemInstruction/generationConfig/tools/safety settings。
- 流式响应使用 SSE 转发，部分 provider 需要把原生流包装成前端可读格式。
- 错误响应会转成前端预期的 `{ error: ... }` 形状。

#### Text Completions

文件：`SillyTavern/src/endpoints/backends/text-completions.js`

主要接口：

- `POST /api/backends/text-completions/status`
- `POST /api/backends/text-completions/props`
- `POST /api/backends/text-completions/generate`

关键行为：

- 根据 `api_type` 决定 `/v1/models`、`/api/tags`、`/api/openai/v1/models` 等状态检查路径。
- 根据 `api_type` 决定生成路径，例如 `/v1/completions`、`/api/v1/generate`、`/api/generate`。
- Ollama、KoboldCpp、llama.cpp、vLLM、Aphrodite、Tabby、TogetherAI 等字段和流式行为不同，需要逐个适配。

#### Horde

文件：`SillyTavern/src/endpoints/horde.js`

主要接口：

- `POST /api/horde/status`
- `POST /api/horde/text-models`
- `POST /api/horde/text-workers`
- `POST /api/horde/generate-text`
- `POST /api/horde/task-status`
- `POST /api/horde/cancel-task`
- `POST /api/horde/user-info`
- `POST /api/horde/sd-models`
- `POST /api/horde/sd-samplers`
- `POST /api/horde/generate-image`
- `POST /api/horde/caption-image`

它不是核心 chat completion provider，但前端连接、模型列表和 Horde 生图/文本生成会依赖这些接口。

#### Stable Diffusion

文件：`SillyTavern/src/endpoints/stable-diffusion.js`

常用接口：

- `POST /api/sd/ping`
- `POST /api/sd/models`
- `POST /api/sd/samplers`
- `POST /api/sd/schedulers`
- `POST /api/sd/upscalers`
- `POST /api/sd/vaes`
- `POST /api/sd/get-model`
- `POST /api/sd/set-model`
- `POST /api/sd/generate`
- `POST /api/sd/comfy/*`
- `POST /api/sd/sdcpp/*`
- `POST /api/sd/drawthings/*`

这部分也是 provider 适配层，不是单一路径转发。

### 1.3 Tokenizer 实现方式

文件：`SillyTavern/src/endpoints/tokenizers.js`

主要接口：

- `POST /api/tokenizers/llama/encode`
- `POST /api/tokenizers/nerdstash/encode`
- `POST /api/tokenizers/nerdstash_v2/encode`
- `POST /api/tokenizers/mistral/encode`
- `POST /api/tokenizers/yi/encode`
- `POST /api/tokenizers/gemma/encode`
- `POST /api/tokenizers/jamba/encode`
- `POST /api/tokenizers/gpt2/encode`
- `POST /api/tokenizers/claude/encode`
- `POST /api/tokenizers/llama3/encode`
- `POST /api/tokenizers/qwen2/encode`
- `POST /api/tokenizers/command-r/encode`
- `POST /api/tokenizers/command-a/encode`
- `POST /api/tokenizers/nemo/encode`
- `POST /api/tokenizers/deepseek/encode`
- 对应的 `decode`
- `POST /api/tokenizers/openai/encode`
- `POST /api/tokenizers/openai/decode`
- `POST /api/tokenizers/openai/count`
- `POST /api/tokenizers/remote/kobold/count`
- `POST /api/tokenizers/remote/textgenerationwebui/encode`

原版依赖：

- `tiktoken`
- `@agnai/sentencepiece-js`
- `@agnai/web-tokenizers`
- `src/tokenizers/*.model`
- `src/tokenizers/*.json`

关键行为：

- OpenAI/GPT 系列用 tiktoken。
- Llama/Mistral/Yi/Gemma/Jamba/Nerdstash 等用 SentencePiece。
- Claude/Llama3/Qwen2/Command/Nemo/DeepSeek 等用 web tokenizer JSON。
- tokenizer 资源可能从本地或远程 URL 获取，下载后缓存。
- `openai/count` 会根据模型选择不同 tokenizer，并按 chat messages 规则添加 message overhead。
- 远程 tokenizer 接口只覆盖 Kobold/TextGen 等少数后端，不能替代本地精确 tokenizer。

### 1.4 Vector 实现方式

文件：`SillyTavern/src/endpoints/vectors.js`

主要接口：

- `POST /api/vector/query`
- `POST /api/vector/query-multi`
- `POST /api/vector/insert`
- `POST /api/vector/list`
- `POST /api/vector/delete`
- `POST /api/vector/purge-all`
- `POST /api/vector/purge`

原版使用 `vectra.LocalIndex` 做本地向量索引，索引目录结构大致为：

```text
data/<user>/vectors/<source>/<collectionId>/<model>/
```

支持的 embedding source 包括：

- `transformers`
- `openai`
- `mistral`
- `togetherai`
- `nomicai`
- `extras`
- `palm`
- `vertexai`
- `cohere`
- `ollama`
- `llamacpp`
- `vllm`
- `webllm`
- `koboldcpp`
- `electronhub`
- `openrouter`
- `chutes`
- `nanogpt`
- `siliconflow`

关键行为：

- `insert`：按文本批量调用 embedding，写入本地索引，metadata 保存 `{ hash, text, index }`。
- `list`：返回 collection 中已保存的 hash。
- `delete`：按 hash 删除。
- `query`：对 searchText 生成 query vector，查询 topK，按 threshold 过滤，返回 `{ hashes, metadata }`。
- `query-multi`：跨 collection 查询，整体排序后按 collection 分组返回。
- `purge/purge-all`：删除 collection 或全部 source 索引。
- 发生 index JSON 损坏时，原版有重建/删除 corrupted index 的容错逻辑。

## 2. TauriTavern 的解决方案

项目位置：`C:/Users/Cestbon/Desktop/TavernNext/TarvenNext`

它不是保留 Express 路由，而是把前端 API 改成 Tauri command，再在 Rust 里重写后端。

### 2.1 模型调用

关键文件：

- `src-tauri/src/application/services/chat_completion_service/mod.rs`
- `src-tauri/src/application/services/chat_completion_service/config.rs`
- `src-tauri/src/application/services/chat_completion_service/payload/mod.rs`
- `src-tauri/src/infrastructure/apis/http_chat_completion_repository/mod.rs`

结构：

```text
Tauri command
  -> ChatCompletionService
    -> resolve source/config/key/baseUrl
    -> payload::build_payload(source, payload)
    -> ChatCompletionRepository.generate/generate_stream
    -> provider HTTP module
```

特点：

- 把 provider 枚举成 `ChatCompletionSource`。
- `config.rs` 统一处理 base URL、reverse proxy、secret key、custom headers。
- `payload/mod.rs` 按 provider 分发 payload builder。
- `http_chat_completion_repository` 负责真实 HTTP、SSE 读取、错误映射。
- 支持取消请求和 stream channel。

Provider payload builder 拆分很细：

- `payload/openai.rs`
- `payload/openrouter.rs`
- `payload/claude/*`
- `payload/makersuite.rs`
- `payload/vertexai.rs`
- `payload/cohere.rs`
- `payload/deepseek.rs`
- `payload/moonshot.rs`
- `payload/nanogpt.rs`
- `payload/chutes.rs`
- `payload/zai.rs`
- `payload/custom.rs`

这说明 TauriTavern 也认为模型调用的核心是“provider 适配层”，而不是简单 fetch。

### 2.2 OpenAI 兼容 builder

文件：`src-tauri/src/application/services/chat_completion_service/payload/openai.rs`

关键做法：

- 先删除内部字段：`chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_*`、`bypass_status_check` 等。
- 判断是否 text completion 模型，是则走 `/completions`，否则走 `/chat/completions`。
- Chat payload 只挑 provider 接受的字段：`messages`、`model`、`temperature`、`max_tokens`、`max_completion_tokens`、`stream`、`presence_penalty`、`frequency_penalty`、`top_p`、`top_k`、`stop`、`logit_bias`、`seed`、`n`、`user`。
- `logprobs` 转 `logprobs/top_logprobs`。
- `json_schema` 转 `response_format`。
- text completion 会把 messages 转成 prompt。

这部分最适合直接借鉴到 OHOS 的 `ModelProxyService`。

### 2.3 Claude/Gemini builder

Claude 文件：

- `payload/claude/builder.rs`
- `payload/claude/messages.rs`
- `payload/claude/tools.rs`
- `payload/claude/contract.rs`
- `payload/claude/params.rs`

实现了：

- OpenAI-like messages -> Anthropic messages。
- system prompt 拆分。
- assistant prefill。
- tools schema 转 Anthropic tools。
- json_schema 转 forced tool。
- reasoning_effort 转 thinking budget 或 adaptive thinking。
- 模型能力 contract 校验。
- assistant 图片移动、连续消息合并。

Gemini 文件：

- `payload/makersuite.rs`
- `payload/vertexai.rs`
- `payload/gemini_interactions.rs`

实现了：

- messages -> Gemini `contents/parts`。
- `generationConfig`。
- `systemInstruction`。
- safety settings。
- tools/function declarations。
- google search。
- image modality。
- thinking config。

这部分证明 Claude/Gemini 的迁移量大确实来自 payload 转换，而不是 HTTP 调用本身。

### 2.4 Tokenizer

关键文件：

- `src-tauri/src/application/services/tokenization_service.rs`
- `src-tauri/src/domain/repositories/tokenizer_repository.rs`
- `src-tauri/src/infrastructure/apis/miktik_tokenizer_repository.rs`

TauriTavern 使用 Rust crate `miktik`：

```toml
miktik = { version = "0.2.0", default-features = false, features = ["openai", "huggingface", "sentencepiece"] }
```

做法：

- `TokenizerRepository` 定义 `ensure_model_ready`、`encode`、`decode`、`count_messages`。
- `MiktikTokenizerRepository` 用 `TokenizerRegistry` 管理 tokenizer。
- Claude、DeepSeek、Gemma 的 tokenizer 资源通过 `include_bytes!` gzip 打包进应用。
- Llama3、Llama、Mistral、Yi、Jamba、Nerdstash、Command、Qwen2、Nemo 等资源首次使用时从 SillyTavern 仓库下载到 cache。
- 按 canonical model 做 alias 解析，例如 `gpt-4.1-mini -> gpt-4o`、`o4-mini -> o1`、`gemini-2.0-flash -> gemma`。

这条路线对 OHOS 很有价值：不要在 ArkTS 里手写 BPE/SentencePiece，而是把 MikTik 做成 native tokenizer module。

### 2.5 Vector

在 TauriTavern 当前源码里，没有看到完整 `/api/vector/*` 后端实现。

能看到的是：

- 用户目录里保留 `vectors` 目录。
- data archive/export/import 包含 `vectors`。
- 角色 lorebook 兼容字段里有 `vectorized`。

但没有看到等价于原版 `vectra.LocalIndex` 的 insert/query/delete/purge 实现。因此 vector 这块不能直接借鉴 TauriTavern，需要我们自己实现或找 Rust/native vector index 方案。

## 3. MikTik 编译成 OHOS so 的可行性

项目位置：`C:/Users/Cestbon/Desktop/TavernNext/MikTik`

MikTik 当前是 Rust library crate，不是 ArkTS 可直接 import 的 `.so`。需要做桥接层。

### 3.1 已验证情况

本机已经安装 Rust OHOS targets：

- `x86_64-unknown-linux-ohos`
- `aarch64-unknown-linux-ohos`

MikTik native tokenizer 已经落地到当前 OHOS 工程：

```powershell
cargo build --manifest-path native\tavern_tokenizer_ffi\Cargo.toml --target x86_64-unknown-linux-ohos --release
cargo build --manifest-path native\tavern_tokenizer_ffi\Cargo.toml --target aarch64-unknown-linux-ohos --release
```

已验证 `entry` HAP 构建、模拟器安装和 HTTP 接口：

- `POST /api/tokenizers/openai/encode?model=gpt-4o`：`Hello world` 返回真实 token ids `[13225,2375]`。
- `POST /api/tokenizers/openai/decode?model=gpt-4o`：可还原 `Hello world`。
- `POST /api/tokenizers/openai/count?model=gpt-4o`：按原版 OpenAI chat message overhead 计数。
- `POST /api/backends/chat-completions/bias?model=gpt-4o`：普通文本和 `[1,2]` 原始 token 数组均可映射。
- `POST /api/tokenizers/claude/encode`：`Hello world` 返回真实 Claude web-tokenizer ids `[10002,2253]`，chunks 为 `["Hello"," world"]`。
- `POST /api/tokenizers/deepseek/encode`：`Hello world` 返回真实 DeepSeek web-tokenizer ids `[19923,2058]`。
- `POST /api/tokenizers/gemma/encode`：`Hello world` 返回真实 Gemma SentencePiece ids `[2405,545,513,483,706]`。
- `POST /api/tokenizers/openai/count?model=claude-3-7-sonnet`、`model=deepseek-chat`、`model=gemini-2.0-flash`：分别按原版 web tokenizer / SentencePiece 分支计数。
- 2026-05-03 已补齐并验证剩余本地 tokenizer：`gpt2`、`llama`、`llama3`、`mistral`、`yi`、`jamba`、`nerdstash`、`nerdstash_v2`、`qwen2`、`command-r`、`command-a`、`nemo` 的 encode/decode/count 已走 native；`openai/encode?model=llama-3.3-70b`、`qwen2.5-coder`、`command-r-plus`、`text-davinci-003` 等 alias 已能按原版分流。

### 3.2 已解决的编译问题

MikTik `full` feature 会启用：

- `tiktoken-rs`
- `tokenizers`
- `sentencepiece-model`
- `onig_sys`

`onig_sys` 的 OHOS 交叉编译问题已经解决。关键是让 CMake 在构建 Rust staticlib 时向 cargo 传入 OHOS clang/ar/sysroot，并设置 `CC_SHELL_ESCAPED_FLAGS=1`，避免 Windows 下 `DevEco Studio` 路径中的空格破坏 `cc-rs` 参数解析。

当前 `entry/src/main/cpp/CMakeLists.txt` 会根据 `OHOS_ARCH` 设置：

- `CC_x86_64_unknown_linux_ohos` / `CC_aarch64_unknown_linux_ohos`
- `CXX_x86_64_unknown_linux_ohos` / `CXX_aarch64_unknown_linux_ohos`
- `AR_x86_64_unknown_linux_ohos` / `AR_aarch64_unknown_linux_ohos`
- `CFLAGS_*` / `CXXFLAGS_*`，包含 `--target=<ohos target>` 和 `--sysroot=<CMAKE_SYSROOT>`
- `CC_SHELL_ESCAPED_FLAGS=1`

本机已验证 `x86_64-unknown-linux-ohos` 和 `aarch64-unknown-linux-ohos` 两个 target 的 release build。

### 3.3 已采用桥接结构

```text
ArkTS TokenizerService
  -> OHOS NAPI native module
    -> Rust staticlib FFI bridge crate
      -> MikTik TokenizerRegistry
```

当前文件位置：

- `third_party/miktik`：MikTik submodule。
- `native/tavern_tokenizer_ffi`：Rust FFI staticlib，启用 MikTik `openai`、`huggingface`、`sentencepiece` features。
- `native/tavern_tokenizer_ffi/resources/tokenizers/`：内置 SillyTavern tokenizer gzip 资源，包括 `claude.json.gz`、`deepseek.json.gz`、`gemma.model.gz`、`llama.model.gz`、`llama3.json.gz`、`mistral.model.gz`、`yi.model.gz`、`jamba.model.gz`、`nerdstash.model.gz`、`nerdstash_v2.model.gz`、`qwen2.json.gz`、`command-r.json.gz`、`command-a.json.gz`、`nemo.json.gz`，首次使用时懒加载解压到 MikTik registry。
- `entry/src/main/cpp/tokenizer_native.cpp`：C++ NAPI wrapper，导出 `resolveModel/canUseModel/encode/decode/count/encodePieces/countMessages`。
- `entry/src/main/ets/backend/TokenizerService.ets`：ArkTS 路由层，保持 SillyTavern HTTP 响应形状。

Rust bridge 当前导出：

- `tavern_tokenizer_resolve_model(model)`
- `tavern_tokenizer_can_use_model(model)`
- `tavern_tokenizer_encode(model, text)`
- `tavern_tokenizer_decode(model, ids)`
- `tavern_tokenizer_count(model, text)`
- `tavern_tokenizer_encode_pieces(model, text)`：用于 SentencePiece encode 响应里的原版 pieces/chunks 展示。
- `tavern_tokenizer_count_messages(model, messagesJson)`
- 对应的 ids/bytes/string 释放函数。

已替换 `/api/tokenizers/openai/*` 和所有 SillyTavern 本地 tokenizer 路由的真实 tokenizer。OpenAI/tiktoken 覆盖 `o1`、`gpt-4o`、`gpt-4`、`gpt-4-32k`、`gpt-3.5-turbo`、`gpt-3.5-turbo-0301`、GPT-2、旧 text-completion/code/embedding 模型；HuggingFace/web tokenizer 覆盖 Claude、Llama3、Qwen2、Command-R、Command-A、Nemo、DeepSeek；SentencePiece 覆盖 Llama、Mistral、Yi、Gemma、Jamba、Nerdstash、Nerdstash v2。`/api/tokenizers/openai/count` 会按原版 SillyTavern 的模型分支行为计数：OpenAI 添加 chat message overhead，web tokenizer 先转换成 Claude-style prompt，SentencePiece 把 message values flatten 后再计数。

## 4. 对当前 OHOS 移植的启发方案

### 4.1 模型调用

当前 ArkTS 里 `ModelProxyService` 的方向是对的，但需要从“直接代理 body”改为“provider payload builder”。

建议拆分：

```text
ModelProxyService
  -> ModelProxyConfigResolver
  -> OpenAiCompatiblePayloadBuilder
  -> ClaudePayloadBuilder
  -> GeminiPayloadBuilder
  -> TextCompletionPayloadBuilder
  -> RemoteHttpClient
```

优先级：

1. OpenAI-compatible builder：收益最大，迁移量最低。
2. Text completions：按 `api_type` 补路径和请求体。
3. Horde/SD local provider：补常用路由，先不追云端生图全量。
4. Claude/Gemini builder：按 TauriTavern 的 Rust 实现分段翻译到 ArkTS。

### 4.2 Tokenizer

OpenAI/tiktoken、GPT-2、Claude、DeepSeek、Gemma、Llama/Llama 3、Mistral、Yi、Jamba、Nerdstash、Qwen2、Command 和 Nemo 已经不再是 ArkTS 字节估算，而是走 MikTik native tokenizer。当前本地 tokenizer 路由已经达到最小原版一致目标。

已完成路线：

1. MikTik OHOS native bridge 已完成，启用 `openai`、`huggingface`、`sentencepiece`。
2. ArkTS `/api/tokenizers/openai/encode/decode/count` 和 `/api/tokenizers/<model>/encode/decode` 已切到 native；SentencePiece encode 的 chunks 通过 native `encodePieces` 返回，web tokenizer chunks 按原版增量 decode 处理。
3. 虚拟机 `.so` 加载、HAP 构建安装和关键 HTTP 接口已验证。
4. chat-completions `bias` 的 OpenAI、DeepSeek、Gemma 等 token 映射已切到 native，Claude 保持原版空对象行为。

后续路线：

1. 对比原版 SillyTavern 的特殊 token、异常 token id、chunks 展示和 fallback 行为，继续补齐边界一致性。
2. 评估 tokenizer 资源全部内置对 HAP 体积的影响；如果包体压力明显，再改成 TauriTavern 式“核心内置 + 首次下载缓存”。
3. 继续模型 provider builder、vector index 等更影响聊天主流程的功能。

### 4.3 Vector

当前 ArkTS 已有可用 vector 最小实现，并在 2026-05-03 对齐了原版 SillyTavern 的常用 embedding provider 请求形状。

已完成：

1. HTTP 接口保持原版形状：`insert/list/delete/query/query-multi/purge/purge-all`。
2. 本地索引写入 `data/default-user/vectors/<source>/<collectionId>/<model>/index.json`，query 使用 cosine similarity，返回 `{ hashes, metadata }` 或按 collectionId 分组的 multi-query 结果。
3. `insert` 改为 10 条一批生成 embedding，避免逐条请求远端。
4. remote embedding provider 请求体/响应解析已覆盖：
   - OpenAI-compatible、Mistral、TogetherAI、OpenRouter、ElectronHub、NanoGPT、SiliconFlow、Chutes：批量 `/embeddings`。
   - Cohere：v2 `/embed`，使用 `texts`、`embedding_types: ["float"]`、`input_type` 和 `truncate: "END"`。
   - Ollama：`/api/embed`，使用 `input` 数组。
   - Extras：`/api/embeddings/compute`，使用 `{ text }`，兼容单条和数组。
   - NomicAI：`/v1/embedding/text`，使用 `texts/model`。
   - llama.cpp/vLLM：去掉可能重复的 `/v1` 后拼 `/v1/embeddings`。
   - MakerSuite/Google 与 Vertex AI：补基础 batch embedding/predict 请求和响应解析。
5. provider 未配置、请求失败或响应无法解析时，仍回退到本地 hash vector，保证前端流程不中断。

仍不完善：

1. 本地 index 仍是 JSON + 全量 cosine scan，不是原版 `vectra.LocalIndex` 的性能/持久化等价实现。
2. Transformers 本地 embedding 仍是 hash fallback，还没有引入真正本地 embedding 模型。
3. Vertex embedding 当前只覆盖 express API key 基础路径，未复用 chat provider 已实现的 full service account OAuth。
4. 还需要用真实 provider 做回归，尤其是 Cohere、Ollama、Chutes、Google/Vertex 的实际响应边界。

后续考虑 native vector index：

1. Rust 自实现 cosine scan + JSON/二进制持久化。
2. 或使用可编译到 OHOS 的 Rust 向量索引库。

Vector 不建议依赖 TauriTavern，因为它当前没有完整实现。

## 5. 当前下一步建议

当前短线进度：

1. 模型代理：OpenAI chat-completions 最小代理已经完成；下一步若继续模型侧，应先补真实 OpenAI 错误细节、请求取消、更多 OpenAI 参数和 OpenAI-compatible provider 的差异。
2. Tokenizer：SillyTavern 本地 tokenizer 路由已通过 MikTik native bridge 补齐；下一步只保留特殊 token/chunks/包体积等边界优化。

这两条都能明显提升“与原版行为一致”的程度，而且风险可控。
