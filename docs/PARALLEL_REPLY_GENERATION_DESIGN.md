# 聊天并发回复生成设计记录

本文档记录“发送一条用户消息，并发生成 N 个候选回复”的实现思路和风险点。

当前目标是先分析和规划，不在本文档内直接落实现。

---

## 1. 目标定义

需要新增一个并发生成能力：

- 聊天页面发送一条用户消息后，可以并发请求 `N` 个回复。
- `N == 1` 时，必须保持现有行为完全不变。
- 并发能力应由 `Generate()` 所在的应用编排层原生支持，不依赖 OpenAI-compatible 的 `n` / multi-choice 能力。
- 所有 `main_api` 类型都应通过统一的候选执行抽象参与并发，包括 OpenAI、textgenerationwebui、kobold、koboldhorde、novel 等。
- `N > 1` 时：
  - 只插入一条用户消息。
  - 并发发起 `N` 个模型请求。
  - 前端展示 `N` 个候选回复的生成状态。
  - 默认聊天流不再直接展示所有候选的流式文本。
  - 用户可以点进某一个候选，查看该候选的实时流式生成过程。
  - 最终候选结果应保存为同一条 assistant 消息的多个候选，而不是把聊天历史变成连续 `N` 条 assistant 消息。

首版建议只覆盖普通单人聊天的 `normal` 生成。群聊、续写、重新生成、手动 swipe、quiet prompt、impersonate、工具调用、auto-swipe、auto-continue 建议后续单独处理。

---

## 2. 当前生成链路观察

主生成入口在：

- `entry/src/main/resources/rawfile/public/script.js`
  - `Generate()`：聊天生成主流程
  - `StreamingProcessor`：当前流式生成处理器
  - `sendGenerationRequest()`：非流式请求
  - `sendStreamingRequest()`：流式请求
  - `saveReply()`：保存 assistant 回复
  - `stopGeneration()`：停止当前生成

相关后端入口：

- `entry/src/main/ets/backend/BackendService.ets`
  - `POST /api/backends/chat-completions/generate`
  - `POST /api/backends/chat-completions/cancel-stream`
  - `POST /api/backends/chat-completions/cancel-generation`
- `entry/src/main/ets/backend/model/ChatCompletionService.ets`
  - `activeStreams`
  - `activeGenerations`
  - `stream_id`
  - `request_id`

当前前端生成流程是明显的单活动生成模型：

- `is_send_press` 是全局发送锁。
- `abortController` 是全局取消控制器。
- `streamingProcessor` 是全局单例。
- `stopGeneration()` 默认只停止一个当前生成任务。
- `StreamingProcessor` 会直接创建或更新唯一一条聊天消息。
- `sendStreamingRequest()` 会读取全局 `streamingProcessor.abortController.signal`。
- `sendGenerationRequest()` 会读取全局 `abortController.signal`。

不过，所有 LLM 类型最终都会经过 `Generate()` 内部的共同准备流程，并在 `switch (main_api)` 后形成各自的 `generate_data`。这个位置是实现“应用层原生并发”的合适切入点：prompt 只准备一次，然后为每个候选复制请求数据并分别调用当前 `main_api` 的请求适配器。

因此，并发模式不适合在外部简单循环调用完整的 `Generate()`。直接循环会导致：

- 全局发送锁互相覆盖。
- 全局 abort controller 互相覆盖。
- 全局 streaming processor 只能指向最后一个任务。
- 多个任务同时写同一条或多条 chat DOM，消息 ID 容易错位。
- 停止按钮、事件派发、自动续写、自动 swipe 的语义会混乱。

---

## 3. 数据模型选择

推荐把并发候选保存为同一条 assistant 消息的 `swipes`。

原因：

- 现有 SillyTavern 聊天数据已经用 `swipes` 表示一条 assistant 回复的多个候选。
- `saveReply()` 已经会初始化和维护：
  - `message.swipes`
  - `message.swipe_id`
  - `message.swipe_info`
- OpenAI / text-generation 的多 choice 响应已经会通过 `extractMultiSwipes()` 转成额外 swipes。
- 保存为 swipes 后，后续查看、切换、删除候选可以复用现有 swipe 体系。

不推荐把 `N` 个候选保存成连续 `N` 条 assistant 消息。

这样虽然 UI 直观，但会改变聊天历史语义：

- 下一轮 prompt 会看到连续多个 assistant 回复。
- 删除、编辑、重新生成、swipe 逻辑都会变复杂。
- 角色卡正则、脚本、扩展事件可能把它们当成真实多轮对话。
- 与 SillyTavern 现有 chat JSON 语义不一致。

---

## 4. 推荐架构

将 `Generate()` 重构为原生支持“一个生成会话、一个或多个候选任务”的编排器。

`N == 1`：

- 仍通过同一个 generation session 执行，但只有一个 candidate。
- 对外行为必须与当前 `Generate()` 完全一致。
- 可以保留 legacy rendering adapter，让单候选流式输出仍直接更新当前聊天消息。

`N > 1`：

