# 并发多回复生成方案记录

> 目标：在预设页面配置一次发送要生成多少个回复，并在用户按发送后并行生成多个候选回复。本文只记录可行性、现有链路、风险和后续实施方案；当前阶段不修改功能代码。

## 当前结论

可行，但不是单纯“多发几次 API”这么简单。SillyTavern 前端的生成流程大量依赖单次生成状态，例如 `is_send_press`、全局 `abortController`、全局 `streamingProcessor`、消息占位、自动继续、工具调用、自动 swipe、聊天保存、事件通知等。要保持原版行为一致，需要在现有单次生成状态机外面加一个很薄的“并发候选调度层”，而不是把 `Generate()` 整体直接跑 N 次。

用户最新确认的交互目标：
- 当 `n = 1` 时，保持现在的单条回复生成行为。
- 当 `n > 1` 时，点击发送按钮后，聊天区不要直接显示某条具体回复内容。
- 聊天区先显示一个“并发候选状态面板”，里面有 N 个候选条目。
- 每个候选条目展示状态：生成中 / 已完成 / 失败 / 已取消。
- 用户点击某个候选条目后，展开该候选，看到的应是“常规的一条消息的生成/显示效果”。
- 展开某个候选时，应尽量复用原本单条助手消息的渲染、Markdown、reasoning、媒体、代码块、复制、编辑、swipe 等行为。

最推荐的数据模型：把多个生成结果保存为同一条助手消息的 `swipes`，而不是追加 N 条助手消息。但并发默认态不直接显示 `swipes[0]`，而是显示候选状态面板；用户选择候选后，再把对应候选作为当前 `swipe_id` 展开显示。

原因：
- `swipes` 是 SillyTavern 已有的“同一轮回复的多个候选版本”结构。
- 如果写成 N 条助手消息，后续上下文会错误地把所有候选回复都当成真实聊天历史。
- 现有 UI 已经能显示 swipe 左右切换、计数、删除和保存。
- 非流式返回里已经有 `extractMultiSwipes()`，会把 OpenAI/兼容接口的多个 `choices` 转成额外 swipes。

新增交互下的关键补充：
- 需要一个“并发候选组消息”的前端展示状态。
- 它最好仍然挂在一条普通助手消息对象上，例如 `message.extra.parallel_generation`。
- 面板态只是一种渲染模式，不应改变聊天历史语义。
- 用户展开候选后，当前消息切到对应 `swipe_id`，并正常渲染该 swipe 文本。

## 已发现的原版/现有能力

### 1. 预设页已有 `n` 设置

文件：
- `entry/src/main/resources/rawfile/public/index.html`
- `entry/src/main/resources/rawfile/public/scripts/openai.js`

现有 UI 已有 `Multiple swipes per generation`，对应输入框 `#n_openai`。

`openai.js` 里：
- `default_settings.n = 1`
- `settingsToUpdate.n = ['#n_openai', 'n', false, false]`
- `#n_openai` 输入时写入 `oai_settings.n` 并 `saveSettingsDebounced()`
- `getChatCompletionPreset()` 会把 `n` 存入 OpenAI/chat-completion 预设

这说明“预设里保存候选回复数量”已有一部分基础。

### 2. 现有 `n` 不是并发请求

`createGenerationParameters()` 里已经有“单请求多候选”的逻辑：

- `multiswipeSources = [OPENAI, AZURE_OPENAI, CUSTOM, XAI, AIMLAPI, MOONSHOT]`
- 仅在 `settings.n > 1`、类型不是 `quiet/impersonate/continue`、且 provider 支持时，把 `n` 写进请求体。
- 如果 `canMultiSwipe` 为 true，会禁用工具调用注册：`if (!canMultiSwipe && ToolManager.canPerformToolCalls(...)) registerFunctionToolsOpenAI(...)`

这代表现有行为是：一个请求交给 provider，让 provider 返回多个 `choices`。它不等价于“前端并发发起 N 个生成请求”。

### 3. 现有多候选保存路径

文件：
- `entry/src/main/resources/rawfile/public/script.js`

