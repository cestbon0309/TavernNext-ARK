# TauriTavern Provider 处理逻辑梳理

本文记录 `C:/Users/Cestbon/Desktop/TavernNext/TarvenNext` 中 TauriTavern Rust 后端处理模型 provider 的方式，重点覆盖 chat-completions provider 适配层、每个相关文件职责、核心接口实现，以及对当前 OHOS ArkTS 后端的启发。

当前结论：

- TauriTavern 没有把 provider 当成简单 URL 转发，而是拆成 `source/config/payload/http/normalizer/stream` 几层。
- OpenAI-compatible provider 复用 OpenAI payload 和 SSE 形状，但仍有 provider 专属参数、默认 base URL、鉴权 header、模型列表路径和 reasoning/web search 差异。
- Claude、Gemini/Vertex、Cohere、OpenAI Responses、Gemini Interactions 都需要专门 payload builder 和响应归一化，不能只替换 endpoint。
- 当前 OHOS 的 `ModelProxyService.ets` 已完成 `openai/custom` 最小可用，但还没有形成 TauriTavern 这种可扩展 provider adapter 层；文件里虽然有 `claude/makersuite/openrouter` 等残留分支，入口目前仍只放行 `openai/custom`。

## 1. 总体调用链

TauriTavern 的调用链：

```text
Frontend Tauri command
  -> presentation/commands/chat_completion_commands.rs
  -> application/services/chat_completion_service/mod.rs
  -> config.rs resolve base URL / API key / headers
  -> payload/mod.rs dispatch provider payload builder
  -> prompt_caching_plan.rs / prompt_caching.rs optional cache_control
  -> domain/repositories/chat_completion_repository.rs trait
  -> infrastructure/apis/http_chat_completion_repository/mod.rs
  -> provider HTTP module
  -> normalizers.rs optional response normalization
  -> stream channel / Tauri IPC event
```

核心思想是：前端仍然提交 SillyTavern/OpenAI-like 的统一 payload，后端按 `chat_completion_source` 转成不同 provider 真实协议。HTTP 层再负责真实请求、SSE 读取、错误映射、响应转成前端能消费的 OpenAI-like 形状。

## 2. 对外命令接口

文件：`src-tauri/src/presentation/commands/chat_completion_commands.rs`

提供 Tauri command，职责相当于我们 OHOS HTTP route handler 的外层：

```rust
get_chat_completions_status(dto, app_state) -> Result<Value, CommandError>
generate_chat_completion(dto, request_id, app_state) -> Result<Value, CommandError>
start_chat_completion_stream(stream_id, dto, on_event, app_state) -> Result<(), CommandError>
cancel_chat_completion_stream(stream_id, app_state) -> Result<(), CommandError>
cancel_chat_completion_generation(request_id, app_state) -> Result<(), CommandError>
```

具体行为：

- `get_chat_completions_status` 调 `ChatCompletionService.get_status()`，用于模型列表和连通性检查。
- `generate_chat_completion` 是非流式生成，会注册 `request_id`，支持取消。
- `start_chat_completion_stream` 创建 `Channel<ChatCompletionStreamEvent>`，后台跑 `service.generate_stream()`，把每个 chunk 发送给前端。
- `ChatCompletionStreamEvent` 有三类：`Chunk { data }`、`Done`、`Error { message }`。
- `validate_stream_id` 限制 id 非空、长度不超过 128，只允许 ASCII 字母数字、`-`、`_`。

对 OHOS 的对应关系：

- `generate_chat_completion` 对应 `POST /api/backends/chat-completions/generate` 的非流式路径。
- `start_chat_completion_stream` 在 OHOS HTTP 里不需要 Tauri Channel，可以直接返回 `text/event-stream`，但仍应保留 request id / cancel registry 的概念，后续用于“停止生成”。

## 3. DTO 与领域接口

### 3.1 DTO

文件：`src-tauri/src/application/dto/chat_completion_dto.rs`

```rust
pub struct ChatCompletionStatusRequestDto {
    pub chat_completion_source: String,
    pub custom_api_format: String,
    pub reverse_proxy: String,
    pub proxy_password: String,
    pub custom_url: String,
    pub custom_include_headers: String,
    pub bypass_status_check: bool,
}

pub struct ChatCompletionGenerateRequestDto {
    #[serde(flatten)]
    pub payload: Map<String, Value>,
}
```

`StatusRequestDto` 是明确字段；`GenerateRequestDto` 用 flatten 接收任意 JSON object，这点很关键，因为 SillyTavern 会给不同 provider 传大量 provider-specific 字段。

### 3.2 Provider 枚举与仓储接口

文件：`src-tauri/src/domain/repositories/chat_completion_repository.rs`

核心枚举：

```rust
pub enum ChatCompletionSource {
    OpenAi,
    OpenRouter,
    Custom,
    Claude,
    Makersuite,
    VertexAi,
    DeepSeek,
    Cohere,
    Groq,
    Moonshot,
    NanoGpt,
    Chutes,
    SiliconFlow,
    Zai,
}
```

`ChatCompletionSource::parse(raw)` 支持别名，例如：

- `"" | "openai"` -> `OpenAi`
- `"openrouter" | "open-router"` -> `OpenRouter`
- `"makersuite" | "gemini" | "google"` -> `Makersuite`
- `"vertexai" | "vertex-ai" | "vertex ai"` -> `VertexAi`
- `"zai" | "z.ai" | "glm"` -> `Zai`

API 配置：

```rust
pub struct ChatCompletionApiConfig {
    pub base_url: String,
    pub api_key: String,
    pub authorization_header: Option<String>,
    pub extra_headers: HashMap<String, String>,
    pub anthropic_beta_header_mode: AnthropicBetaHeaderMode,
}
```

仓储接口：

```rust
#[async_trait]
pub trait ChatCompletionRepository: Send + Sync {
    async fn list_models(source, config) -> Result<Value, DomainError>;
    async fn generate(source, config, endpoint_path, payload) -> Result<Value, DomainError>;
    async fn generate_stream(source, config, endpoint_path, payload, sender, cancel) -> Result<(), DomainError>;
}
```

这个 trait 是 provider HTTP 层的统一边界。应用层不关心 reqwest 细节，只关心“source + config + endpoint_path + upstream_payload”。

## 4. Application Service

文件：`src-tauri/src/application/services/chat_completion_service/mod.rs`

`ChatCompletionService` 是 provider 流程总调度器，主要字段：

- `chat_completion_repository`: 实际 HTTP provider repository。
- `secret_repository`: 读取 API key。
- `settings_repository`: 读取 TauriTavern 设置。
- `prompt_cache_repository`: Claude/OpenRouter prompt cache digest。
- `ios_policy`: iOS 能力限制，OHOS 可以暂不照搬。
- `active_streams` / `active_generations`: 取消 registry。

核心方法：

```rust
get_status(dto) -> Result<Value, ApplicationError>
generate(dto) -> Result<Value, ApplicationError>
generate_with_cancel(dto, cancel) -> Result<Value, ApplicationError>
generate_stream(dto, sender, cancel) -> Result<(), ApplicationError>
register_stream(stream_id) -> watch::Receiver<bool>
cancel_stream(stream_id) -> bool
complete_stream(stream_id)
register_generation(request_id) -> watch::Receiver<bool>
cancel_generation(request_id) -> bool
complete_generation(request_id)
```

`generate` 和 `generate_stream` 的共同流程：