- 使用同一个 `Generate()` 编排入口。
- `Generate()` 完成一次用户消息插入、prompt 构造、WI 注入、扩展 prompt 注入和 `generate_data` 构造。
- 随后创建 `ParallelGenerationSession`，启动 `N` 个 candidate task。
- 每个 candidate task 调用相同 `main_api` 下的统一请求执行器。
- 不依赖 provider 原生 multi-choice；应用层自己发起 `N` 个独立请求，并把结果合并成 swipes。

建议会话结构：

```js
{
  id: "parallel-session-id",
  type: "normal",
  count: 4,
  status: "running",
  startedAt: Date,
  finishedAt: Date | null,
  userMessageId: number,
  assistantMessageId: number | null,
  selectedCandidateId: string | null,
  candidates: [
    {
      id: "candidate-0",
      index: 0,
      status: "pending | streaming | done | error | stopped",
      abortController: AbortController,
      requestId: "parallel-...-0",
      streamId: "parallel-...-0",
      startedAt: Date | null,
      finishedAt: Date | null,
      text: "",
      displayText: "",
      reasoning: "",
      reasoningDuration: null,
      images: [],
      logprobs: [],
      toolCalls: [],
      error: null,
      timeToFirstToken: null,
      tokenCount: 0
    }
  ]
}
```

---

## 5. 建议拆分步骤

### 5.1 增加设置入口

新增并发回复数设置，例如 `parallel_reply_count`。

这个设置属于聊天生成编排层，不属于某个 provider。

注意不要复用 OpenAI 设置里的 `n`。

现有 `oai_settings.n` 是 provider 原生 multi-choice/multi-swipe 参数。并发回复数是应用层发起多个独立请求。两者混用会导致候选数量变成 `parallel_reply_count * oai_settings.n`。

并发模式下，每个候选请求都应强制 provider 原生 choice 数为 1，或者显式绕过 multi-swipe 参数。OpenAI-compatible 只是这个统一模型里的一个 adapter，不能成为并发语义的来源。

### 5.2 拆出生成准备阶段

当前 `Generate()` 同时做了很多事情：

- 处理 slash command。
- 读取并清空输入框。
- 插入用户消息。
- 构造角色卡、世界书、扩展 prompt。
- 构造 provider request data。
- 发请求。
- 保存回复。
- 事件派发。
- UI 解锁。

并发实现前，建议先把 `Generate()` 拆成“准备、执行、落库”三个阶段：

- `prepareGenerationContext()`
  - 完成用户输入、角色卡字段、WI、扩展 prompt、token 统计等准备。
- `buildGenerationData()`
  - 根据 `main_api` 生成 `generate_data`。
- `createPromptItemization()`
  - 生成 itemized prompt 记录。
- `executeGenerationSession()`
  - 根据 `parallel_reply_count` 启动一个或多个 candidate。
- `finalizeGenerationSession()`
  - 将候选结果按单回复或 swipes 方式写回聊天记录。

并发模式应只插入一次用户消息，只构造一次 prompt 基础数据。

### 5.3 新增候选请求执行器

新增单候选执行器，例如 `runGenerationCandidate(session, candidate, generateData)`。

职责：

- 克隆基础 `generate_data`。
- 注入候选自己的 `request_id` / `stream_id`。
- 为候选创建独立 `AbortController`。
- 通过统一请求适配器发送当前 `main_api` 的流式或非流式请求。
- 把流式 token 写入候选自己的 buffer。
- 只更新候选状态 UI，不直接写正式 chat message。
- 请求完成后保存最终文本、reasoning、图片、logprobs、耗时等信息。

统一请求适配器需要覆盖所有现有 API 类型：

- `openai`：调用 `sendOpenAIRequest()`，但传入候选自己的 signal 和单 choice 参数。
- `textgenerationwebui`：调用 textgen 非流式 / 流式请求，传入候选自己的 signal。
- `kobold`：调用 kobold 非流式 / 流式请求，传入候选自己的 signal。
- `koboldhorde`：调用 Horde 任务请求，传入候选自己的 signal，并尽量复用现有 cancel-task。
- `novel`：调用 NovelAI 非流式 / 流式请求，传入候选自己的 signal。

这要求 `sendGenerationRequest()` / `sendStreamingRequest()` 不再从全局 `abortController` 和全局 `streamingProcessor` 取 signal，而是显式接收 candidate options。

### 5.4 拆出轻量流式消费器

现有 `StreamingProcessor` 不适合直接用于并发候选，因为它会：

- 创建正式 assistant 消息。
- 直接写 `chat[messageId].mes`。
- 直接更新 `.mes_text` DOM。
- 依赖全局 `streamingProcessor`。

并发模式建议新增轻量流式消费器：

- 只消费 async generator。
- 维护候选自己的 `text` / `reasoning` / `images` / `toolCalls`。
- 按节流频率通知候选 UI 刷新。
- 点开候选详情时，详情面板读取候选 buffer。

### 5.5 新增候选状态 UI

并发生成时，聊天流中可以显示一个候选容器，而不是直接展示所有流式文本。

容器应显示：