关键函数：
- `Generate()`：主生成入口。
- `sendGenerationRequest()`：非流式请求。
- `sendStreamingRequest()`：流式请求。
- `extractMultiSwipes()`：从响应的多个候选里抽取额外 swipes。
- `saveReply()`：保存助手消息，并把额外 `swipes` 追加进当前消息。
- `ensureSwipes()`、`syncMesToSwipe()`、`loadFromSwipeId()`、`swipe()`：维护 swipe 结构和 UI。

非流式路径：
1. `Generate()` 构造 prompt。
2. `finishGenerating()` 调 `sendGenerationRequest()`。
3. `onSuccess()` 调 `extractMessageFromData()` 得到主回复。
4. `extractMultiSwipes()` 从 `data.choices[1...]` 得到额外回复。
5. `saveReply({ getMessage, swipes })` 创建一条助手消息，并把其他候选加入 `message.swipes`。

流式路径：
- `StreamingProcessor` 当前主要面向一个可见回复流。
- 如果 `canMultiSwipe` 且流式 chunk 里有 `choices[index > 0]`，也会把其他 index 的内容累积到 `this.swipes`。
- 但 `state.reasoning`、图片、工具调用等仍然明显偏向“主回复”模型，代码里已有 FIXME：`state.reasoning should be an array to support multi-swipe`。

### 4. 后端基本支持并发生成

文件：
- `entry/src/main/ets/backend/model/ChatCompletionService.ets`
- `entry/src/main/ets/backend/model/http/ChatCompletionRepository.ets`
- `entry/src/main/ets/backend/RemoteHttpClient.ets`
- `entry/src/main/ets/backend/LlmBackgroundTaskService.ets`

后端现状：
- `/api/backends/chat-completions/generate` 同时支持流式和非流式。
- 流式请求可通过 `stream_id` 注册到 `activeStreams`。
- 非流式请求可通过 `request_id` 注册到 `activeGenerations`。
- 取消接口：
  - `/api/backends/chat-completions/cancel-stream`
  - `/api/backends/chat-completions/cancel-generation`
- `RemoteHttpClient` 每个请求创建独立 HarmonyOS HTTP request，取消时调用 `request.destroy()`。
- `LlmBackgroundTaskService` 是引用计数式：
  - 每个生成 `beginResponse()`
  - 每个结束 `finishResponse()`
  - 多个并发生成时 `activeCount` 累加，全部结束后才停止 DATA_TRANSFER 长时任务。

因此后端本身没有明显的“只能同时一个 LLM 请求”的硬限制。真正复杂的是前端如何组织多个候选、取消多个请求、保存一个最终聊天消息。

## 最新交互方案：候选状态面板

### 目标形态

`n > 1` 时，用户按发送后，聊天区最后出现一条助手侧消息，但这条消息默认不是具体回复文本，而是候选状态面板：

```text
并发生成 4 个回复

[1] 生成中
[2] 生成中
[3] 已完成
[4] 失败
```

点击 `[3] 已完成`：
- 当前面板展开为候选 3 的完整消息内容。
- 展开后的显示应走常规消息渲染：Markdown、代码块、reasoning、附件、计时、token 统计等尽量一致。
- 可以提供“返回候选列表”或在消息上保留候选切换入口。

点击 `[1] 生成中`：
- 第一阶段可以只显示“生成中”，等完成后自动渲染完整内容。
- 如果后续要做到“点击进去就是常规的一条消息的生成”，则需要给每个候选维护独立流式状态，并在展开时把该候选的流式 chunk 投递到当前消息 DOM。

### 数据结构建议

仍使用一条助手消息承载候选组：

```js
message = {
  name: name2,
  is_user: false,
  mes: '',
  swipe_id: 0,
  swipes: ['', '', '', ''],
  swipe_info: [],
  extra: {
    parallel_generation: {
      enabled: true,
      group_id: 'parallel-...',
      count: 4,
      display_mode: 'panel', // panel | candidate
      active_candidate: null,
      candidates: [
        { index: 0, status: 'generating', request_id: '...', stream_id: '', error: '' },
        { index: 1, status: 'completed', request_id: '...', stream_id: '', error: '' }
      ]
    }
  }
}
```

面板态：
- `extra.parallel_generation.display_mode = 'panel'`
- `.mes_text` 渲染候选状态 UI，不渲染具体回复。
- 不把候选 UI 文本作为 prompt 内容。