```text
resolve_source(payload.chat_completion_source)
ensure source / endpoint overrides / feature policy allowed
load settings
PromptCachingRequestHints::from_payload(payload)
resolve_generate_api_config(source, dto, secrets)
payload::build_payload(source, payload) -> (endpoint_path, upstream_payload)
apply_tauritavern_prompt_caching(...)
repository.generate or repository.generate_stream(...)
```

对 OHOS 的启发：

- 当前 `ModelProxyService.ets` 应该拆出类似 `ModelProviderService` 的总调度。
- `chatCompletionGenerate()` 不应该直接组 URL 和 body，而应按 `source` 调 `resolveConfig()` 和 `buildPayload()`。
- 取消机制可以先作为后续项，但接口设计时应保留 `requestId/streamId`。

## 5. Config 解析

文件：`src-tauri/src/application/services/chat_completion_service/config.rs`

职责：统一处理 base URL、reverse proxy、API key、custom headers、Anthropic beta header、Vertex AI 鉴权。

默认 base URL：

```text
OpenAI       https://api.openai.com/v1
OpenRouter   https://openrouter.ai/api/v1
Claude       https://api.anthropic.com/v1
Gemini       https://generativelanguage.googleapis.com
Vertex AI    https://aiplatform.googleapis.com
DeepSeek     generate=https://api.deepseek.com/beta, status=https://api.deepseek.com
Cohere       generate=https://api.cohere.ai/v2, status=https://api.cohere.ai/v1
Groq         https://api.groq.com/openai/v1
Moonshot     https://api.moonshot.ai/v1
NanoGPT      https://nano-gpt.com/api/v1
Chutes       https://llm.chutes.ai/v1
SiliconFlow  https://api.siliconflow.com/v1
Z.AI         common=https://api.z.ai/api/paas/v4, coding=https://api.z.ai/api/coding/paas/v4
```

关键接口：

```rust
resolve_status_api_config(source, dto, secret_repository) -> ChatCompletionApiConfig
resolve_generate_api_config(source, dto, secret_repository) -> ChatCompletionApiConfig
```

具体行为：

- `Custom` source 优先 `custom_url`，否则 `reverse_proxy`；如果 `custom_include_headers` 里有 `Authorization`，则不再使用保存的 custom key。
- 非 custom source 如果支持 reverse proxy 且用户配置了 `reverse_proxy`，则 base URL 用 reverse proxy，key 用 `proxy_password`。
- `source_extra_headers(OpenRouter)` 添加 `HTTP-Referer` 和 `X-Title`。
- `source_extra_headers(Zai)` 添加 `Accept-Language: en-US,en`。
- `source_anthropic_beta_header_mode(Claude)` 默认为 `ClaudeDefaults`。
- Vertex AI 支持 `express` 和 `full` 两种鉴权：
  - `express` 用 API key 和 region/project 拼 base URL。
  - `full` 用 service account JSON 获取 OAuth access token，设置 `Authorization: Bearer ...`。

当前 OHOS 应替代接口：

```ts
interface ChatCompletionApiConfig {
  baseUrl: string;
  apiKey: string;
  authorizationHeader?: string;
  extraHeaders: Record<string, string>;
  anthropicBetaHeaderMode: 'none' | 'prompt_caching_only' | 'claude_defaults';
}

resolveStatusApiConfig(source, body): ChatCompletionApiConfig
resolveGenerateApiConfig(source, payload): ChatCompletionApiConfig
```

## 6. Payload 分发入口

文件：`src-tauri/src/application/services/chat_completion_service/payload/mod.rs`

接口：

```rust
pub(super) fn build_payload(
    source: ChatCompletionSource,
    payload: Map<String, Value>,
) -> Result<(String, Value), ApplicationError>
```

分发：

```text
OpenAi / Groq / SiliconFlow -> openai::build
DeepSeek                    -> deepseek::build
Cohere                      -> cohere::build
Moonshot                    -> moonshot::build
NanoGpt                     -> nanogpt::build
Chutes                      -> chutes::build
OpenRouter                  -> openrouter::build
Zai                         -> zai::build
Custom                      -> custom::build
Claude                      -> claude::build
Makersuite                  -> makersuite::build
VertexAi                    -> vertexai::build
```

除 DeepSeek 外，进入 builder 前会执行 `prompt_post_processing::apply_custom_prompt_post_processing()`。DeepSeek 自己在 builder 里用 `SemiTools` 方式处理 prompt。

返回值里的 `endpoint_path` 很重要：同一个 source 可能走不同 endpoint，例如 OpenAI legacy model 走 `/completions`，普通 chat 走 `/chat/completions`，Claude 走 `/messages`，Gemini 走 `/generateContent` 或 `/streamGenerateContent`。

## 7. OpenAI 与 OpenAI-compatible

### 7.1 `payload/openai.rs`

接口：

```rust
build(payload) -> (String, Value)
strip_internal_fields(payload)
```

主要逻辑：

- 删除内部字段：`chat_completion_source`、`reverse_proxy`、`proxy_password`、`custom_api_format`、`custom_prompt_post_processing`、`custom_include_body`、`custom_exclude_body`、`custom_include_headers`、`custom_claude_prompt_caching`、`custom_url`、`bypass_status_check`。
- 如果 `messages` 是字符串，或 model 属于 legacy text completion 列表，走 `/completions`。
- 否则走 `/chat/completions`。

Chat body 允许字段：

```text
messages, model, temperature, max_tokens, max_completion_tokens, stream,
presence_penalty, frequency_penalty, top_p, top_k, stop, logit_bias,
seed, n, user, tools, tool_choice, response_format
```

特殊映射：

- `logprobs: number` -> `logprobs: true` + `top_logprobs: number`。
- `json_schema.value` -> `response_format: { type: "json_schema", json_schema: { name, strict, schema } }`。
- OpenAI/custom 且模型是 reasoning model 时，`reasoning_effort=min` -> `minimal`，`auto` 不转发。
- `gpt-5*` 模型转发 `verbosity`。
- Text completion 会把 messages 转成 prompt，格式大致为 `role: content\nassistant:`。

OHOS 当前已经实现了大半 OpenAI 最小可用逻辑，但还缺：

- `/completions` legacy 模型分流。
- `top_k` 当前 OpenAI body 是否完整保留需对齐。
- 更完整的 OpenAI reasoning model 精确列表。
- `custom_prompt_post_processing`。

### 7.2 `payload/openrouter.rs`

OpenRouter 先复用 OpenAI builder，再追加 OpenRouter 专属字段：

- `min_p`、`top_a`、`repetition_penalty`
- `include_reasoning`
- `middleout` -> `transforms: ["middle-out"]` 或 `[]`
- `enable_web_search` -> `plugins: [{ id: "web" }]`
- `provider` / `allow_fallbacks` / `quantizations` -> `provider` object
- `use_fallback` -> `route: "fallback"`
- `reasoning_effort` -> `reasoning: { effort }`，并移除 OpenAI `reasoning_effort`

HTTP 层仍走 OpenAI 形状 `/chat/completions`。

### 7.3 `payload/deepseek.rs`

DeepSeek 是 OpenAI-compatible，但有专门思考模式：

