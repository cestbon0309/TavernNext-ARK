# 300 轮长聊天性能测试夹具

将本目录下的 `characters` 和 `chats` 复制到应用的 `<filesDir>/data/default-user/` 中。

角色卡文件基名和聊天目录均为 `Mock_Long_Chat_300`，因此聊天会绑定到该 mock 角色。

- 300 轮用户与 AI 往返，共 600 条消息
- 每条用户消息 50 个 JavaScript 字符
- 每条 AI 回复 1000 个 JavaScript 字符
- 每条 AI 消息的 `extra.reasoning` 为 1500 个 JavaScript 字符
- 完整性信息和 SHA-256 位于 `manifest.json`

重新生成：`node scripts/generate-long-chat-fixture.mjs`
