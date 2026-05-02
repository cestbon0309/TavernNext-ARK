# Provider Behavior Validation

本文件记录 ArkTS provider 层的行为等价验证入口。目标不是替代真实 provider 回归，而是在每次补齐 provider 行为后保留可重复的请求样例、预期上游形状和观察点。

## 1. OpenAI-Compatible Stream Pass-Through

用途：确认普通 OpenAI-compatible provider 仍保持原始 SSE 透传，不被 Responses/Interactions normalizer 改写。

请求体关键字段：

```json
{
  "chat_completion_source": "custom",
  "custom_api_format": "openai_compat",
  "custom_url": "https://example.com/v1",
  "model": "openai-compatible-model",
  "messages": [
    { "role": "user", "content": "hello" }
  ],
  "stream": true
}
```

期望：

- ArkTS builder 输出 endpoint `/chat/completions`。
- `ChatCompletionRepository.generateStream()` 调用 `RemoteHttpClient.streamPostJson()`。
- 前端收到的 SSE data 事件与上游 OpenAI-compatible chunk 形状一致。

## 2. OpenAI Responses Stream Normalization

用途：确认 `custom_api_format=openai_responses` 会把 Responses API SSE 转成 SillyTavern 期望的 OpenAI chat completion chunk。

请求体关键字段：

```json
{
  "chat_completion_source": "custom",
  "custom_api_format": "openai_responses",
  "custom_url": "https://example.com/v1",
  "model": "gpt-5.1",
  "messages": [
    { "role": "user", "content": "hello" }
  ],
  "stream": true
}
```

期望：

- ArkTS builder 输出 endpoint `/responses`。
- 上游 `response.output_text.delta` 这类事件被转换为 `choices[0].delta.content`。
- reasoning 事件被转换为 `choices[0].delta.reasoning_content`。
- tool call 事件被转换为 OpenAI-style `choices[0].delta.tool_calls`。
- 完成事件输出 `[DONE]`。

## 3. Gemini Interactions Stream Normalization

用途：确认 `custom_api_format=gemini_interactions` 会把 Gemini Interactions SSE 转成 OpenAI chat completion chunk。

请求体关键字段：

```json
{
  "chat_completion_source": "custom",
  "custom_api_format": "gemini_interactions",
  "custom_url": "https://example.com/v1",
  "model": "gemini-2.5-pro",
  "messages": [
    { "role": "user", "content": "hello" }
  ],
  "stream": true
}
```

期望：

- ArkTS builder 输出 endpoint `/interactions`。
- 文本增量进入 `choices[0].delta.content`。
- reasoning/thought 增量进入 `choices[0].delta.reasoning_content`。
- function call 增量进入 OpenAI-style `tool_calls`。
- 完成事件输出 `[DONE]`。

## 4. Claude Prompt Cache

用途：确认 Claude/OpenRouter Claude prompt cache 按 TauriTavern 行为插入 breakpoint、持久化 digest，并记录 usage。

请求体关键字段：

```json
{
  "chat_completion_source": "claude",
  "model": "claude-sonnet-4-5",
  "prompt_cache_ttl": "5m",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "long pre-history text" }
      ]
    },
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "current message" }
      ]
    }
  ]
}
```

期望：

- 默认未设置 TTL 时 prompt cache 关闭；显式 `prompt_cache_ttl=5m/1h` 或 settings 中 `models.claude.prompt_cache_ttl` 才启用。
- 自动缓存启用时，如果 payload 已包含任意 `cache_control`，返回错误：`Claude prompt caching cannot be combined with manually supplied cache_control fields`。
- Claude/custom Claude Messages 插入 `{ "type": "ephemeral", "ttl": "5m" }`。
- NanoGPT Claude 插入 `{ "enabled": true, "ttl": "5m" }`。
- digest snapshot 写入 `data/_cache/prompt-cache/claude.json`、`openrouter_claude.json` 或 `custom_claude_<scope>.json`。
- 非流式响应或流式 SSE 中出现 `usage.cache_creation_input_tokens/cache_read_input_tokens/input_tokens` 时，控制台输出 `[LLM] <source> prompt cache usage...`。

## 5. Vertex AI Full OAuth

用途：确认 Vertex full service account 模式不再把 service account JSON 当 bearer token，而是按 Google OAuth JWT bearer flow 换取 access token。

请求体关键字段：

```json
{
  "chat_completion_source": "vertexai",
  "vertexai_auth_mode": "full",
  "vertexai_region": "us-central1",
  "model": "gemini-2.5-pro",
  "messages": [
    { "role": "user", "content": "hello" }
  ]
}
```

预置：

- `secrets.json` 中存在 `vertexai_service_account_json`，内容为 Google service account JSON，必须包含 `client_email`、`private_key`、`project_id`，可包含 `private_key_id`。

期望：

- `VertexAiAuth.ets` 使用 service account private key 生成 RS256 JWT assertion。
- 后端 POST `https://oauth2.googleapis.com/token`，body 为 `application/x-www-form-urlencoded`。
- `ChatCompletionConfigResolver` 设置 `Authorization: Bearer <access_token>`。
- base URL 使用 service account 内的 `project_id`：`https://<region>-aiplatform.googleapis.com/v1/projects/<project_id>/locations/<region>`，`region=global` 时使用 `https://aiplatform.googleapis.com`。
- token 按 service account JSON SHA256 digest 缓存，并在过期前刷新。

注意：该路径已经通过 ArkTS/HAP 构建；RSA 签名算法名仍需要用真实 service account 在模拟器或真机上做一次运行时验证。