- `deepseek-chat` -> `thinking.type = disabled`
- `deepseek-reasoner` -> `thinking.type = enabled`
- `deepseek-v4-*` 默认可按 `include_reasoning` 控制
- reasoning 开启时移除 `temperature/top_p/presence_penalty/frequency_penalty`
- `reasoning_effort` 映射：`min/low/medium/high` -> `high`，`max/xhigh` -> `max`
- 工具上下文里 assistant message 必须有字符串 `reasoning_content`，缺失时补空字符串
- 没有 tools/tool messages 时，最后一条 assistant prefill 加 `prefix: true`
- 会移除 tools schema 中空的 `required: []`

### 7.4 `payload/moonshot.rs` 与 `payload/zai.rs`

两者都复用 OpenAI builder，然后在 chat body 里加入：

```json
{ "thinking": { "type": "enabled" | "disabled" } }
```

开关来自 `include_reasoning`。

### 7.5 `payload/nanogpt.rs`

复用 OpenAI builder，但只允许 `/chat/completions`。

专属逻辑：

- `min_p/top_a/repetition_penalty`
- `enable_web_search=true` 时给 model 追加 `:online` 后缀，避免重复追加
- `reasoning_effort` 映射：
  - `min` -> `none`
  - `low` -> `minimal`
  - `medium` -> `low`
  - `high` -> `medium`
  - `max` -> `high`

### 7.6 `payload/chutes.rs`

复用 OpenAI builder，并补回 OpenAI builder 不一定转发的：

- `min_p`
- `repetition_penalty`
- `reasoning_effort`

## 8. Custom API Format

文件：

- `custom_api_format.rs`
- `custom_parameters.rs`
- `payload/custom.rs`

`CustomApiFormat`：

```rust
OpenAiCompat       -> /chat/completions or /completions
OpenAiResponses    -> /responses
ClaudeMessages     -> /messages
GeminiInteractions -> /interactions
```

`custom_api_format` 也影响 status 时使用哪个模型列表 transport：

- `openai_compat` / `openai_responses` -> `Custom`
- `claude_messages` -> `Claude`
- `gemini_interactions` -> `Makersuite`

`custom_parameters.rs` 支持把 `custom_include_headers`、`custom_include_body`、`custom_exclude_body` 按 YAML/JSON 解析：

- object：直接合并。
- list of objects：顺序合并。
- exclude 支持 array、object keys、string。

`payload/custom.rs`：

- `openai_compat`：复用 OpenAI builder，然后应用 include/exclude body。
- `openai_responses`：交给 `payload/openai_responses.rs`。
- `claude_messages`：交给 `payload/claude_messages.rs`。
- `gemini_interactions`：交给 `payload/gemini_interactions.rs`。

OHOS 注意点：

- 现在 `parseCustomYamlObject()` 只是简化 YAML parser，不能完整覆盖 TauriTavern 的 `serde_yaml` 行为。
- Custom 的 `Authorization` header 优先级需要和 TauriTavern 对齐：如果 custom headers 显式给了 Authorization，就不要再自动 Bearer saved secret。

## 9. Claude

文件：

- `payload/claude.rs`
- `payload/claude_messages.rs`
- `payload/claude/builder.rs`
- `payload/claude/contract.rs`
- `payload/claude/messages.rs`
- `payload/claude/tools.rs`
- `payload/claude/params.rs`
- `payload/claude/validation.rs`

### 9.1 入口

`payload/claude.rs`：

```rust
build(payload) -> ("/messages", request)
build_passthrough(payload) -> ("/messages", request)
validate_request(payload)
```

`build()` 会执行 Claude model contract 校验；`build_passthrough()` 给 custom Claude Messages 用，允许用户通过 include/exclude body 自己控制更多字段。

### 9.2 Builder

`payload/claude/builder.rs` 把 OpenAI-like payload 转成 Anthropic Messages API：

- 必须有 `model`。
- `use_sysprompt=true` 时，把开头连续 system messages 转成 Claude 顶层 `system: [{ type: "text", text }]`。
- messages 转成 Claude `messages: [{ role, content: [{ type, ... }] }]`。
- 空文本用零宽字符占位。
- `assistant_prefill` 追加到 messages 尾部，但部分 Claude 新模型不支持。
- assistant message 里的 image block 会移动到后续 user message，因为 Claude 不接受 assistant image。
- 连续同 role messages 合并。
- `max_tokens` 默认至少 1，thinking 相关默认最低 1024。
- `stop` -> `stop_sequences`。
- sampling params 只转发非默认值。
- OpenAI tools -> Claude tools。
- `json_schema.value` 会变成一个强制 tool，用于 JSON schema 输出。
- `reasoning_effort` 根据模型能力转 `thinking` 或 `output_config`。

Claude reasoning 映射：

- legacy thinking：`thinking: { type: "enabled", budget_tokens }`，并移除 sampling params。
- adaptive thinking：`thinking: { type: "adaptive", display: "summarized" | "omitted" }`。
- 支持 output effort 的模型还加 `output_config: { effort }`。

### 9.3 Model Contract

`payload/claude/contract.rs` 用模型名决定能力：

```rust
ClaudeSamplingMode = Full | TemperatureOrTopP | None
ClaudeThinkingMode = Unsupported | ManualOnly | ManualOrAdaptive | AdaptiveOnly
ClaudeModelContract {
  sampling,
  thinking,
  supports_output_effort,
  supports_assistant_prefill,
}
```

这块非常重要，因为 Claude 新旧模型的 sampling/thinking/prefill 支持差异很大。

### 9.4 Messages 与 Tools

`payload/claude/messages.rs`：

- string prompt -> 单条 user message。
- role `assistant` + `tool_calls` -> Claude `tool_use` blocks。
- role `tool` -> Claude `tool_result` block。
- `image_url` 只接受 data URL，并转成 `source: { type: "base64", media_type, data }`。
- `name` 会作为文本前缀。

`payload/claude/tools.rs`：

- OpenAI function tool -> Claude `{ name, description, input_schema }`。
- OpenAI `tool_choice`：
  - `auto` -> `{ type: "auto" }`
  - `required` -> `{ type: "any" }`
  - function name -> `{ type: "tool", name }`

### 9.5 Validation

`payload/claude/validation.rs` 校验：

- `thinking.type` 必须合法。
- legacy thinking 必须有 `budget_tokens`。
- adaptive thinking 不允许 `budget_tokens`。
- 不支持 thinking 的模型不能带 thinking。
- sampling-free 模型不允许非默认 `temperature/top_p/top_k`。
- limited sampling 模型不允许同时设置非默认 `temperature` 和 `top_p`。

## 10. Gemini / MakerSuite / Vertex AI

文件：

- `payload/makersuite.rs`
- `payload/vertexai.rs`
- `payload/gemini_interactions.rs`
- `infrastructure/apis/http_chat_completion_repository/makersuite.rs`
- `infrastructure/apis/http_chat_completion_repository/vertexai.rs`
- `infrastructure/apis/http_chat_completion_repository/gemini_interactions.rs`

### 10.1 MakerSuite Payload

`payload/makersuite.rs` 是最大的一块 provider builder。

入口：

```rust
build(payload) -> endpoint "/generateContent" or "/streamGenerateContent"
build_vertexai(payload) -> same payload, Vertex mode enabled
```

主要转换：

