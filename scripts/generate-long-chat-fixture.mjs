import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIR, '..');
const OUTPUT_ROOT = path.resolve(
  REPOSITORY_ROOT,
  process.argv[2] ?? 'test-data/long-chat-300',
);

const CHARACTER_FILE_NAME = 'Mock_Long_Chat_300.png';
const CHARACTER_ID = path.parse(CHARACTER_FILE_NAME).name;
const CHAT_FILE_NAME = 'Mock_Long_Chat_300_300_rounds.jsonl';
const USER_NAME = '性能测试用户';
const CHARACTER_NAME = '长对话性能测试助手';
const ROUND_COUNT = 300;
const USER_MESSAGE_LENGTH = 50;
const ASSISTANT_MESSAGE_LENGTH = 1000;
const REASONING_LENGTH = 1500;

const PNG_SIGNATURE = Buffer.from('89504e470d0a1a0a', 'hex');
const BASE_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);

function fixedLength(prefix, seed, targetLength) {
  let value = prefix;
  while (value.length < targetLength) {
    value += seed;
  }
  return value.slice(0, targetLength);
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function createPngChunk(type, data) {
  const typeBuffer = Buffer.from(type, 'ascii');
  const lengthBuffer = Buffer.alloc(4);
  lengthBuffer.writeUInt32BE(data.length);
  const crcBuffer = Buffer.alloc(4);
  crcBuffer.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])));
  return Buffer.concat([lengthBuffer, typeBuffer, data, crcBuffer]);
}

function insertChunkBeforeIend(png, chunk) {
  if (!png.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error('基础图片不是有效 PNG');
  }

  let offset = PNG_SIGNATURE.length;
  while (offset < png.length) {
    const dataLength = png.readUInt32BE(offset);
    const type = png.subarray(offset + 4, offset + 8).toString('ascii');
    if (type === 'IEND') {
      return Buffer.concat([png.subarray(0, offset), chunk, png.subarray(offset)]);
    }
    offset += 12 + dataLength;
  }
  throw new Error('基础图片缺少 IEND 块');
}

function createCharacterCard() {
  const data = {
    name: CHARACTER_NAME,
    description: '用于验证超长聊天加载、滚动、搜索、保存和恢复性能的模拟角色。',
    personality: '稳定、耐心、条理清晰，始终输出可重复的性能测试文本。',
    scenario: '用户正在进行 300 轮超长聊天压力测试。',
    first_mes: '性能测试角色已就绪，可以开始长对话测试。',
    mes_example: '<START>\n{{user}}: 请生成一段测试回复。\n{{char}}: 这是用于性能测试的模拟回复。',
    creator_notes: 'TavernNext 300 轮长聊天测试夹具。',
    system_prompt: '你是一个仅用于本地性能测试的模拟助手。',
    post_history_instructions: '',
    alternate_greetings: [],
    character_book: undefined,
    tags: ['mock', 'performance', 'long-chat'],
    creator: 'TavernNext',
    character_version: '1.0.0',
    extensions: {},
  };
  const card = {
    spec: 'chara_card_v2',
    spec_version: '2.0',
    name: data.name,
    description: data.description,
    personality: data.personality,
    scenario: data.scenario,
    first_mes: data.first_mes,
    mes_example: data.mes_example,
    data,
  };
  const encodedCard = Buffer.from(JSON.stringify(card), 'utf8').toString('base64');
  const textData = Buffer.from(`chara\0${encodedCard}`, 'latin1');
  return insertChunkBeforeIend(BASE_PNG, createPngChunk('tEXt', textData));
}