候选展开态：
- `display_mode = 'candidate'`
- `active_candidate = index`
- `swipe_id = index`
- `mes = swipes[index]`
- 调 `updateMessageElement()` 或类似路径重新渲染这一条消息。

### 为什么仍建议落到 swipes

这个交互看起来像 N 条消息，但语义上仍然是“同一轮回复的 N 个候选”。后续上下文只能选择一个候选进入历史，否则会把未选择候选也喂给模型。

使用 swipes 的好处：
- SillyTavern 本来就通过 `swipe_id` 决定当前消息内容。
- 保存 JSONL 时能保留所有候选，但当前 `mes` 代表活跃候选。
- 现有编辑、删除 swipe、切换 swipe、重新生成候选等功能可以复用或小改。
- 插件和正则更容易看到原版接近的数据结构。

### 面板 UI 的实现方式

建议不要把面板作为系统消息，也不要写入多条临时消息。更稳的方式：
- 在 `updateMessageElement()` 或 `getMessageTextHTML()` 前增加判断：
  - 如果 `message.extra.parallel_generation?.enabled` 且 `display_mode === 'panel'`，返回候选面板 HTML。
  - 面板 HTML 使用安全的 DOM 构造或严格转义，避免直接拼用户文本。
- 面板 DOM 的按钮通过事件委托绑定，例如 `.parallel-candidate-open`。
- 点击候选后，更新消息对象状态并重渲染这一条消息。

可利用现有 `extra.uses_system_ui` 机制，但要谨慎：
- 它允许部分系统 UI HTML 通过 sanitizer。
- 面板最好不要依赖未清理的 HTML 字符串。
- 推荐新增专用渲染函数，手工创建 DOM 或生成固定模板。

### 展开候选后的“常规消息生成”

有两层含义：

1. 已完成候选：
   - 直接显示候选完整内容。
   - 调用常规 `messageFormatting()`、`updateReasoningUI()`、`appendMediaToMessage()`、`addCopyToCodeBlocks()`。

2. 生成中候选：
   - 第一阶段可以只展示候选状态，不展开流式内容。
   - 如果要做到“点进去就是常规的一条消息的生成”，则需要支持每个候选有独立流式状态，并且在某个候选被展开时，把该候选的流式 chunk 投递到当前消息 DOM。

推荐阶段化：
- 阶段 2 MVP：并发时默认面板，候选完成后可展开；生成中候选点开仍显示生成中。
- 阶段 3：支持展开正在生成中的候选并实时流式显示。

## 推荐方案

下面的推荐方案已按最新“候选状态面板”需求更新。早先“直接生成完成后合并 swipes”的思路只保留为背景，不作为首选实现。

### 方案 A：并发候选状态面板 + 最终 swipes 存储

这是按最新需求调整后的推荐方案。

行为：
- `n = 1` 保持现有行为。
- `n > 1` 时创建一条候选组助手消息。
- 立即渲染 N 个候选状态，不直接显示具体回复。
- 前端并行发起 N 个独立候选请求。
- 每个候选完成后更新状态，并把文本写入对应 `swipes[index]`。
- 用户点击候选后，将该候选作为当前 `swipe_id` 展开为常规消息。

优点：
- 满足用户明确需求。
- 不污染上下文。
- UI 上能清楚看到每个候选的生成进度。
- 最终数据结构仍贴近 SillyTavern 的候选回复模型。

缺点：
- 比单纯 `n` 多候选复杂。
- 需要新增候选面板渲染、点击展开、状态刷新、取消和失败处理。
- 如果要求“生成中候选展开后实时流式”，还需要多路流式状态管理。

### 方案 B：继续复用 provider 原生 `n`

行为：
- 支持原生 `n` 的 provider 只发一个请求，返回多个 choices。
- 前端仍渲染候选面板，choices 到达后标记多个候选完成。

优点：
- 请求少，成本和限速压力更低。

缺点：
- 不是真正“并发 N 个请求”。
- 流式下多个 choices 的状态粒度不一定稳定。
- 与用户“并发生成多个回复”的直觉可能不完全一致。

### 推荐落地方式

按最新需求，推荐优先实现真正并发候选状态面板：