- `messages` -> Gemini `contents: [{ role: "user" | "model", parts: [...] }]`。
- `use_sysprompt=true` 时，开头 system messages -> `systemInstruction`。
- `max_tokens` -> `generationConfig.maxOutputTokens`。
- `top_p` -> `topP`，`top_k` -> `topK`，`stop` -> `stopSequences`。
- `json_schema.value` -> `generationConfig.responseMimeType = application/json` + `responseSchema`。
- `tools` -> `tools: [{ function_declarations: [...] }]`。
- `tool_choice` -> `toolConfig.functionCallingConfig`。
- `enable_web_search` -> `tools: [{ google_search: {} }]`，但 Gemma/LearnLM/部分 no-search 模型排除。
- 图片生成模型 + `request_images` -> `responseModalities: ["text", "image"]`，并可设置 `imageConfig.aspectRatio/imageSize`。
- image/video data URL -> `inlineData`。
- Gemini 2.5/3 的 signature -> `thoughtSignature`。
- tool result 根据前面 tool call id 找回 function name，构造 `functionResponse`。
- thinking config：
  - Gemini 2.5 flash/pro 使用 `thinkingBudget`。
  - Gemini 3 flash/pro 使用 `thinkingLevel`。
  - `include_reasoning` 控制 `includeThoughts`。

### 10.2 Vertex AI

`payload/vertexai.rs` 只是复用 `makersuite::build_vertexai(payload)`。

HTTP 层差异在 `vertexai.rs`：

- list models 直接返回 `{ bypass: true, data: [] }`。
- URL 形状：`<base>/publishers/google/models/<model>:generateContent`。
- stream 加 query `alt=sse`。
- 鉴权可能是 API key query，也可能是 `Authorization: Bearer <access token>`。
- 响应复用 Gemini normalizer。

### 10.3 Gemini Interactions

`payload/gemini_interactions.rs` 用于 custom format `gemini_interactions`，目标 endpoint `/interactions`。

转换逻辑：

- `messages` -> `input`。
- system messages -> `system_instruction` 字符串。
- `generation_config` 使用 snake_case 字段：`temperature/top_p/top_k/max_output_tokens`。
- OpenAI tools -> Interactions function tools。
- assistant tool_calls -> `function_call` output。
- tool messages -> `function_result`。
- 支持 image/audio/video data URL 或 URI。
- `json_schema.value` -> `response_format`。
- 保留 `native.gemini_interactions.outputs`，用于多轮工具调用恢复原生输出。

`http_chat_completion_repository/gemini_interactions.rs` 的 stream 不是简单透传：它把 Google Interactions 原生事件：

- `interaction.start`
- `content.start`
- `content.delta`
- `interaction.complete`
- `error`

转换成 OpenAI-compatible `chat.completion.chunk`，包括 `delta.content`、`delta.reasoning_content`、`delta.tool_calls`、最终 `[DONE]`。

## 11. Cohere

文件：

- `payload/cohere.rs`
- `infrastructure/apis/http_chat_completion_repository/cohere.rs`

Payload：

- endpoint `/chat`。
- `model` 必填。
- `messages` 如果为空，补 `"Let's get started."`。
- `top_k` -> `k`。
- `top_p` -> `p`。
- `stop` -> `stop_sequences`。
- 固定 `documents: []`。
- OpenAI tools 会删除 `$schema`。
- 2024 年 8 月后缀模型加 `safety_mode: "OFF"`。
- `json_schema.value` -> `response_format: { type: "json_schema", schema }`。
- tool_calls 会用 primer 文本或前一条 assistant content 适配 Cohere。
- 非 system 的 `name` 会前缀进 content，再删除 `name`。

HTTP：

- status 走 `/models`，并把 `models` 或 `data` 归一成 `{ data: [{ id }] }`。
- generate/stream 走 `/chat`，Bearer auth，SSE 直接转发。

## 12. OpenAI Responses

文件：

- `payload/openai_responses.rs`
- `infrastructure/apis/http_chat_completion_repository/openai_responses.rs`

这是 custom format `openai_responses`。

Payload builder：

- endpoint `/responses`。
- `messages` -> `input`。
- system role -> `developer`。
- 尾部 tool/function messages -> `function_call_output`，要求 `tool_call_id`。
- `max_tokens/max_completion_tokens` -> `max_output_tokens`。
- `reasoning_effort` -> `reasoning: { effort }`，`min` -> `minimal`。
- `tools` 从 OpenAI chat function schema 提升为 Responses API function tool。
- `tool_choice` 改成 Responses API 形状。
- `store: false`。

HTTP 层：

- 非流式响应用 `normalizers::normalize_openai_responses_response()` 转成 OpenAI chat completion。
- 流式事件不是透传，而是把 Responses API event 转成 `chat.completion.chunk`。
- 工具调用 follow-up 需要维护 `previous_response_id`：
  - 生成 tool call 后记录 `call_id -> response_id`。
  - 后续输入如果包含 `function_call_output`，自动加 `previous_response_id`，并只发送尾部 tool output。

## 13. HTTP Repository

### 13.1 统一 HTTP 实现

文件：`src-tauri/src/infrastructure/apis/http_chat_completion_repository/mod.rs`

核心结构：

```rust
pub struct HttpChatCompletionRepository {
    http_clients: Arc<HttpClientPool>,
    openai_responses_previous_response_id_by_call_id: Mutex<HashMap<String, String>>,
}
```

辅助函数：

- `build_url(base_url, path)`：拼接 base + endpoint path。
- `apply_bearer_auth()`：设置 `Authorization: Bearer ...`。
- `apply_openai_auth()`：优先 explicit `authorization_header`，否则 Bearer API key。
- `apply_extra_headers()`：合并额外 headers，跳过空 key/value。
- `map_error_response()`：HTTP 错误转 `AuthenticationError`、`InvalidData` 或 `InternalError`。
- `stream_sse_response()`：读取 SSE 响应，按 `data:` 事件转发。
- `SseEventAccumulator`：支持多行 `data:`、CRLF、注释行、尾部 flush。

Repository dispatch：

```rust
list_models(source, config)
generate(source, config, endpoint_path, payload)
generate_stream(source, config, endpoint_path, payload, sender, cancel)
```

Provider 分派规则：

- OpenAI/OpenRouter/DeepSeek/Groq/Moonshot/NanoGPT/Chutes/SiliconFlow/Zai 走 `openai.rs`。
- Custom 根据 `endpoint_path` 再分：
  - `/responses` -> `openai_responses.rs`
  - `/interactions` -> `gemini_interactions.rs`
  - `/messages` -> `claude.rs`
  - 其它 -> `openai.rs`
- Claude -> `claude.rs`
- Makersuite -> `makersuite.rs`
- VertexAI -> `vertexai.rs`
- Cohere -> `cohere.rs`

### 13.2 OpenAI HTTP

文件：`http_chat_completion_repository/openai.rs`

接口：

```rust
list_models(repository, config, provider_name)
list_models_with_path(repository, config, provider_name, path)
generate(repository, config, endpoint_path, payload, provider_name)
generate_stream(repository, config, endpoint_path, payload, provider_name, sender, cancel)
```

行为：

- models: GET `<base>/models`。
- generate: POST `<base>/<endpoint_path>`，`Accept: application/json`。
- stream: POST，`Accept: text/event-stream`。
- 如果 payload 包含 `cache_control`，流式时会在 SSE hook 里尝试记录 prompt cache usage。

### 13.3 Claude HTTP

文件：`http_chat_completion_repository/claude.rs`

行为：

- models: GET `<base>/models`，header `anthropic-version: 2023-06-01`。
- generate/stream 默认 endpoint `/messages`。
- 鉴权优先 `Authorization`，否则 `x-api-key`。
- 自动构建 `anthropic-beta`：
  - Claude 默认加 output/context beta。
  - 如果 payload 有 `cache_control`，追加 prompt-caching 和 extended-cache-ttl beta。
  - 用户自定义 `anthropic-beta` 会合并去重。
