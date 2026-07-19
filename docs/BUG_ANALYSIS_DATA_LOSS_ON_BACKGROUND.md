# 后台关闭后脚本 / 正则丢失问题分析

日期：2026-05-21

## 用户反馈

用户反馈的现象集中在导入角色卡、JS-Slash-Runner / 酒馆助手脚本、角色正则配置这几块：

- 酒馆助手的脚本会丢失。
- 角色卡的正则会消失。
- 在角色聊天界面直接从后台关闭应用后，重新进入会发现这个角色的正则和脚本都没了。
- 删除旧卡后重新导入，清后台重进后出现同名纯黑头像角色卡。
- 两张卡不会重复导入世界书。
- 脚本和正则应该是分开的。

目前用户只要求分析原因，不修改代码。

## 初步结论

当前更像是两个问题叠加：

1. **脚本 / 正则丢失很可能是前端设置未及时落盘。**

   SillyTavern 前端大量设置保存是防抖保存。用户在角色聊天页导入脚本、调整角色级正则后，如果直接把应用从后台清掉，ArkWeb 进程可能来不及完成 `saveSettingsDebounced`、`saveMetadataDebounced` 或角色扩展字段保存请求，导致重启后看起来像脚本和正则丢失。

2. **角色级正则本身正常应写入角色卡扩展字段。**

   原版 SillyTavern 的角色 scoped regex 读取位置是角色对象里的 `data.extensions.regex_scripts`。前端会通过 `writeExtensionField()` 调用后端 `/api/characters/merge-attributes` 来合并保存。只要这次请求成功完成，角色级正则理论上应随角色卡数据持久化。

3. **部分“正则消失”可能不是 PNG 内数据丢了，而是全局开关 / 启用状态丢了。**

   Regex 扩展除了角色级规则本体外，还有全局启用状态、配置项、脚本列表等设置。这些通常走 `settings.json` 或扩展 metadata 的保存链路。如果全局配置没有及时保存，重启后可能表现为“正则没有了”或“没有生效”。

4. **同名纯黑头像角色卡更像是导入 fallback 行为问题。**

   ArkTS 后端当前存在一个 1x1 PNG fallback。某些 JSON / 无头像导入路径可能会用这个 fallback 写卡，表现为纯黑或异常头像。重新导入同名角色时又会走唯一命名逻辑，于是出现同名或近似同名的黑头像卡。

5. **世界书没有重复，说明导入链路不是完全重复执行。**

   用户明确说“两张卡不会重复导入世界书”，这说明至少世界书关联逻辑没有简单重复跑两遍。问题更可能集中在角色卡写入、头像 fallback、以及脚本 / 正则设置落盘时机。

## 关键代码位置

### SillyTavern 前端保存链路

- `entry/src/main/resources/rawfile/public/script.js:469`

  `saveSettingsDebounced = debounce(..., DEFAULT_SAVE_EDIT_TIMEOUT)`，设置保存是防抖保存。

- `entry/src/main/resources/rawfile/public/scripts/constants.js:14`

  `DEFAULT_SAVE_EDIT_TIMEOUT` 当前为 1000ms。

- `entry/src/main/resources/rawfile/public/scripts/extensions.js:77`

  `saveMetadataDebounced`，扩展 metadata 也是防抖保存。

- `entry/src/main/resources/rawfile/public/scripts/extensions.js:1769`

  `writeExtensionField()`，用于写角色扩展字段。

- `entry/src/main/resources/rawfile/public/scripts/extensions/regex/engine.js:114`

  角色 scoped regex 从 `characters[this_chid]?.data?.extensions?.regex_scripts` 读取。

### ArkTS 后端角色保存 / 导入

- `entry/src/main/ets/backend/SillyTavernCore.ets:696`

  `mergeCharacterAttributes`，处理 `/api/characters/merge-attributes` 一类角色属性合并保存。

- `entry/src/main/ets/backend/SillyTavernCore.ets:817`

  `importCharacter`，角色导入入口。

- `entry/src/main/ets/backend/SillyTavernCore.ets:2050`

  `importedCharacterInternalName`，导入角色时的内部命名 / 去重相关逻辑。

- `entry/src/main/ets/backend/PngCardStore.ets:16`

  `DEFAULT_PNG_BYTES`，当前 fallback PNG。