1. 保持 `n = 1` 时完全走现有逻辑，确保原版行为不变。
2. `n > 1` 时，不再把 `n` 交给 provider 做单请求多 choices，而是创建候选组并行发起 N 个候选请求。
3. 每个候选独立状态，完成后写入同一条消息的 swipes。
4. 第一阶段可以先不展开生成中的流式内容，只允许完成后展开。
5. 第二阶段再支持“点击生成中候选后实时展开流式生成”。

是否继续保留 provider 原生 `n`：
- 可以作为后续优化，但第一版建议统一走并发请求，行为最符合需求。
- 为避免 provider 内部 `n` 与前端并发 `n` 叠加，候选子请求必须把请求体里的 `n` 固定为 `1`。

## 前端实施设计

### 1. 不要直接并行调用 `Generate()` N 次

原因：
- `Generate()` 会读取并清空输入框。
- `Generate()` 会创建用户消息。
- `Generate()` 会增删最后一条消息。
- `Generate()` 会设置全局 `is_send_press`。
- `Generate()` 会使用全局 `abortController`。
- 流式时会使用全局 `streamingProcessor`。
- 自动继续、工具调用、自动 swipe 都默认只面向一个主回复。

直接跑 N 次会导致：
- 用户消息可能重复写入。
- 多个助手消息竞争最后一条消息。
- 停止按钮只停掉其中一个或行为不可控。
- 后续上下文污染。

### 2. 需要拆出“prompt snapshot”和“候选请求”

建议抽象：

- `buildGenerationSnapshot(type, options)`：
  - 执行现有 prompt 构建。
  - 只产生稳定的 `generate_data`、prompt metadata、当前消息 ID、上下文副本。
  - 只创建一次用户消息。

- `runSingleCandidate(snapshot, index, options)`：
  - 用同一份 `generate_data` 发起一次请求。
  - 每个候选生成独立 `request_id` / `stream_id`。
  - 返回标准结构：`text`、`reasoning`、`imageUrls`、`title`、`logprobs`、`error`。

- `mergeCandidatesIntoSwipes(primary, candidates)`：
  - 第一条候选作为 `message.mes` 和 `swipes[0]`。
  - 其他候选追加到 `message.swipes[1...]`。
  - 每个候选补齐 `swipe_info`。
  - 调用现有 `parseReasoningInSwipes()` 保持思维/推理内容处理一致。

### 3. 流式策略

这是最大的不确定点。

可选策略：

#### MVP 推荐：`n > 1` 时状态面板 + 非流式候选

行为：
- 并发请求全部使用非流式。
- 用户看到 N 个候选状态。
- 每个候选完成后，状态从“生成中”变成“已完成”。
- 用户点击已完成候选后展开常规消息。

优点：
- 最容易保证聊天数据正确。
- 不需要多个可见 stream DOM。
- 避免 `StreamingProcessor` 的全局状态冲突。

缺点：
- 用户不能实时看到 token 流。

#### 阶段 3：点击某个生成中候选后流式展开该候选

行为：
- 所有候选请求可以流式进行，但默认只更新状态面板。
- 如果用户点击某个生成中的候选，则把该候选的当前缓冲内容以常规消息形式展示，并继续实时追加 token。
- 用户切换到另一个候选时，当前消息 DOM 改为另一个候选的缓冲内容。

优点：
- 符合“点击进去就是常规的一条消息的生成”。

缺点：
- 需要拆掉 `StreamingProcessor` 对单一全局 DOM 的假设。
- 需要每个候选独立保存 text/reasoning/images/logprobs/toolCalls/state。
- 停止、失败、保存时机更复杂。

#### 完整版：候选面板中预览所有流式摘要

行为：
- 面板中的每个候选可显示少量实时预览或进度。

不建议第一阶段做。原因是容易泄露具体回复内容，而用户明确说默认“不显示具体的消息”。

## 后端实施设计

后端可能不需要新增核心接口，但为了并发取消和日志可读，建议补充：

- 每个候选请求都写入唯一 `request_id` 或 `stream_id`，例如：
  - `parallel-<groupId>-0`
  - `parallel-<groupId>-1`
- 前端保存 `groupId -> child ids`，停止时逐个调用取消接口。
- LLM API logs 可追加 `parallel_group_id` / `candidate_index` 字段，方便调试。