- 每个候选的序号。
- 状态：排队中、生成中、完成、失败、已停止。
- 简短预览。
- 耗时 / token 数 / 首 token 延迟。
- 错误提示。
- 点击查看流式详情。
- 选择某个候选作为当前 `swipe_id`。
- 停止单个候选。
- 停止全部候选。

详情视图可以是弹层、抽屉或内嵌展开区域。关键是不要让 `N` 个流式内容同时挤在主聊天流里。

### 5.6 完成后合并保存

当候选完成后，创建或更新一条 assistant 消息：

- 不再默认选择候选 0 或第一个成功候选。候选全部结束后，聊天流继续显示候选状态 UI，直到用户明确选择某个候选。
- 所有成功候选写入 `message.swipes`。
- 每个候选的元信息写入对应 `message.swipe_info`。
- `message.extra.display_text` 保存候选状态 UI，`message.extra.parallel_generation_pending_selection` 表示这条消息仍在等待用户选择。
- 等待选择期间，这条消息应从后续 prompt 中排除，避免把候选状态文本当成角色回复。
- 候选状态快照写入 `message.extra.parallel_generation_session`，生成会话清理后仍可点开候选详情。
- 用户在候选详情弹窗点击“切换到此回复”后，才把对应 `swipe_id` 同步为当前 `message.mes`，并移除候选状态 UI / pending 标记。

失败候选是否保存需要明确：

- 推荐首版不把失败候选保存进 `swipes`。
- UI 可在本次生成容器中显示失败状态。
- 如果所有候选都失败，则不创建 assistant 消息，或者创建一条错误系统提示，具体跟现有错误处理保持一致。

### 5.7 保存时机

建议：

- 用户消息插入后可以按现有逻辑保存。
- 并发候选生成中需要持续更新前端状态，并把轻量候选快照保存到消息 extra，便于生成结束后继续查看。
- 候选全部完成后保存带候选 UI 的 assistant 消息；用户选择某个候选后再保存普通 assistant 消息。
- 如果要支持应用后台清理恢复，需要把进行中的 session 状态持久化，这会显著增加复杂度，建议不放首版。

---

## 6. 取消与停止

当前后端 chat-completions 已支持：

- `stream_id`
- `request_id`
- `cancel-stream`
- `cancel-generation`

并发模式建议每个候选都生成唯一 ID：

```text
parallel_<sessionId>_<candidateIndex>
```

取消策略：

- 停止单个候选：abort 该候选前端 `AbortController`，同时调用对应后端 cancel 接口。
- 单候选停止后必须丢弃已经生成到一半的内容，清空候选的文本、reasoning、额外 swipes、工具调用和 logprobs，不能把半截内容保存为 swipe。
- 已完成、失败、已停止的候选隐藏单候选停止按钮。
- 停止全部：遍历所有 running/streaming 候选执行取消。
- 顶部停止按钮在并发模式下应停止整个 session。

只依赖浏览器 `AbortController` 不够稳。应用切后台、连接断开、ArkTS 后端仍在处理时，显式后端取消 ID 更可靠。

---

## 7. 事件兼容性

现有扩展会监听：

- `GENERATION_STARTED`
- `GENERATION_ENDED`
- `GENERATION_STOPPED`
- `STREAM_TOKEN_RECEIVED`
- `MESSAGE_RECEIVED`
- `CHARACTER_MESSAGE_RENDERED`

并发模式需要谨慎设计事件语义。

建议首版：

- 整个并发 session 只发一次 `GENERATION_STARTED`。
- 整个并发 session 结束后只发一次 `GENERATION_ENDED`。
- 最终 assistant 消息落库时只发一次 `MESSAGE_RECEIVED` 和 `CHARACTER_MESSAGE_RENDERED`。
- 候选内部 token 不复用全局 `STREAM_TOKEN_RECEIVED`，避免扩展误以为主消息正在流式更新。

如需给扩展暴露候选流，可以新增独立事件，例如：

- `PARALLEL_GENERATION_STARTED`
- `PARALLEL_CANDIDATE_STARTED`
- `PARALLEL_CANDIDATE_TOKEN`
- `PARALLEL_CANDIDATE_FINISHED`
- `PARALLEL_GENERATION_FINISHED`

但首版可以先不公开新事件，只保证既有事件不被破坏。

---

## 8. Provider 与后端限制

并发请求本质上会增加实际请求数和费用。

需要考虑：

- Provider rate limit。
- Provider 对并发连接数的限制。
- 同一 seed 可能导致候选高度相似。
- 部分后端或本地模型服务可能不适合高并发。
- Horde 等排队型后端不适合按普通并发方式处理。

设计目标：

- 并发语义在 `Generate()` / generation session 层统一实现。
- 所有 `main_api` 类型都接入同一套 candidate task 管理。
- provider adapter 只负责“如何发一个候选请求”和“如何取消一个候选请求”。
- 不依赖任何 provider 的原生 multi-choice 能力。

现实约束：

- 不是所有 provider 都支持真正的并行处理。本地后端可能串行排队，Horde 可能远端排队，部分服务会限流。
- 不是所有 provider 都有等价的后端取消接口。没有后端取消能力时，至少要支持前端 abort，并把 UI 状态标记为 stopped。
- 同一 preset 下多个候选可能因为 seed 固定而高度相似。并发执行器需要考虑是否为候选生成不同 seed，或者在 seed 固定时提示用户。