- `entry/src/main/ets/backend/PngCardStore.ets:49`

  `writeCard`，写角色卡时使用现有 PNG 或 fallback PNG。

### ArkUI / Ability 生命周期

- `entry/src/main/ets/entryability/EntryAbility.ets:64`

  `onBackground` 当前主要记录后台状态，没有主动通知 ArkWeb 立即 flush 前端设置。

### JS-Slash-Runner / 酒馆助手相关

外部插件源码位于：

- `<TavernNext 工作区>\JS-Slash-Runner`

重点位置：

- `src/store/settings/global.ts:40`

  全局酒馆助手设置保存使用 `saveSettingsDebounced`。

- `src/store/scripts.ts:19`

  全局脚本位于 `settings.script.scripts`。

- `src/store/settings/character.ts:47`

  角色级酒馆助手设置通过 `writeExtensionField` 保存到角色扩展字段。

这说明插件没有使用独立持久化机制，而是依赖 SillyTavern 原有设置和角色扩展字段保存机制。因此修复方向应优先保证 TavernNext 对原版保存链路兼容，而不是修改插件或脚本。

## 高概率原因

### 1. 后台杀进程时前端防抖保存未完成

原版 Web 环境里，用户关闭页面前通常还有浏览器生命周期事件和网络请求收尾机会。但 ArkWeb 嵌在应用里，用户直接从后台清掉应用时，Ability 进入后台到进程结束之间的时间可能很短。

如果此时前端刚刚改了：

- 酒馆助手脚本列表；
- 酒馆助手角色级配置；
- regex 全局启用状态；
- 角色 scoped regex；
- 其他扩展 metadata；

而保存仍处于防抖等待或请求未完成阶段，就会丢失最后一次修改。

### 2. 当前 `onBackground` 没有触发前端 flush

目前 `EntryAbility.onBackground` 没有向 Web 页面注入或派发“请立即保存”的动作，也没有等待关键保存请求完成。这样在后台被系统终止时，TavernNext 比桌面浏览器更容易丢最后几秒的设置。

### 3. 纯黑头像来自 fallback PNG

`PngCardStore` 里的 `DEFAULT_PNG_BYTES` 是很小的 fallback 图片。对于没有头像或 JSON 导入的角色，如果导入路径没有按原版行为补齐默认头像，而是直接写这个 fallback，就可能产生纯黑头像卡。

### 4. 重复角色卡可能来自导入唯一命名策略

重新导入同名角色时，后端会为了避免覆盖已有角色而生成新的内部名称。这个行为本身未必错误，但如果导入失败 / fallback 写卡 / 旧卡没有完全删除的状态叠加，就会出现用户看到的“同名黑头像卡”。

## 建议修复方向

后续如果开始修复，建议按以下顺序：

1. **先补应用后台 / 销毁前的前端保存 flush。**

   在 Ability `onBackground`、页面隐藏、ArkWeb 退出前，主动通知前端立即执行非防抖保存。目标是尽量调用原版已有保存函数，而不是改插件。

2. **覆盖几类关键保存对象。**

   至少要覆盖：

   - `saveSettings()`；
   - `saveMetadata()`；
   - 当前角色扩展字段保存；
   - 可能存在的扩展注册 flush hook。

3. **检查角色 scoped regex 保存是否确实等待 `/api/characters/merge-attributes` 完成。**

   如果前端函数是异步的，需要保证后台前 flush 能等待 Promise 或至少尽快发起请求。

4. **替换角色卡 fallback 头像逻辑。**

   对 JSON / 无头像角色导入，应尽量对齐原版 SillyTavern 行为，使用原版默认头像或生成兼容 PNG，而不是写 1x1 fallback。

5. **复测 JS-Slash-Runner，不修改插件和脚本。**

   验证路径应以兼容原版为目标：

   - 导入脚本后立刻后台杀应用；
   - 添加角色正则后立刻后台杀应用；
   - 导入无头像 / JSON 角色；
   - 删除旧卡后重导入；
   - 确认世界书不重复；
   - 确认脚本、正则、角色扩展字段都保留。

## 暂不建议的方向

- 不建议修改 JS-Slash-Runner 或用户脚本来适配 TavernNext。
- 不建议只延长防抖时间或简单取消防抖，这可能影响原版行为和性能。
- 不建议只修黑头像，因为脚本 / 正则丢失是另一个独立的生命周期持久化问题。

## 当前状态