- 非流式响应归一化为 OpenAI chat completion。
- 流式目前转发 Claude 原生 SSE data，不做 OpenAI chunk 化；前端或日志层按 source 理解。

### 13.4 Gemini / Vertex HTTP

`makersuite.rs`：

- models: GET `<base>/v1beta/models`，只保留支持 `generateContent` 的模型，返回 `{ data: [{ id }] }`。
- generate: URL `models/<model>:generateContent`。
- stream: URL `models/<model>:streamGenerateContent?alt=sse`。
- 鉴权同时支持 `x-goog-api-key` header 和 `key=` query；如果 explicit `Authorization` 存在，则不用 key。
- 非流式响应归一化为 OpenAI chat completion。
- 流式 SSE 直接转发。

`vertexai.rs`：

- models bypass。
- URL 使用 `<base>/publishers/google/models/<model>:method`。
- 支持 API key query 或 Authorization bearer。
- 响应同 Gemini normalizer。

### 13.5 Normalizers

文件：`http_chat_completion_repository/normalizers.rs`

把非 OpenAI provider 响应统一成 OpenAI chat completion：

- `normalize_claude_response(response)`
- `normalize_gemini_response(response)`
- `normalize_openai_responses_response(response)`
- `normalize_gemini_interactions_response(response)`

统一输出形状：

```json
{
  "id": "...",
  "object": "chat.completion",
  "created": 123,
  "model": "...",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "...",
      "tool_calls": []
    },
    "finish_reason": "stop|length|tool_calls"
  }],
  "usage": {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "total_tokens": 0
  }
}
```

这层是保持 SillyTavern 前端行为一致的关键。比如 Claude 的 `tool_use`、Gemini 的 `functionCall`、OpenAI Responses 的 `function_call` 都会转成 OpenAI-style `tool_calls`。

## 14. Prompt Post Processing 与 Prompt Caching

### 14.1 Prompt Post Processing

文件：`payload/prompt_post_processing.rs`

支持 `custom_prompt_post_processing`：

```text
none, claude/merge, merge_tools, semi, semi_tools, strict, strict_tools, single
```

作用：

- 合并连续同 role message。
- system/example name 前缀处理。
- tool message 是否保留。
- strict 模式下修正 system/user 顺序并插入占位 user。
- single 模式把 assistant/user 都合并为 user 文本，并加角色名。
- 多媒体 block 用临时 token 保留，合并后再恢复成 content parts。

### 14.2 Prompt Caching

文件：

- `prompt_caching_plan.rs`
- `prompt_caching.rs`

策略：

- Claude source 默认可启用 Claude prompt cache。
- OpenRouter 如果模型名是 `anthropic/claude...`，使用 OpenRouter Claude cache_control 形状。
- NanoGPT 如果模型名包含 Claude，则加 `{ cache_control: { enabled: true, ttl } }`。
- Custom 只有 `custom_api_format=claude_messages` 且 `custom_claude_prompt_caching=true` 时启用。

`prompt_caching.rs` 会：

- 对 tools/system/messages 可缓存 block 做 SHA-256 digest。
- 保存上一次 digest snapshot。
- 按 system break、pre-history break、last common prefix 自动插入 `cache_control`。
- 避免用户手动 `cache_control` 与自动缓存混用。

OHOS 可以先暂缓 prompt caching，但接口设计要预留，因为 Claude/OpenRouter 的长上下文成本和速度会受它影响。

## 15. 日志层

文件：`src-tauri/src/infrastructure/logging/llm_api_logs.rs`

`LoggingChatCompletionRepository` 包装真实 repository：

- 非流式记录 request JSON、response JSON、耗时、source、model、endpoint。
- 流式记录 request JSON 和 SSE 原文。
- 同时生成 readable request/response，便于 UI 查看。
- `StreamReadableCollector` 针对不同 source 提取可读文本：
  - OpenAI-like 读 `choices[].delta.content`
  - Claude 读 `content_block_delta.delta.text`
  - Gemini 读 `candidates[].content.parts[].text`
  - Cohere 读 `delta.message.content.text`

这块对 OHOS 不是 MVP 必需，但后续 debug provider 很有价值。

## 16. 文件总览

### 16.1 Presentation / Domain / Service

- `presentation/commands/chat_completion_commands.rs`：Tauri command 入口、stream channel、取消命令、stream id 校验。
- `application/dto/chat_completion_dto.rs`：status/generate DTO。generate 使用 flatten JSON。
- `domain/repositories/chat_completion_repository.rs`：provider enum、API config、stream sender/cancel receiver、repository trait。
- `application/services/chat_completion_service/mod.rs`：总编排，解析 source、检查策略、构建 config/payload、应用 prompt caching、调用 repository。
- `application/services/agent_model_gateway.rs`：agent 功能调用模型时的轻量 gateway，复用 `ChatCompletionService.generate_with_cancel()`。

### 16.2 Config / Custom / Caching

- `config.rs`：base URL、API key、reverse proxy、custom headers、Vertex AI auth、OpenRouter/ZAI extra headers。
- `custom_api_format.rs`：custom endpoint 格式枚举，决定 payload builder 和 status model list source。
- `custom_parameters.rs`：解析 YAML/JSON include/exclude headers/body。
- `prompt_post_processing.rs`：自定义 prompt 合并和 role 修正。
- `prompt_caching_plan.rs`：决定当前请求是否应用 Claude/OpenRouter/NanoGPT prompt caching。
- `prompt_caching.rs`：计算 digest、找 cache breakpoint、插入 `cache_control`。
- `vertexai_auth.rs`：Vertex service account OAuth access token 获取和缓存。

### 16.3 Payload Builders

- `payload/mod.rs`：provider builder 分发。
- `payload/shared.rs`：通用字段插入、content 转文本、data URL 解析、custom body include/exclude。
- `payload/tool_calls.rs`：OpenAI tool_calls 解析、tool result 归一。
- `payload/openai.rs`：OpenAI/OpenAI-compatible 基础 body。
- `payload/openrouter.rs`：OpenRouter provider 参数、web search、fallback、reasoning。
- `payload/deepseek.rs`：DeepSeek thinking、reasoning_content、assistant prefix、工具 schema 修正。
- `payload/moonshot.rs`：Moonshot thinking flag。
- `payload/zai.rs`：Z.AI thinking flag。
- `payload/nanogpt.rs`：NanoGPT web search model suffix、reasoning effort 映射。
- `payload/chutes.rs`：Chutes 特殊字段补转发。
- `payload/cohere.rs`：Cohere `/chat` payload、messages/tools/schema 适配。
- `payload/custom.rs`：custom format 分发和 OpenAI-compatible include/exclude。
- `payload/openai_responses.rs`：OpenAI Responses API body、input/tool follow-up 结构。
- `payload/claude.rs`：Claude builder 入口和校验。
- `payload/claude_messages.rs`：custom Claude Messages passthrough + include/exclude。
- `payload/claude/*`：Claude messages/tools/contract/validation/reasoning 细分实现。
- `payload/makersuite.rs`：Gemini/MakerSuite/Vertex payload，含 contents、tools、thinking、image modality。
- `payload/vertexai.rs`：Vertex payload 复用 MakerSuite。
- `payload/gemini_interactions.rs`：custom Gemini Interactions API body。