首版建议：

- 默认并发数为 1。
- 设置上限，例如 2 到 4。
- 所有 `main_api` 都使用统一并发框架。
- 对取消能力弱或并发能力弱的 provider 保持相同 UI 语义，但允许底层实际串行或排队。
- 对可能产生费用或限流的 provider 给出轻量提示。

---

## 9. 与 provider 原生 multi-choice 的关系

当前 `scripts/openai.js` 中 `createGenerationParameters()` 会根据 `settings.n` 和 provider 支持情况设置请求体 `n`。

这是 provider 原生 multi-choice：

- 一个请求。
- provider 返回多个 choice。
- 前端通过 `extractMultiSwipes()` 保存为 swipes。

新功能是应用层并发：

- 多个请求。
- 每个请求一个候选。
- 前端把多个独立结果合并成 swipes。
- 同一套逻辑适用于所有 `main_api`。

两者应保持独立。

并发模式下建议：

- 强制每个候选请求的 provider 原生 choice 数为 1。
- 对 OpenAI-compatible，可在 `createGenerationParameters()` 增加选项，例如 `{ forceSingleChoice: true }`。
- 对 textgenerationwebui 等可能支持多返回的接口，也应在候选请求层压成单返回。
- 避免最终候选数量不可预测。
- 后续如果要组合“provider 原生 multi-choice + 应用层并发”，应作为高级功能单独设计。

---

## 10. 高风险点

### 10.1 工具调用

当前工具调用流程会在生成后递归调用 `Generate()`，并且会保存 tool invocation。它天然假设只有一个主回复。

首版并发模式禁用候选请求的工具调用。注意这里不能仅仅在“当前模型支持工具调用”时把并发降级为 `N == 1`，否则开启工具能力的 OpenAI-compatible 模型会永远无法使用应用层并发。实际实现应在并发候选请求选项里传 `disableTools: true`，让候选请求不注册工具，同时保留单路 `N == 1` 的原工具调用行为。

### 10.2 auto-swipe

auto-swipe 会在生成结果被过滤后自动触发下一次 swipe。并发模式已经在生成多个候选，再叠加 auto-swipe 会让候选来源不清晰。

首版建议并发模式禁用 auto-swipe。

---

### 10.3 auto-continue

auto-continue 会基于当前 message chunk 继续补全。并发模式下每个候选都可能需要 continue，成本和语义都会变复杂。

首版建议并发模式禁用 auto-continue。

### 10.4 群聊

群聊生成有成员选择、头像、group generation id、成员轮次等逻辑。

首版建议并发模式不支持群聊。

### 10.5 正则与脚本

最终落库为 swipes 后，只有当前选中 swipe 会成为 `message.mes`。这与现有 swipe 语义一致。

需要注意：

- 候选生成中不应对每个 token 都执行会影响正式聊天记录的角色卡脚本。
- 最终保存时，应按现有 `cleanUpMessage()` / `getRegexedString()` 流程处理候选文本。
- 切换候选时，现有 `syncSwipeToMes()` / `loadFromSwipeId()` 仍应负责同步当前 `message.mes`。

### 10.6 后台清理与恢复

如果用户在并发生成中直接清后台，前端临时候选状态会丢失。

首版可以接受这一点，因为当前普通流式生成也没有完整的进行中恢复能力。若要增强，需要把 session 和候选 buffer 持久化，并在启动时恢复或清理未完成 session，这应作为独立功能设计。

---

## 11. 建议实施顺序

1. 增加设置项和 UI 控制，只保存配置，不接入生成。
2. 重构 `Generate()` 为准备、执行、落库三个阶段，让现有 `N == 1` 行为保持不变。
3. 把 `sendGenerationRequest()` / `sendStreamingRequest()` 改成显式接收 candidate options，不再依赖全局 signal。
4. 新增统一 candidate request adapter，覆盖 openai、textgenerationwebui、kobold、koboldhorde、novel。
5. 新增 `GenerationSession` / `ParallelGenerationSession`，先让 `N == 1` 也通过 session 运行并通过现有测试。
6. 新增单候选执行器，先支持所有 API 类型的非流式并发。
7. 把多个非流式候选保存为同一条 assistant 消息的 swipes。
8. 新增候选状态容器 UI。
9. 增加轻量流式消费器和候选详情视图，让所有支持流式的 API 都能写入 candidate buffer。
10. 接入停止单个候选和停止全部。
11. 补充错误处理、保存时机、事件兼容。
12. 按 API 类型验证真实并发、串行排队、取消和限流表现。

---

## 12. 验证清单

`N == 1`：

- 普通发送行为不变。
- 流式显示不变。
- 停止按钮不变。
- 保存聊天不变。
- auto-continue / auto-swipe / tool calling 行为不变。

`N > 1`：