2026-05-21：此文档只记录分析结果，没有修改实现代码。

## 2026-05-22 重新分析与修复记录

重新分析后发现，脚本 / 正则丢失不只是“后台杀进程时防抖保存没来得及落盘”这一种可能，还存在一条更直接的兼容性缺口：

### 新发现的可能原因

1. **JS-Slash-Runner / 酒馆助手并不完全使用原版 `writeExtensionField()`。**

   酒馆助手源码里有自己的兼容保存函数：

   - `<TavernNext 工作区>\JS-Slash-Runner\src\util\tavern.ts`

   它保存角色级脚本 / 角色级配置时，会调用：

   - `POST /api/characters/edit`

   并在 multipart/form-data 里提交一个完整的 `extensions` JSON 字段。

2. **原版 SillyTavern 的 `/api/characters/edit` 会深合并这个 `extensions` 字段。**

   原版位置：

   - `<TavernNext 工作区>\SillyTavern\src\endpoints\characters.js`

   原版逻辑会先构造标准 `data.extensions`，再把请求里的 `data.extensions` JSON 深合并进去。这样第三方插件写入的字段，例如 `TavernHelper`、`regex_scripts` 等，不会被角色编辑保存覆盖。

3. **TavernNext ArkTS 后端之前缺少这段兼容逻辑。**

   之前 `SillyTavernCore.buildCharacterCard()` 只写入了：

   - `talkativeness`
   - `fav`
   - `world`
   - `depth_prompt`

   如果插件通过 `/api/characters/edit` 提交完整 `extensions`，后端会忽略这整块，最终写卡时就可能把酒馆助手脚本、角色级配置、角色正则等扩展字段覆盖丢失。

4. **后台关闭仍然是另一个风险点。**

   即使后端兼容补齐了，用户在修改全局脚本、全局正则启用状态、角色脚本、角色正则后马上把应用从后台清掉，前端的防抖保存或异步请求仍可能没跑完。所以仍然需要后台前主动 flush。

### 本次修复内容

已修改：

- `entry/src/main/resources/rawfile/public/script.js`
- `entry/src/main/ets/backend/ApplicationStateService.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/backend/SillyTavernCore.ets`

修复点：

1. **前端新增 TavernNext 持久化 flush。**

   新增 `window.__tavernNextFlushPersistentState()`，用于立即执行：

   - 取消并替代待执行的 `saveSettingsDebounced()`
   - 取消并替代待执行的 `saveMetadataDebounced()`
   - 立即调用 `saveSettings()`
   - 立即调用 `saveMetadata()`
   - 将当前角色内存里的 `data.extensions` 整体通过 `/api/characters/merge-attributes` 再落盘一次

2. **前端监听页面生命周期。**

   在 `visibilitychange`、`pagehide`、`beforeunload`、`freeze` 时触发持久化 flush，覆盖 ArkWeb 页面隐藏 / 卸载前的常见路径。

3. **ArkUI 壳层在应用进入后台时主动触发 Web flush。**

   `ApplicationStateService` 新增前后台状态订阅，`Index.ets` 在应用切后台或页面消失时通过 `WebviewController.runJavaScript()` 调用 `window.__tavernNextFlushPersistentState()`。

4. **后端补齐 `/api/characters/edit` 对 `extensions` 的原版兼容。**

   `SillyTavernCore.buildCharacterCard()` 现在会解析请求里的 `extensions` JSON，并与现有 `data.extensions` 深合并，避免插件字段被编辑保存覆盖。

### 验证结果

已执行命令行构建：

```powershell
$env:DEVECO_SDK_HOME='<DevEco SDK 路径>'
& '<DevEco Studio 路径>\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p module=entry@default -p product=default
```

结果：

- `BUILD SUCCESSFUL`
- 只有既有 ArkTS warning，没有新增编译错误。

### 后续仍需人工复测

需要在模拟器或真机上复测：

- 酒馆助手导入脚本后，立刻切后台并清掉应用，重开后脚本是否保留。
- 添加角色级酒馆助手脚本后，立刻切后台并清掉应用，重开后脚本是否保留。
- 添加角色 scoped regex 后，立刻切后台并清掉应用，重开后正则是否保留。
- 切换角色、编辑角色、重新进入聊天后，`data.extensions` 里的插件字段是否仍保留。

本次修复没有修改 JS-Slash-Runner 插件源码，也没有修改用户脚本。