### 16.4 HTTP Repository

- `http_chat_completion_repository/mod.rs`：统一 reqwest client、auth/header helpers、SSE parser、provider dispatch。
- `openai.rs`：OpenAI-like models/generate/stream。
- `claude.rs`：Anthropic headers/auth/beta/prompt cache usage/normalizer。
- `makersuite.rs`：Gemini models/generate/stream URL 和 auth。
- `vertexai.rs`：Vertex AI generate/stream URL 和 auth。
- `cohere.rs`：Cohere models normalization、generate/stream。
- `openai_responses.rs`：Responses API response/stream 转 OpenAI chat chunk，维护 previous_response_id。
- `gemini_interactions.rs`：Interactions API response/stream 转 OpenAI chat completion/chunk。
- `normalizers.rs`：Claude/Gemini/Responses/Interactions 非流式响应转 OpenAI chat completion。

## 17. 对 OHOS ArkTS 的建议接口落点

当前 `entry/src/main/ets/backend/ModelProxyService.ets` 可以按 TauriTavern 拆成以下模块：

```text
backend/model/
  ChatCompletionTypes.ets
  ChatCompletionService.ets
  ChatCompletionConfigResolver.ets
  payload/
    PayloadBuilderRegistry.ets
    OpenAiPayloadBuilder.ets
    CustomPayloadBuilder.ets
    OpenRouterPayloadBuilder.ets
    DeepSeekPayloadBuilder.ets
    ClaudePayloadBuilder.ets
    GeminiPayloadBuilder.ets
    CoherePayloadBuilder.ets
    OpenAiResponsesPayloadBuilder.ets
    GeminiInteractionsPayloadBuilder.ets
    PromptPostProcessing.ets
    ToolCalls.ets
    Shared.ets
  http/
    ChatCompletionRepository.ets
    OpenAiTransport.ets
    ClaudeTransport.ets
    GeminiTransport.ets
    VertexAiTransport.ets
    CohereTransport.ets
    OpenAiResponsesTransport.ets
    GeminiInteractionsTransport.ets
    ResponseNormalizers.ets
    SseParser.ets
```

建议 ArkTS 接口：

```ts
type ChatCompletionSource =
  'openai' | 'openrouter' | 'custom' | 'claude' | 'makersuite' |
  'vertexai' | 'deepseek' | 'cohere' | 'groq' | 'moonshot' |
  'nanogpt' | 'chutes' | 'siliconflow' | 'zai';

interface ChatCompletionApiConfig {
  baseUrl: string;
  apiKey: string;
  authorizationHeader?: string;
  extraHeaders: Record<string, string>;
  anthropicBetaHeaderMode: 'none' | 'prompt_caching_only' | 'claude_defaults';
}

interface BuiltPayload {
  endpointPath: string;
  body: JsonRecord;
}

interface ChatPayloadBuilder {
  build(payload: JsonRecord): BuiltPayload;
}

interface ChatCompletionRepository {
  listModels(source: ChatCompletionSource, config: ChatCompletionApiConfig): Promise<JsonValue>;
  generate(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string, payload: JsonValue): Promise<JsonValue>;
  generateStream(source: ChatCompletionSource, config: ChatCompletionApiConfig, endpointPath: string, payload: JsonValue, send: StreamSend, cancel: CancelToken): Promise<void>;
}
```

`ModelProxyService.chatCompletionsGenerate()` 最终应变成薄入口：

```text
parse body
source = parseSource(body.chat_completion_source)
config = resolveGenerateApiConfig(source, body)
built = buildPayload(source, body)
if stream: repository.generateStream(...)
else: repository.generate(...)
```

## 18. 建议实现顺序

1. 先抽出 `ChatCompletionSource`、`ChatCompletionApiConfig`、`BuiltPayload`、`ChatCompletionRepository`，不改变现有 openai/custom 行为。
2. 把当前 `openAiChatCompletionBody()` 提取为 `OpenAiPayloadBuilder`，补 `/completions` legacy 分流。
3. 把 custom include/exclude/header 逻辑提取为 `CustomPayloadBuilder` 和 `CustomParameterParser`，尽量增强 YAML/JSON 兼容。
4. 补 OpenAI-compatible 专属 provider：OpenRouter、DeepSeek、Moonshot、NanoGPT、Chutes、ZAI、Groq、SiliconFlow。它们大多复用 OpenAI transport。
5. 再做 Cohere，因为 payload 差异中等，但响应/stream 相对简单。
6. Claude 单独做一轮：messages/tools/schema/thinking/model contract/normalizer。
7. Gemini/MakerSuite/Vertex 单独做一轮：contents/parts/tools/thinking/image modality/normalizer。
8. OpenAI Responses 和 Gemini Interactions 放后面，它们的 stream event 到 OpenAI chunk 转换更细。
9. Prompt caching 和 LLM API log 可以作为后续增强，但接口要提前预留。

## 19. 当前 OHOS 与 TauriTavern 的差距

当前 OHOS 已有：

- OpenAI/custom chat-completions 最小可用。
- status `/models`。
- 非流式 JSON 和流式 SSE 透传。
- OpenAI body 字段清理、tools/tool_choice、logprobs、json_schema response_format、部分 reasoning/verbosity。

主要缺口：

- Provider gate 和 builder registry 已落地，OpenAI-compatible、Claude、Gemini/MakerSuite、Vertex、Cohere 等主路径已有专门 builder/normalizer。
- OpenRouter/DeepSeek/NanoGPT/ZAI/Moonshot 等 OpenAI-compatible 专属参数已补主路径，但仍需要真实服务回归。
- Claude/Gemini/Cohere 已有专门 payload builder、model contract 和 response normalizer，但边界模型、工具调用和多模态仍要用真实端点补回归样例。
- OpenAI Responses/Gemini Interactions 已有 custom format builder 和 stream 转换基础版，仍需更多事件类型对齐。
- custom YAML/JSON parser 不如 TauriTavern 的 `serde_yaml` 完整。
- prompt post processing、prompt caching、LLM API logs 已迁移基础行为；剩余主要是真实请求样例回归、UI 差异和事件细节。

## 20. 当前 ArkTS 重写落地状态

本轮已经按 TauriTavern 的思路把 OHOS 后端的 chat-completions 从 `ModelProxyService.ets` 拆出，落点为：

```text
entry/src/main/ets/backend/model/
  ChatCompletionTypes.ets
  SourceRegistry.ets
  ChatCompletionConfigResolver.ets
  CustomApiFormat.ets
  CustomParameters.ets
  JsonHelpers.ets
  ChatCompletionService.ets
  payload/
    PayloadBuilderRegistry.ets
    OpenAiPayloadBuilder.ets
    OpenRouterPayloadBuilder.ets
    DeepSeekPayloadBuilder.ets
    OpenAiCompatiblePayloadBuilders.ets
    ClaudePayloadBuilder.ets
    GeminiPayloadBuilder.ets
    CoherePayloadBuilder.ets
    CustomPayloadBuilder.ets
    OpenAiResponsesPayloadBuilder.ets
    GeminiInteractionsPayloadBuilder.ets
    Shared.ets
  http/
    ChatCompletionRepository.ets
    ResponseNormalizers.ets
```

文件职责：