- 只插入一条用户消息。
- 同时出现 `N` 个候选状态。
- 每个候选独立成功、失败、停止。
- 点击候选可查看该候选流式内容。
- 主聊天流不同时显示 `N` 段完整流式文本。
- 完成后只产生一条 assistant 消息。
- 成功候选保存为 swipes。
- swipe 切换能看到不同候选。
- 停止全部不会留下后台生成。
- 保存并重载聊天后，候选 swipes 仍存在。

API 类型验证：

- OpenAI / Custom OpenAI-compatible 非流式与流式。
- textgenerationwebui 非流式与流式。
- Kobold 非流式与流式。
- NovelAI 非流式与流式。
- Horde 队列型生成和取消。
- 对底层串行或取消能力弱的 provider，UI 状态仍保持一致。

---

## 13. 当前结论

这个功能可行，但核心不是“循环调用现有生成函数”，也不是依赖 OpenAI-compatible 的 `n` 参数，而是把当前单例式 `Generate()` 重构为原生支持一个 generation session 下多个 candidate。

最稳的落点是：

- `Generate()` 保持唯一主入口。
- `N == 1` 通过 session 的单候选路径保持现有行为。
- `N > 1` 通过同一 session 启动多个 candidate task。
- 所有 `main_api` 类型都使用统一 candidate adapter。
- 每个候选独立请求、独立取消、独立 buffer。
- UI 展示候选状态和可选详情。
- 最终结果合并到一条 assistant 消息的 `swipes`。

这样对聊天历史语义、现有 swipe 体系和扩展兼容性影响最小。

---

## 14. 实施日志

### 2026-05-27 开工记录

当前实现策略：

- 先保持 `N == 1` 完全走现有路径。
- `N > 1` 在 `Generate()` 已完成用户消息插入、prompt 构造、WI 注入和 `generate_data` 构造后分流。
- 不在第一步拆完整 `Generate()`，避免一次性移动大段 prompt 构造逻辑导致行为回归。
- 新增候选请求执行器时，先让 `sendGenerationRequest()` / `sendStreamingRequest()` 支持显式 `AbortSignal` 和 candidate 选项，逐步摆脱全局 `abortController` / `streamingProcessor` 依赖。
- 并发结果优先保存为同一条 assistant 消息的 `swipes`，默认显示第一个成功候选。
- 首版先保证普通单人 `normal` 发送并发可用；其他生成类型保持 `N == 1` 原行为。

待实现关键点：

- 设置项：聊天并发回复数，默认 1。
- 请求层：所有 `main_api` 的非流式/流式请求都能传入 candidate signal。
- 流式并发：候选 token 写入独立 buffer，不直接写正式聊天消息。
- UI：`N > 1` 时在聊天流展示候选状态，可点开查看某个候选流式内容。
- 停止：停止按钮能停止整个并发 session。
- 验证：构建 HAP，并通过 hdc 安装/启动/端口映射或设备前端验证并发生成。

### 2026-05-27 实现切入点确认

第一版代码落点：

- 新增全局设置 `parallel_generation_count`，保存到 `settings.parallel_generation_count`。
- `N == 1` 仍走原 `finishGenerating().then(onSuccess, onError)` 路径。
- `N > 1` 只在普通单人 `normal` 生成触发，条件包括：
  - `type` 为 `normal` 或未指定。
  - 非 `quiet`、非 `continue`、非 `swipe`、非 `impersonate`。
  - 非 group chat。
  - 非 dry run。
  - 非 tool-calling 递归 depth。
- 并发分流位置在 `Generate()` 生成 `generate_data` 后、实际发请求前。
- 每个 candidate 使用独立 `AbortController`；全局停止按钮会停止整个并发 session。
- 并发时强制候选请求单返回，避免和 provider 原生 multi-choice 相乘。
- 并发流式不会使用 `StreamingProcessor`，而是消费 async generator 写入 candidate buffer。
- 并发完成后创建一条正式 assistant 消息：
  - 第一个成功候选作为 `message.mes`。
  - 所有成功候选写入 `message.swipes`。
  - 对应元信息写入 `message.swipe_info`。
  - 失败候选只保留在本次 UI 状态，不写入 swipes。

### 2026-05-27 第一版实现和修补