后端已有引用计数长时任务，理论上能覆盖多个并发请求。

## 与工具调用的关系

当前 `createGenerationParameters()` 在 `canMultiSwipe` 时会跳过工具调用：

```js
if (!canMultiSwipe && ToolManager.canPerformToolCalls(type, settings, model)) {
    await ToolManager.registerFunctionToolsOpenAI(generate_data);
}
```

并发多回复也建议第一阶段同样限制：当候选数量大于 1 时禁用工具调用，或者直接回退到单回复。原因：
- 多个候选都可能产生 tool calls。
- 每个候选调用工具会改变世界状态，无法保证“候选回复”语义。
- 原版对多候选也已经避免工具调用。

建议行为：
- `parallel_reply_count > 1` 时，不启用工具调用。
- UI 或日志提示“多候选生成不执行工具调用”。
- `count = 1` 保持原行为。

## 与 auto-swipe / auto-continue 的关系

### auto-swipe

原逻辑：
- 单个回复如果被过滤器判定不合格，可能自动 swipe 生成新候选。

并发多回复建议：
- 第一阶段只对主候选做原有 auto-swipe，或在 `count > 1` 时禁用 auto-swipe。
- 更稳妥：`count > 1` 时禁用 auto-swipe，因为用户本来已经要求多个候选。

### auto-continue

原逻辑：
- 单个回复长度不足时可能自动 continue。

并发多回复建议：
- 第一阶段 `count > 1` 禁用 auto-continue。
- 否则每个候选都 continue 会产生 N 组后续请求，成本和状态复杂度暴涨。

## 与 TGbreak 预设/思维格式的关系

之前分析的 `TGbreak😺V3.0.8.json` 会通过正则和提示词把思维内容整理为类似：

```text
<!-- 梳理：
...
-->
```

如果多个候选都保存为 swipes，则每个候选文本都会独立经过现有 `cleanUpMessage()`、`getRegexedString()`、`parseReasoningInSwipes()` 等路径，理论上与原版候选回复展示一致。

需要注意：
- 如果 provider 返回结构化 reasoning 字段，当前 swipe reasoning 主要依赖 `parseReasoningInSwipes()`。
- 多路流式 reasoning 当前不是完善结构，第一阶段不建议做全多路流式。

## 需要修改的主要文件

预计会涉及：

- `entry/src/main/resources/rawfile/public/index.html`
  - 可能调整 `Multiple swipes per generation` 的说明，或新增“并发 fallback/生成方式”选项。

- `entry/src/main/resources/rawfile/public/scripts/openai.js`
  - 现有 `n` 配置和 provider `canMultiSwipe` 逻辑在这里。
  - 需要导出或补充判断函数：当前 provider 是否支持原生 `n`。
  - 可能需要给并发请求生成 `request_id` / `stream_id`。

- `entry/src/main/resources/rawfile/public/script.js`
  - 主改造点。
  - 需要避免直接并行跑 `Generate()`。
  - 需要在 `finishGenerating()` 或附近插入并发候选调度。
  - 需要统一停止按钮取消所有候选。
  - 需要新增候选组消息渲染和点击展开逻辑。
  - 需要把每个候选结果写入对应 `swipes[index]`，展开时设置 `swipe_id`。

- `entry/src/main/resources/rawfile/public/style.css`
  - 新增候选状态面板样式。
  - 需要兼容移动端窄屏，不让候选状态文字挤压错位。

- `entry/src/main/ets/backend/model/ChatCompletionService.ets`
  - 可能无需核心修改。
  - 如果要增强日志/取消分组，可能补 `parallel_group_id` 透传或记录。

- `entry/src/main/ets/backend/model/LlmApiLogger.ets`
  - 可选：记录并发组和候选序号。

## 风险清单