- `ChatCompletionService.ets`：HTTP route 之后的编排层，负责解析 `chat_completion_source`、处理 status/generate/stream、调用 config resolver、payload registry 和 repository。
- `ChatCompletionConfigResolver.ets`：统一处理默认 base URL、reverse proxy、custom URL、API key、Authorization/custom headers、Claude beta header、Vertex AI express/full 鉴权。
- `VertexAiAuth.ets`：解析 service account JSON，使用 HarmonyOS CryptoFramework 做 RSA-SHA256 JWT 签名，请求 Google OAuth access token，并按 service account JSON digest 缓存 token。
- `SourceRegistry.ets`：provider 名称解析、别名、secret key 映射、reverse proxy 支持范围。
- `CustomApiFormat.ets` / `CustomParameters.ets`：处理 `custom_api_format`，以及 `custom_include_headers/custom_include_body/custom_exclude_body` 的 JSON/简化 YAML 解析。
- `payload/*`：只负责把 SillyTavern 前端传入的 OpenAI-like payload 转成各 provider 上游请求体和 endpoint path，不发网络请求。
- `http/ChatCompletionRepository.ets`：只负责拼 URL、鉴权 header、发起 GET/POST/SSE、按 endpoint/source 做响应归一化。
- `http/ResponseNormalizers.ets`：把 Claude、Gemini、Cohere、OpenAI Responses、Gemini Interactions 的非流式响应转成 OpenAI chat completion 形状。
- `ModelProxyService.ets`：现在 chat-completions 只做薄委托，text-completions、NovelAI、Horde、Stable Diffusion 代理仍留在原文件。

当前已接入的 provider：

- OpenAI：`/chat/completions`、legacy `/completions` 分流、status `/models`、流式 SSE 透传。
- Custom OpenAI-compatible：支持 `custom_url/reverse_proxy`、保存的 `api_key_custom`、显式 `Authorization` header 优先、include/exclude body/header。
- OpenRouter：复用 OpenAI payload，并补 `min_p/top_a/repetition_penalty/include_reasoning/middleout/web search/provider/fallback/reasoning` 等参数。
- DeepSeek：复用 OpenAI payload，并补 thinking 开关、reasoning effort 映射、reasoning_content/prefix、空 required schema 清理。
- Moonshot / Z.AI：复用 OpenAI payload，并根据 `include_reasoning` 生成 `thinking`。
- NanoGPT：复用 OpenAI chat payload，补 web search `:online` 后缀和 reasoning effort 映射。
- Chutes：复用 OpenAI payload，补 `min_p/repetition_penalty/reasoning_effort`。
- Groq / SiliconFlow：按 OpenAI-compatible provider 走统一 OpenAI payload/transport。
- Claude：已做 OpenAI-like messages 到 Anthropic Messages 的转换，含 system 提取、文本/图片 block、tool result、OpenAI tools 到 Claude tools、json_schema 强制 tool、thinking budget、model contract、assistant prefill、sampling/thinking/output effort 校验；非流式响应归一化为 OpenAI chat completion。
- Gemini/MakerSuite：已做 messages 到 `contents/systemInstruction/generationConfig/tools` 的转换，支持 data URL 图片/视频/音频、function declarations、function call/result、custom Google tools、web search、json_schema response mime/schema、thinkingBudget/thinkingLevel、image generation response modalities/imageConfig；非流式响应归一化。
- Vertex AI：复用 Gemini payload，URL 改为 Vertex publisher model endpoint；支持 express API key 与 full service account OAuth；status 目前按 TauriTavern 思路 bypass。
- Cohere：已做 `/chat` payload 转换，含 messages、sampling 参数、stop、tools、json_schema；status models 和非流式响应归一化。
- Custom formats：`openai_compat`、`openai_responses`、`claude_messages`、`gemini_interactions` 都有 builder 分发。

当前仍不完整或需要下一轮精修的点：

- Prompt post processing 已迁移 `none/merge/merge_tools/semi/semi_tools/strict/strict_tools/single`，后续主要需要真实请求样例回归。
- Prompt caching 已迁移 plan、digest、cache_control、持久化快照、usage 日志；TTL 默认按 TauriTavern 从 settings 读取，默认 off。
- LLM API logging 已补 ArkTS 文件日志：每次 generate 会写入 `index/meta/request/response`，保存 raw JSON 或 raw SSE，并生成 request/response readable 预览；新增 `/api/dev/llm-api-logs`、`/preview`、`/raw`、`/settings`、`/keep`、`/stream-enabled`、`/stream`。默认 keep=5，可配置到 100；`/stream` 使用 HTTP SSE 推送 `llm-api-log` 事件，rawfile 前端的扩展抽屉已加入 `LLM API Logs` 面板。和 TauriTavern 相比，OHOS 走 HTTP SSE 而不是 Tauri event bus，连接清理依赖心跳/发送失败。
- Claude 已补常用 model contract，但仍需要用真实新旧 Claude 模型做 sampling/thinking/assistant prefill 的边界回归。
- Gemini/Vertex 已补常用多模态、function output、Gemini 2.5/3 thinking 映射；仍需要用真实 Gemini/Vertex 端点做全路径回归。
- OpenAI Responses 和 Gemini Interactions 的非流式已做基础归一化，流式已转换成 OpenAI chat completion chunk；还需要更多真实 provider 回归样例。
- Custom YAML/JSON override 解析已增强：JSON 优先，YAML 支持常用顶层/嵌套 map、list、inline map/list、引号、布尔/null/数字和行内注释，可覆盖 include/exclude body/header 的常见形状；仍不是完整 `serde_yaml` 等价实现，复杂 anchors、merge keys、多行 block scalar 暂不支持。
- Vertex AI full service account OAuth 已实现 JWT/OAuth access token 流程；需要在真机/模拟器上用真实 service account 验证 CryptoFramework 的 RSA 算法名兼容性。

验证状态：

- 使用 `DEVECO_SDK_HOME=E:\Huawei\DevEco Studio\sdk`、`OHOS_SDK_HOME=E:\Huawei\DevEco Studio\sdk\default\openharmony` 执行 `hvigorw.bat assembleHap --mode module -p module=entry@default -p product=default`，构建通过。
- 构建仍会输出项目既有 warning：部分旧文件的异常处理提示，以及 `rawfile/public/global.d.ts` 被打包的 source code warning；这些不是本轮 provider 分层新增错误。

## 21. 行为等价补齐进度

目标：继续以 TauriTavern 为参照，把 provider 层从“结构等价/基础可用”补到“常用行为尽量等价”。本节作为连续迁移日志，后续每完成一块都更新，避免上下文压缩后丢失状态。

当前任务拆分：

- [x] 行为基线：为关键 provider 建立可对照的 payload/stream 样例和验证入口。
- [x] Prompt post processing：迁移 `none/merge/merge_tools/semi/semi_tools/strict/strict_tools/single`。
- [x] Claude：补 model contract、assistant prefill、sampling/thinking/output effort、messages/tools/validation。
- [x] Gemini/Vertex：补多模态 parts、function call/result、thinkingBudget/thinkingLevel、Vertex full OAuth。
- [x] OpenAI Responses / Gemini Interactions：补原生 SSE 到 OpenAI chat chunk 的流式转换。
- [x] Prompt caching：补 Claude/OpenRouter/NanoGPT cache plan、digest、cache_control 插入和 usage 记录。
- [x] 取消、日志、错误映射：补 generation/stream cancel registry、LLM API readable logs、上游错误分类。
- [x] Custom overrides：补常用 YAML/JSON include/exclude body/header 解析。
- [x] Vector embedding provider：补 SillyTavern 常用 provider 请求形状和批量 embedding。