- 在 `Generate()` 的 prompt 和 `generate_data` 准备完成后分流；`N == 1` 继续走原有单路逻辑。
- 新增全局设置 `parallel_generation_count`，默认 `1`，当前 UI 上限 `8`。
- 并发仅在普通单人 `normal` 生成中启用；dry-run、群聊、续写、swipe、quiet、impersonate、递归工具调用均降级为单路。
- 每个候选有独立 `AbortController`、`request_id`、`stream_id`；OpenAI-compatible 候选强制 `forceSingleChoice`，textgen/kobold/novel 的请求体也会把 `n` 等多返回参数压成单返回。
- 候选流式输出不走全局 `StreamingProcessor`，不派发 `STREAM_TOKEN_RECEIVED`，只更新并发候选状态和候选详情弹窗。
- 最终只保存一条 assistant 消息：第一个成功候选为 `mes`，所有成功候选写入同一消息的 `swipes` / `swipe_info`。
- 所有候选都被用户停止时删除临时占位 assistant 消息并解锁 UI；所有候选失败则沿用生成错误流程。
- 并发候选的流式请求只检查候选自己的 signal，避免被旧的全局 `abortController` 状态误杀。
- 并发完成或全部停止后使用 `activateSendButtons()` 收尾，恢复停止按钮、生成状态和 swipe 按钮。
- 候选详情由静态 HTML 改成实时 DOM 视图，打开弹窗后会随着候选 buffer 更新。
- 顶部停止按钮在并发模式下会同时 abort 所有候选，并尽量调用 chat-completions 的 `cancel-stream` / `cancel-generation` 后端取消接口。
- 对固定 seed 的 provider，请求克隆时按候选 index 偏移 `seed` / `sampler_seed`，降低并发候选完全相同的概率。
- OpenAI 非流式候选请求关闭延迟保存 logprobs 的副作用，避免多个候选竞争“最后一条消息”的概率数据。
- 并发完成后改为走统一 `unblockGeneration(type)` 收尾，确保停止按钮、生成状态、临时停止串和 WI 注入状态都按普通生成流程恢复。
- `swipe_info.extra` 不复用第一个候选的 reasoning / token / 首 token 元数据；每个成功候选会独立写入自己的候选元信息，同时保留 `parallel_generation_count`。
- 修正工具调用兼容策略：`N > 1` 不再因为 `ToolManager.canPerformToolCalls()` 为真直接降级，而是在每个并发候选请求中传入 `disableTools: true`，OpenAI 参数构造时不注册 `tools/tool_choice`。这样应用层并发不会被 provider 原生 multi-swipe 掩盖，`N == 1` 仍保持原工具调用路径。
- 并发成功最终化后先调用 `unblockGeneration(type)` 恢复发送/停止按钮，再异步触发聊天保存；避免保存队列或完整性检查拖住生成 UI。普通 `N == 1` 路径仍保持原保存顺序。
- `extra.uses_system_ui && extra.display_text` 的消息渲染不再走普通 markdown / 角色正则链路，只做 DOMPurify 系统 UI 净化，避免并发候选状态卡在生成中被当成 AI 正文处理。

### 2026-05-28 最终验证记录

已完成的本地检查：

- `node --input-type=module --check < entry/src/main/resources/rawfile/public/script.js` 通过。
- `node --input-type=module --check < entry/src/main/resources/rawfile/public/scripts/openai.js` 通过。
- `hvigorw assembleHap --mode module -p module=entry@default -p product=default` 通过；仍有项目既有 ArkTS warning 和 `global.d.ts` rawfile source packaging warning。
- 通过 `hdc install -r entry/build/default/outputs/default/entry-default-signed.hap` 安装到模拟器，随后 `aa force-stop` / `aa start` 启动成功。
- `http://127.0.0.1:8000/health` 返回正常，`script.js` / `scripts/openai.js` 静态资源确认包含 `parallel_generation_count`、`disableTools: true`、`forceSingleChoice`、`saveChatAfterParallelGeneration`。

真实 API 验证环境：

- 当前测试 provider 为 `main_api = openai`，`chat_completion_source = custom`，模型 `deepseek-v4-flash`。
- 测试时强制写入 `parallel_generation_count = 2`，并保持 `oai_settings.n = 1`，避免 provider 原生 multi-choice 参与。

非流式真实 UI 验证：

- 通过本机 Chrome CDP 打开 `http://127.0.0.1:8000/`，选中 `Assistant`，发送一条普通聊天消息。
- 生成中主聊天里出现一条并发状态消息，包含两个候选按钮：`Candidate 1`、`Candidate 2`。
- 完成后临时状态消息被替换为一条 assistant 消息，swipe counter 显示 `1/2`。
- 后端 LLM 日志产生两条独立请求：ID `17` 和 `18`，时间戳分别为 `1779898186230`、`1779898186268`，间隔约 38ms，均为 `stream: false`。
- 原始外部请求体中没有 `n: 2`、没有 `tools`、没有 `tool_choice`；请求体里的 `stream` 为 `false`。

流式真实 UI 验证：

- 通过本机 Chrome CDP 打开页面并发送一条普通聊天消息，`parallel_generation_count = 2`，`stream_openai = true`。
- 生成中主聊天展示一条并发状态消息，包含两个候选按钮；候选元信息展示 first token 时间。
- 自动点击第一个候选按钮后，候选详情弹窗出现，并且详情文本长度随着 SSE token 增长，确认“点进其中一个回复查看其流式传输过程”可用。
- 完成后同一条 assistant 消息显示 swipe counter `1/2`，生成状态清空，停止按钮隐藏。
- 后端 LLM 日志产生两条独立 SSE 请求：ID `19` 和 `20`，均为 `stream: true`。
- 原始外部请求体中没有 `n: 2`、没有 `tools`、没有 `tool_choice`；请求体里的 `stream` 为 `true`。

验证结论：