- 全局状态冲突：`abortController`、`streamingProcessor`、`is_send_press` 当前都是单生成模型。
- 聊天历史污染：不能把候选回复写成多条助手消息。
- 停止按钮：必须能取消所有并发候选。
- 保存时机：所有候选合并后只保存一次，避免中途保存半成品。
- 面板态持久化：如果 app 在生成中被清后台，重新打开时应能显示已保存的候选结果；未完成候选应标记为已中断或失败，不能永远“生成中”。
- 候选展开语义：展开候选后，后续 prompt 应只使用当前 `swipe_id` 对应文本。
- 失败处理：部分候选失败时，至少保留成功候选；全部失败时恢复 UI 并提示错误。
- Provider 限速：并发请求比原生 `n` 更容易触发 429。
- 成本增加：N 个请求等于 N 倍输入 token 成本。
- 工具调用：多候选下应禁用或回退单候选。
- 自动继续/自动 swipe：多候选下建议第一阶段禁用。
- 流式多路显示：完整实现工作量大，第一阶段不建议做。
- 移动端后台：后端长时任务引用计数已适配并发，但通知应避免每个候选都发一次。

## 初步工作量评估

如果目标是“候选状态面板最小可用且不破坏原行为”：
- UI/设置：小。
- 候选状态面板 UI：中。
- 非流式并发候选：中。
- 取消所有候选：中。
- swipes 写入、展开与保存：中到偏大。
- 与工具调用、auto-continue、auto-swipe 的兼容处理：中。
- 展开生成中候选并实时流式：大，不建议第一阶段。

第一阶段建议工作量：约 2 个较完整开发回合。

完整行为等价，包括点击生成中候选后实时流式、每个候选 reasoning/logprobs/images/tool-call 细粒度一致、日志分组、部分失败 UI、移动端后台通知去重：工作量会明显变大。

## 建议实施阶段

### 阶段 1：文档和行为确认

状态：进行中。

输出：
- 确认现有 `n` 和 `swipes` 机制。
- 确认后端并发生成和长时任务能力。
- 确认最新 UI：并发时默认显示候选状态面板，不直接显示具体消息。
- 确认第一阶段是否接受“候选完成后才能展开完整消息”，生成中候选暂不实时展开。

### 阶段 2：最小可用候选状态面板

目标：
- `n = 1` 完全不变。
- `n > 1` 时创建候选组助手消息。
- 面板显示 N 个候选状态。
- 并发发起 N 个非流式请求，每个请求强制 `n = 1`。
- 每个成功结果写入同一条消息的 `swipes[index]`。
- 点击已完成候选，展开为常规消息显示。
- 停止按钮取消所有候选。

限制：
- 多候选时禁用工具调用。
- 多候选时禁用 auto-continue。
- 生成中候选第一阶段不实时展开流式内容。

### 阶段 3：体验增强

目标：
- 点击生成中的候选时，可以展开并实时显示该候选的流式生成。
- 失败候选可见提示。
- LLM API logs 按并发组展示。
- 后台通知只在整个并发组完成后发一次。

### 阶段 4：完整多路流式（可选）

目标：
- 多候选都能保持独立流式缓冲。
- UI 可切换正在生成中的候选并看到对应实时内容。
- 每个候选独立 reasoning/logprobs/images。

当前不建议优先做。

## 进度记录

- 2026-05-25：开始分析并发多回复功能。确认用户要求先规划和记录，不修改功能代码。
- 2026-05-25：确认 `script.js` 中 `Generate()` 是主入口，`sendTextareaMessage()` 是发送按钮入口，`saveReply()` 已支持额外 `swipes`。
- 2026-05-25：确认 `openai.js` 中已有 `oai_settings.n` 和 `#n_openai` 预设设置，用于原生多候选 `choices`。
- 2026-05-25：确认现有 `n` 是 provider 单请求多候选，不是前端并发 N 个请求。
- 2026-05-25：确认 ArkTS 后端 `ChatCompletionService` 支持多个 `request_id` / `stream_id` 并发注册与取消。
- 2026-05-25：确认 `LlmBackgroundTaskService` 是引用计数模型，多个并发生成会共用 DATA_TRANSFER 长时任务，全部结束后才注销。
- 2026-05-25：形成初步建议：优先复用原生 `n`，不支持原生 `n` 的 provider 再使用并发 fallback；结果统一保存为 swipes。
- 2026-05-25：用户进一步明确需求：`n > 1` 时发送后默认不显示具体回复，只显示 N 个候选的生成状态；点击候选后展开为常规单条消息生成/显示。方案调整为“候选状态面板 + swipes 存储”，第一阶段建议并发非流式候选，完成后可展开。