迁移日志：

- 2026-05-03：已提交 `54bcaff Add ArkTS chat completion provider layer`，作为 provider 分层第一版基线。
- 2026-05-03：开始补齐行为等价，优先迁移 prompt post processing。
- 2026-05-03：完成 `PromptPostProcessing.ets`，在 `PayloadBuilderRegistry` 中按 TauriTavern 行为对非 DeepSeek provider 统一应用；支持 merge/semi/strict/single、tools 保留开关、example name 前缀、多媒体 token 暂存/恢复。HAP 构建通过。
- 2026-05-03：Claude builder 拆分为 `payload/claude/*`，补齐 model contract、assistant prefill 与 reasoning_effort 互斥校验、legacy/adaptive thinking、output_config.effort、sampling 参数限制、messages/tools/validation。HAP 构建通过。
- 2026-05-03：Gemini/Vertex builder 对齐 TauriTavern 常用行为：前置 systemInstruction 提取、tool call/result name 回填、OpenAI tools 到 `function_declarations`、custom Google tools、web search、data URL 图片/视频/音频 parts、Gemini 2.5/3 thoughtSignature 处理、thinkingBudget/thinkingLevel、image generation response modalities/imageConfig、Vertex 额外 safetySettings。HAP 构建通过。剩余：Vertex full service account OAuth 仍未做真实 JWT/OAuth 换 token。
- 2026-05-03：新增 `RemoteHttpClient.streamPostJsonEvents()` 和 `http/StreamNormalizers.ets`；`/responses`、`/interactions` 流式响应现在会解析上游 SSE `data:` 事件并转换为 OpenAI chat completion chunk，支持文本 delta、reasoning_content、tool_calls、finish_reason、`[DONE]`。普通 OpenAI-compatible provider 仍走原始 SSE 透传。HAP 构建通过。
- 2026-05-03：新增 `PromptCaching.ets` 并接入 `ChatCompletionService`。Claude、OpenRouter Claude、NanoGPT Claude、custom `claude_messages` 在请求前会计算 digest、维护进程内 snapshot，并插入根级和 system/pre-history/last-common block 级 `cache_control: { type: "ephemeral", ttl: "5m" }`；custom Claude 会把 `anthropic-beta` 限制为 prompt caching 模式。HAP 构建通过。剩余：snapshot 目前是进程内内存，未持久化到 data 目录；cache usage 仅靠上游响应字段归一化，未做专门日志统计。
- 2026-05-03：新增 `CancellationToken.ets`，`ChatCompletionService` 维护 `request_id/stream_id` registry，`RemoteHttpClient` 在 token 取消时调用 HarmonyOS HTTP request destroy，并在流式回调中停止后续输出；新增 `/api/backends/chat-completions/cancel-stream` 和 `/api/backends/chat-completions/cancel-generation`。同时 repository 对上游 400/401/403/429/5xx 做分类错误 message，服务层输出 `[LLM] source/endpoint/model/stream/base` 轻量日志。HAP 构建通过。限制：HarmonyOS HTTP 已进入系统不可中断阶段时，取消可能只能停止后续输出，不能保证立即终止底层网络。
- 2026-05-03：补齐 Vertex AI full service account OAuth：新增 `VertexAiAuth.ets`，解析 `vertexai_service_account_json`，用 HarmonyOS `cryptoFramework` 导入 PEM private key、生成 RS256 JWT assertion，请求 `oauth2.googleapis.com/token`，并按 service account JSON 的 SHA256 digest 缓存 access token；`ChatCompletionConfigResolver.resolveGenerateConfig()` 改为 async，full 模式现在使用 `Authorization: Bearer <access_token>` 和 service account 内的 `project_id` 拼 Vertex base URL。HAP 构建通过。限制：RSA 签名算法名已通过 ArkTS 编译，仍需要用真实 service account 在模拟器/真机验证运行时兼容性。
- 2026-05-03：补齐 prompt cache 持久化与 usage 日志：`PromptCaching.ets` 现在从请求字段或 `default-user/settings.json` 的 `models.claude.prompt_cache_ttl` 读取 TTL，默认 off；支持 `5m/1h`，拒绝自动缓存与手动 `cache_control` 混用；Claude/OpenRouter digest snapshot 写入 `data/_cache/prompt-cache/*.json`；NanoGPT Claude 使用 `{ enabled: true, ttl }` 形状。`RemoteHttpClient.streamPostJsonWithEventHook()` 能在保持 SSE 原样透传时旁路解析 `data:` 事件，`ChatCompletionRepository` 会记录 `cache_creation_input_tokens/cache_read_input_tokens/input_tokens`。HAP 构建通过。
- 2026-05-03：新增 `PROVIDER_BEHAVIOR_VALIDATION.md`，记录 OpenAI-compatible SSE 透传、OpenAI Responses/Gemini Interactions stream chunk 转换、Claude/OpenRouter/NanoGPT prompt cache、Vertex full OAuth 的验证样例和期望观察点，作为后续真实 provider 回归入口。
- 2026-05-03：新增 `LlmApiLogger.ets` 并接入 `ChatCompletionRepository`。非流式请求记录原始上游 JSON、归一化 readable response 和错误信息；流式请求记录原始 SSE，普通 OpenAI-compatible 透传保持不变，Responses/Interactions 记录上游 raw SSE，同时从转换后的 OpenAI chunk 提取 readable 文本。日志写入 `data/_cache/llm-api-logs/`，默认保留最近 5 条，并通过 `/api/dev/llm-api-logs`、`/api/dev/llm-api-logs/preview?id=<id>`、`/api/dev/llm-api-logs/raw?id=<id>` 查看。随后补齐 `/settings`、`/keep`、`/stream-enabled`、`/stream`，支持可配置 keep、HTTP SSE 实时事件订阅，以及 rawfile 前端扩展抽屉里的 `LLM API Logs` 面板。HAP 构建通过。限制：OHOS 这里不是 Tauri event bus，而是 HTTP SSE；订阅清理依赖心跳/发送失败。
- 2026-05-03：`CustomParameters.ets` 从简单 `key: value` parser 升级为常用 YAML/JSON override parser：支持嵌套 map、list、inline map/list、quoted string、bool/null/number、注释 stripping 和 exclude key list；继续保持 JSON 优先。HAP 构建通过。限制：不实现完整 YAML anchors、merge keys、多行 block scalar。
- 2026-05-03：`VectorService.ets` 对齐原版 SillyTavern embedding provider 形状：insert 改为 10 条一批生成 embedding；OpenAI-compatible/Mistral/TogetherAI/OpenRouter/ElectronHub/NanoGPT/SiliconFlow/Chutes 使用批量 `/embeddings`；Cohere 改为 v2 `/embed` + `texts/embedding_types/input_type/truncate`；Ollama 改为 `/api/embed`；Extras 使用 `{ text }`；NomicAI、MakerSuite/Google、Vertex AI 增加基础 embedding 请求与响应解析；llamacpp/vllm 去掉重复 `/v1` 后拼 `/v1/embeddings`。失败或未配置仍回退本地 hash vector。HAP 构建通过。限制：本地索引仍是 JSON + cosine scan，不是 `vectra.LocalIndex` 性能等价实现；Vertex embedding 只覆盖 express API key 基础路径，未复用 full service account OAuth。