function createChatLines() {
  const lines = [
    JSON.stringify({
      user_name: USER_NAME,
      character_name: CHARACTER_NAME,
      create_date: '2026-07-16T00:00:00.000Z',
      chat_metadata: {
        fixture: 'long-chat-300',
        character_id: CHARACTER_ID,
        expected_rounds: ROUND_COUNT,
        expected_user_message_length: USER_MESSAGE_LENGTH,
        expected_assistant_message_length: ASSISTANT_MESSAGE_LENGTH,
        expected_reasoning_length: REASONING_LENGTH,
      },
    }),
  ];

  const userSeeds = [
    '请围绕当前主题继续展开，保持上下文连贯，并覆盖关键条件与边界情况。',
    '请根据前文继续分析，用稳定格式补充细节，方便验证长聊天加载性能。',
    '这一轮用于压力测试，请延续既有语境，并给出结构清楚的完整回应。',
  ];
  const assistantSeeds = [
    '本段是长对话性能测试回复。内容保持连续、稳定且容易检索，用于观察聊天记录加载、渲染、滚动、编辑、搜索与持久化时的表现。',
    '为了覆盖较长文本场景，这里持续补充可重复的说明性文字，同时维持自然段落语义，避免依赖外部知识或网络状态。',
    '测试重点包括消息列表响应速度、内存占用、历史记录恢复、页面切换以及重新进入聊天后的内容一致性。',
  ];
  const reasoningSeeds = [
    '这是显式存储在消息字段中的模拟思考文本，不代表真实模型内部推理。它只用于测试推理区域的折叠、展开、滚动、搜索、保存和恢复。',
    '本轮按照固定长度构造内容，检查超长推理与正文同时存在时的界面响应、数据解析、序列化速度和内存稳定性。',
    '所有文字均为确定性测试数据，可重复生成并通过字符长度、消息数量和文件哈希进行校验。',
  ];

  for (let round = 1; round <= ROUND_COUNT; round += 1) {
    const roundLabel = String(round).padStart(3, '0');
    const userTimestamp = new Date(Date.UTC(2026, 6, 16, 0, round - 1, 0));
    const assistantTimestamp = new Date(userTimestamp.getTime() + 30_000);
    const userMessage = fixedLength(
      `第${roundLabel}轮：`,
      userSeeds[(round - 1) % userSeeds.length],
      USER_MESSAGE_LENGTH,
    );
    const assistantMessage = fixedLength(
      `第${roundLabel}轮回复：`,
      assistantSeeds[(round - 1) % assistantSeeds.length],
      ASSISTANT_MESSAGE_LENGTH,
    );
    const reasoning = fixedLength(
      `第${roundLabel}轮模拟思考：`,
      reasoningSeeds[(round - 1) % reasoningSeeds.length],
      REASONING_LENGTH,
    );

    lines.push(JSON.stringify({
      name: USER_NAME,
      is_user: true,
      is_system: false,
      send_date: userTimestamp.toISOString(),
      mes: userMessage,
      extra: {},
    }));
    lines.push(JSON.stringify({
      name: CHARACTER_NAME,
      is_user: false,
      is_system: false,
      send_date: assistantTimestamp.toISOString(),
      mes: assistantMessage,
      extra: {
        api: 'mock',
        model: 'tavernnext-performance-fixture',
        reasoning,
        reasoning_duration: 15,
      },
      gen_started: new Date(assistantTimestamp.getTime() - 15_000).toISOString(),
      gen_finished: assistantTimestamp.toISOString(),
    }));
  }

  return lines;
}

async function sha256(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

const characterDirectory = path.join(OUTPUT_ROOT, 'characters');
const chatDirectory = path.join(OUTPUT_ROOT, 'chats', CHARACTER_ID);
const characterPath = path.join(characterDirectory, CHARACTER_FILE_NAME);
const chatPath = path.join(chatDirectory, CHAT_FILE_NAME);
const manifestPath = path.join(OUTPUT_ROOT, 'manifest.json');
const readmePath = path.join(OUTPUT_ROOT, 'README.md');

await mkdir(characterDirectory, { recursive: true });
await mkdir(chatDirectory, { recursive: true });
await writeFile(characterPath, createCharacterCard());
await writeFile(chatPath, `${createChatLines().join('\n')}\n`, 'utf8');

const manifest = {
  fixture: 'long-chat-300',
  character_file: `characters/${CHARACTER_FILE_NAME}`,
  chat_file: `chats/${CHARACTER_ID}/${CHAT_FILE_NAME}`,
  rounds: ROUND_COUNT,
  jsonl_lines: 1 + ROUND_COUNT * 2,
  messages: ROUND_COUNT * 2,
  user_message_length: USER_MESSAGE_LENGTH,
  assistant_message_length: ASSISTANT_MESSAGE_LENGTH,
  reasoning_length: REASONING_LENGTH,
  sha256: {
    character: await sha256(characterPath),
    chat: await sha256(chatPath),
  },
};
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
await writeFile(
  readmePath,
  `# 300 轮长聊天性能测试夹具\n\n` +
    `将本目录下的 \`characters\` 和 \`chats\` 复制到应用的 \`<filesDir>/data/default-user/\` 中。\n\n` +
    `角色卡文件基名和聊天目录均为 \`${CHARACTER_ID}\`，因此聊天会绑定到该 mock 角色。\n\n` +
    `- 300 轮用户与 AI 往返，共 600 条消息\n` +
    `- 每条用户消息 ${USER_MESSAGE_LENGTH} 个 JavaScript 字符\n` +
    `- 每条 AI 回复 ${ASSISTANT_MESSAGE_LENGTH} 个 JavaScript 字符\n` +
    `- 每条 AI 消息的 \`extra.reasoning\` 为 ${REASONING_LENGTH} 个 JavaScript 字符\n` +
    `- 完整性信息和 SHA-256 位于 \`manifest.json\`\n\n` +
    `重新生成：\`node scripts/generate-long-chat-fixture.mjs\`\n`,
  'utf8',
);

console.log(JSON.stringify(manifest, null, 2));