- `N == 1` 未改动主路径，仍走原有单路生成逻辑。
- `N > 1` 已经是 TavernNext 应用层原生并发：同一条用户消息触发多个独立候选请求，候选成功后合并到一条 assistant 消息的 `swipes`。
- OpenAI-compatible provider 没有使用原生 `n` 并发，候选请求也禁用了工具调用，避免与工具递归和 provider multi-choice 相互叠加。

### 2026-05-28 前端入口可见性修正

用户在 OpenAI-compatible 模式下找不到并发数量滑块。原因是第一版把 `#parallel_generation_count_block` 放在了 `#common-gen-settings-block` 内，而 `changeMainAPI()` 会在 `main_api == 'openai'` 时隐藏整个 `#common-gen-settings-block`。

修正方式：

- 将并发数量滑块移动到独立的 `#parallel-generation-settings-block`。
- 新位置位于 `#common-gen-settings-block` 之后、各接口专属参数区 `#respective-ranges-and-temps` 之前。
- 这样 OpenAI-compatible、textgenerationwebui、kobold、novel 等模式都能看到同一个全局并发设置，不需要为 OpenAI 复制一份控件，也避免重复 DOM id。

### 2026-05-28 并发状态卡布局修正

用户反馈并发生成时，各个候选生成状态的进度没有正确渲染。通过本机 Chrome CDP 抓取真实生成中的 DOM，确认状态消息已经正常进入 `.mes_text`，并且 DOMPurify 会把外层 class 规范为 `custom-parallel_*`，按钮本身保留 `.parallel_candidate`。

实际问题是 CSS 级联：

- 候选按钮使用了全局 `.menu_button` 样式。
- 全局 `.menu_button` 定义在并发状态样式之后，并包含 `width: min-content`。
- 因此每个候选按钮被压成约 `21px` 宽、约 `550px` 高的细竖条，状态文字被竖向挤开，看起来像进度没有正确渲染。

修正方式：

- 在并发状态卡作用域内提高选择器优先级，覆盖 `.menu_button` 的 `width: min-content`。
- 为 `.parallel_candidates` / `.custom-parallel_candidates` 设置完整宽度和稳定网格列。
- 为候选按钮设置 `width: 100%`、`min-width: 0`、`box-sizing: border-box`、`white-space: normal`、`overflow-wrap: anywhere`、`margin: 0`。
- 验证时禁用浏览器缓存重载运行页面，模拟状态卡中两个候选按钮宽度从原来的约 `21px` 恢复为约 `338px`，布局正常。

### 2026-05-28 并发流式状态细化

用户测试发现并发流式生成时多个 candidate 都显示为生成中，但点开只有第一个候选能看到实时 token。代码分析后判断：前端会并发启动多个候选请求，后端也按 `stream_id` 管理多个流；但旧 UI 在候选请求刚发出时就把状态标成 `streaming`，没有区分“请求已发出，等待首 token”和“已经收到 token 正在流式输出”。

修正方式：

- 新增候选状态 `requesting`，`runParallelCandidate()` 发起请求时先显示为等待状态。
- `consumeParallelCandidateStream()` 只有在收到文本、reasoning 或 swipe 内容后，才把候选状态切换为 `streaming` 并记录 `timeToFirstToken`。
- 候选卡元信息显示 `Waiting for first token` / `Waiting for response`、当前字符数、首 token 延迟和错误信息。
- 候选详情弹窗在没有内容时不再空白，会显示等待首 token、等待响应、等待启动或停止前无内容等状态文本。

### 2026-05-28 字符数文案修正

真机中文环境测试时，候选详情初始状态显示 `0 角色`。原因是状态文案复用了已有 i18n key `characters`，该 key 在中文里表示“角色卡/人物”，不适合表示文本字符数。

修正方式：

- 并发候选字符数改用独立 i18n key `chars`，简体中文为“字符”，繁体中文为“字元”。
- 候选详情在等待首 token / 等待响应且尚无内容时，不再显示 `0 chars`，只显示等待状态；有内容或完成后才显示字符数。

### 2026-05-28 并发流式 UI 卡顿优化

用户反馈并发流式传输时前端页面明显卡顿。代码分析确认主要瓶颈在并发候选的流式循环：

- 每个 SSE chunk 都调用 `updateParallelGenerationMessage()`。
- 该函数原先会调用完整 `updateMessageElement()`，导致整条消息反复走 DOMPurify、消息格式化、媒体、swipe counter、按钮等完整渲染流程。
- 多个候选并发时，这个成本会按候选数和 token/chunk 数放大。
- 每个 chunk 还会对候选正文调用一次 `cleanUpMessage()`，其中包含停止词、正则等处理；并发流式时也会被放大。

修正方式：

- 新增并发状态消息节流：主聊天里的候选状态卡最多约每 `250ms` 刷新一次。
- 新增候选详情节流：只有详情弹窗打开时才刷新详情文本，最多约每 `100ms` 一次。
- 状态切换、候选完成、停止等关键节点仍使用立即刷新，避免 UI 状态滞后到看起来不对。
- 并发状态消息刷新不再调用完整 `updateMessageElement()`，只更新当前消息的 `.mes_text` 内容。
- 流式过程中候选详情使用当前 raw buffer 展示实时内容，最终完成时再执行完整 `cleanUpMessage()` 并写入正式消息 / swipes；因此最终聊天记录行为保持不变。
- session 结束时清理 pending timer，避免临时并发消息被删除或替换后仍有后台 UI 定时器继续写 DOM。

### 2026-05-29 8 并发流式连接池限制修正

用户在并发数 `8` 时观察到：候选 1-6 很快显示 first token，但部分候选字符数不增长；候选 7-8 一直等待，直到前面若干候选完成后才开始有反应。

判断根因：

- 旧实现是每个候选各自从前端 `fetch('/api/backends/chat-completions/generate')` 建立一条本地流式连接。
- WebView / 浏览器在 HTTP/1.1 下通常会限制同一 origin 的并发连接数，常见上限为 `6`。
- 因此 `8` 路并发时，第 7、8 个本地 SSE 连接会被浏览器连接池排队；这不是 provider 一定没有并发，而是前端到 TavernNext 本地后端的连接已经被占满。
- “显示 first token 但字符数不增长”的候选，可能只收到了 reasoning chunk。之前状态卡只统计正文 `text/displayText`，没有把 `reasoning` 纳入进度字符数。

修正方式：

- 后端新增 `POST /api/backends/chat-completions/generate-batch-stream`。
- OpenAI-compatible 并发流式在 `N > 1` 时不再从前端发起 `N` 条本地 SSE 连接，而是一次 POST batch：
  - 前端发送 `{ chat_completion_source, candidates: [...] }`。
  - 后端为每个 candidate 原生并发调用现有 `repository.generateStream(...)`。
  - 后端通过一条 SSE 连接向前端 multiplex：
    - `candidate-start`
    - `candidate-chunk`
    - `candidate-done`
    - `candidate-error`
    - `done`
- 每个 candidate 仍保留自己的 `stream_id`，停止生成时仍逐个调用 `cancel-stream`，同时前端也会 abort batch 总请求。
- `candidate-chunk` 不直接把上游原始 SSE chunk 当字符串塞进 JSON，而是把原始字节 base64 后放入 `chunkBase64`。前端按 candidate 用 `TextDecoder(..., { stream: true })` 解码，避免中文、emoji 等 UTF-8 多字节字符在网络分片边界被拆坏。
- batch 外层 SSE 使用原始 `EventSourceStream` 解析，不套用 smooth streaming。否则外层信封事件会被逐字符平滑延迟，多个候选并发时会重新造成 UI 卡顿或候选进度滞后。候选正文的解析仍复用现有 OpenAI 流式解析逻辑。
- 候选状态卡和详情的进度字符数统计改为正文 + reasoning，避免 reasoning 阶段看起来“有 first token 但 0 字符”。

预期结果：

- 前端到 TavernNext 本地后端只占用一条 batch SSE 连接，不再触发同源 6 连接限制。
- TavernNext 后端到 provider 仍会并发发起多个上游流式请求；实际并发度仍可能受到 provider rate limit、provider 连接限制或模型服务内部排队影响。
- `N == 1` 不走 batch stream，仍保持原有单路流式行为。

### 2026-05-29 HTTP/1.1 兼容开关

后续真机测试发现 batch stream 消除了前端本地连接池限制后，`N = 8` 仍可能表现为只有 6 个候选同时收到 token，剩余候选等待。这说明第二层限制可能在 TavernNext 后端到 provider 的上游连接上。

技术判断：

- OpenHarmony `http.requestInStream()` 如果强制 `HTTP1_1`，同一 provider host 的长连接流式请求可能仍受连接池上限影响。
- 允许系统默认协议协商时，支持 HTTP/2 的 HTTPS provider 理论上可以通过单连接多路复用承载更多并发流。
- 但之前项目曾观察到 OpenHarmony 网络栈在 HTTP/2 / 默认协商模式下偶发错误，因此不能把 HTTP/2 设为默认。

最终策略：

- 新增扩展页开关“强制 http1.1”。
- 默认启用，保持旧的稳定行为。
- 取消勾选时弹窗提醒：OpenHarmony 网络栈在允许 HTTP/2 时可能偶发 bug；该模式主要用于测试更高并发流式生成。
- 前端 chat-completions 请求携带 `force_http1_1`。
- 后端 `ChatCompletionConfigResolver` 将该字段写入 `ChatCompletionApiConfig.forceHttp1_1`。
- `ChatCompletionRepository` 按 config 选择 `RemoteHttpClient`：
  - `forceHttp1_1 == true`：继续强制 `http.HttpProtocol.HTTP1_1`。
  - `forceHttp1_1 == false`：显式设置 `usingProtocol = http.HttpProtocol.HTTP2`，用于测试更高 LLM 流式并发。

注意：

- 这个开关只影响后端到 LLM provider 的 chat-completions 请求，不影响 TavernNext 前端到本地后端的 batch SSE 连接。
- 如果 provider 或反代本身只支持 HTTP/1.1，那么取消强制 HTTP/1.1 也不一定能突破 6 路上游流式限制。
- 如果取消后出现网络栈错误，重新勾选“强制 http1.1”即可回到稳定路径。
