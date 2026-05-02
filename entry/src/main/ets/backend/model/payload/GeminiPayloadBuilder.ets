import { JsonArray, JsonRecord, emptyJsonRecord } from '../../HttpTypes';
import { BuiltChatPayload } from '../ChatCompletionTypes';
import {
  asArrayValue,
  asBooleanValue,
  asNumberValue,
  asRecordValue,
  asStringValue,
  cloneJsonValue,
  messageContentToText,
  parseDataUrl,
} from '../JsonHelpers';
import {
  OpenAiToolCall,
  extractOpenAiToolCalls,
  fallbackToolName,
  messageToolCallId,
  messageToolName,
  messageToolResultText,
  normalizeToolResultPayload,
} from './claude/ToolCalls';

const GOOGLE_FLASH_MAX_BUDGET = 24576;
const GOOGLE_PRO_MAX_BUDGET = 32768;

const GOOGLE_IMAGE_GENERATION_MODELS: string[] = [
  'gemini-2.0-flash-exp',
  'gemini-2.0-flash-exp-image-generation',
  'gemini-2.0-flash-preview-image-generation',
  'gemini-2.5-flash-image-preview',
  'gemini-2.5-flash-image',
  'gemini-3-pro-image-preview',
];

const GOOGLE_NO_SEARCH_MODELS: string[] = [
  'gemini-2.0-flash-lite',
  'gemini-2.0-flash-lite-001',
  'gemini-2.0-flash-lite-preview-02-05',
  'gemini-robotics-er-1.5-preview',
];

const SKIP_THOUGHT_SIGNATURE_VALIDATOR = 'skip_thought_signature_validator';

class GeminiMessageConversion {
  contents: JsonArray = [];
  systemPrompt: string = '';
}

class GeminiThinkingBudget {
  tokens: number = 0;
  level: string = '';
}

class GeminiToolSplit {
  functionDeclarations: JsonArray = [];
  customTools: JsonArray = [];
}

export class GeminiPayloadBuilder {
  private vertexAi: boolean = false;

  constructor(vertexAi: boolean = false) {
    this.vertexAi = vertexAi;
  }

  build(payload: JsonRecord): BuiltChatPayload {
    const model = asStringValue(payload['model']).trim();
    if (model.length === 0) {
      throw new Error('Gemini request is missing model');
    }
    const body = this.buildGeminiBody(payload, model);
    const encodedModel = encodeURIComponent(model);
    const method = asBooleanValue(payload['stream']) ? 'streamGenerateContent?alt=sse' : 'generateContent';
    const endpoint = this.vertexAi ? `/publishers/google/models/${encodedModel}:${method}` :
      `/v1beta/models/${encodedModel}:${method}`;
    return new BuiltChatPayload(endpoint, body);
  }

  private buildGeminiBody(payload: JsonRecord, model: string): JsonRecord {
    const request = emptyJsonRecord();
    request['model'] = model;

    const enableWebSearch = asBooleanValue(payload['enable_web_search']);
    const requestImages = asBooleanValue(payload['request_images']);
    const aspectRatio = asStringValue(payload['request_image_aspect_ratio']).trim();
    const imageSize = asStringValue(payload['request_image_resolution']).trim();
    const modelLower = model.trim().toLowerCase();
    const isGemma = modelLower.includes('gemma');
    const isLearnLm = modelLower.includes('learnlm');
    const enableImageModality = requestImages && GOOGLE_IMAGE_GENERATION_MODELS.includes(model);
    const useSystemPrompt = asBooleanValue(payload['use_sysprompt']) && !enableImageModality && !isGemma;

    const conversion = this.convertMessages(payload['messages'], model, useSystemPrompt);
    request['contents'] = conversion.contents.length > 0 ? conversion.contents : [this.content('user', [this.textPart('')])];

    const generationConfig = this.generationConfig(payload, model, enableImageModality, aspectRatio, imageSize);
    request['generationConfig'] = generationConfig;
    request['safetySettings'] = this.googleSafetySettings();

    if (useSystemPrompt && conversion.systemPrompt.length > 0) {
      const systemInstruction = emptyJsonRecord();
      systemInstruction['parts'] = [this.textPart(conversion.systemPrompt)];
      request['systemInstruction'] = systemInstruction;
    }

    const tools = this.tools(payload, model, enableImageModality, isGemma, isLearnLm, enableWebSearch);
    if (tools.length > 0) {
      request['tools'] = tools;
      const toolChoice = this.mapToolChoiceToMakersuite(payload['tool_choice']);
      if (toolChoice !== null && this.requestHasFunctionDeclarations(request)) {
        const toolConfig = emptyJsonRecord();
        toolConfig['functionCallingConfig'] = toolChoice;
        request['toolConfig'] = toolConfig;
      }
    }

    return request;
  }

  private convertMessages(messagesValue: Object | string | number | boolean | null | JsonArray | undefined,
    model: string, useSystemPrompt: boolean): GeminiMessageConversion {
    const conversion = new GeminiMessageConversion();
    if (typeof messagesValue === 'string') {
      conversion.contents.push(this.content('user', [this.textPart(messagesValue)]));
      return conversion;
    }

    const entries = asArrayValue(messagesValue);
    const toolNameById: Record<string, string> = {};
    const modelLower = model.trim().toLowerCase();
    const supportsSignatures = modelLower.includes('gemini-3') || modelLower.includes('gemini-2.5');
    const isGemini3 = modelLower.includes('gemini-3');
    const isImageModel = modelLower.includes('-image');

    let startIndex = 0;
    const systemParts: string[] = [];
    if (useSystemPrompt && entries.length > 1) {
      while (startIndex < entries.length - 1) {
        const item = entries[startIndex];
        if (item === null || Array.isArray(item) || typeof item !== 'object') {
          break;
        }
        const message = item as JsonRecord;
        const role = asStringValue(message['role']).trim().toLowerCase() || 'user';
        if (role !== 'system') {
          break;
        }
        const contentText = messageContentToText(message['content']);
        if (contentText.length > 0) {
          systemParts.push(contentText);
        }
        startIndex += 1;
      }
    }
    conversion.systemPrompt = systemParts.join('\n\n');

    for (let index = startIndex; index < entries.length; index += 1) {
      const item = entries[index];
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const message = item as JsonRecord;
      const role = asStringValue(message['role']).trim().toLowerCase() || 'user';
      let parts = this.convertMessageContentToParts(message['content'], isGemini3);

      if (role === 'assistant') {
        const toolCalls = extractOpenAiToolCalls(message['tool_calls']);
        if (toolCalls.length > 0) {
          for (let callIndex = 0; callIndex < toolCalls.length; callIndex += 1) {
            const call = toolCalls[callIndex];
            toolNameById[call.id] = call.name;
          }
          const callParts = this.convertOpenAiToolCallsToParts(toolCalls);
          for (let callIndex = 0; callIndex < callParts.length; callIndex += 1) {
            parts.push(callParts[callIndex]);
          }
        }
      }

      if (role === 'tool') {
        const toolCallId = messageToolCallId(message);
        const explicitName = messageToolName(message);
        const name = explicitName.length > 0 ? explicitName :
          (toolCallId.length > 0 && toolNameById[toolCallId] !== undefined ? toolNameById[toolCallId] : fallbackToolName());
        parts = [this.buildToolResponsePart(name, messageToolResultText(message))];
      }

      if (parts.length === 0) {
        parts.push(this.textPart(''));
      }

      const targetRole = role === 'assistant' ? 'model' : 'user';
      if (supportsSignatures) {
        this.applyThoughtSignatures(parts, message, targetRole, isGemini3, isImageModel);
      }
      conversion.contents.push(this.content(targetRole, parts));
    }

    return conversion;
  }

  private convertMessageContentToParts(content: Object | string | number | boolean | null | JsonArray | undefined,
    isGemini3: boolean): JsonArray {
    if (content === undefined || content === null) {
      return [];
    }
    if (typeof content === 'string') {
      return content.length > 0 ? [this.textPart(content)] : [];
    }
    if (!Array.isArray(content)) {
      return [this.textPart(String(content))];
    }

    const result: JsonArray = [];
    const parts: JsonArray = content;
    for (let index = 0; index < parts.length; index += 1) {
      const item = parts[index];
      if (typeof item === 'string') {
        result.push(this.textPart(item));
        continue;
      }
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const record = item as JsonRecord;
      const text = asStringValue(record['text']).trim();
      if (text.length > 0) {
        result.push(this.textPart(text));
        continue;
      }
      const inlineData = asRecordValue(record['inlineData']);
      if (Object.keys(inlineData).length > 0) {
        const part = emptyJsonRecord();
        part['inlineData'] = cloneJsonValue(inlineData) as Object;
        result.push(part);
        continue;
      }
      const inlineDataSnake = asRecordValue(record['inline_data']);
      if (Object.keys(inlineDataSnake).length > 0) {
        const part = emptyJsonRecord();
        part['inlineData'] = cloneJsonValue(inlineDataSnake) as Object;
        result.push(part);
        continue;
      }
      const functionCall = asRecordValue(record['functionCall']);
      if (Object.keys(functionCall).length > 0) {
        const part = emptyJsonRecord();
        part['functionCall'] = cloneJsonValue(functionCall) as Object;
        result.push(part);
        continue;
      }
      const type = asStringValue(record['type']);
      if (type === 'image_url' || type === 'video_url' || type === 'audio_url') {
        const mediaPart = this.mediaPart(record, type, isGemini3);
        if (mediaPart !== null) {
          result.push(mediaPart);
        }
      }
    }
    return result;
  }

  private mediaPart(record: JsonRecord, type: string, isGemini3: boolean): JsonRecord | null {
    const key = type === 'image_url' ? 'image_url' : type === 'video_url' ? 'video_url' : 'audio_url';
    const source = asRecordValue(record[key]);
    const dataUrl = parseDataUrl(asStringValue(source['url']));
    if (dataUrl === null) {
      return null;
    }
    const inlineData = emptyJsonRecord();
    inlineData['mimeType'] = asStringValue(dataUrl['mimeType']);
    inlineData['data'] = asStringValue(dataUrl['data']);
    const part = emptyJsonRecord();
    part['inlineData'] = inlineData;
    if (isGemini3 && (type === 'image_url' || type === 'video_url')) {
      const resolution = this.geminiMediaResolution(asStringValue(source['detail']));
      if (resolution.length > 0) {
        const mediaResolution = emptyJsonRecord();
        mediaResolution['level'] = resolution;
        part['mediaResolution'] = mediaResolution;
      }
    }
    return part;
  }

  private convertOpenAiToolCallsToParts(toolCalls: OpenAiToolCall[]): JsonArray {
    const result: JsonArray = [];
    for (let index = 0; index < toolCalls.length; index += 1) {
      const toolCall = toolCalls[index];
      const functionCall = emptyJsonRecord();
      functionCall['name'] = toolCall.name;
      functionCall['args'] = cloneJsonValue(toolCall.arguments);
      const part = emptyJsonRecord();
      part['functionCall'] = functionCall;
      if (toolCall.signature.length > 0) {
        part['thoughtSignature'] = toolCall.signature;
      }
      result.push(part);
    }
    return result;
  }

  private buildToolResponsePart(name: string, content: string): JsonRecord {
    const functionResponse = emptyJsonRecord();
    functionResponse['name'] = name;
    functionResponse['response'] = normalizeToolResultPayload(content);
    const part = emptyJsonRecord();
    part['functionResponse'] = functionResponse;
    return part;
  }

  private applyThoughtSignatures(parts: JsonArray, message: JsonRecord, targetRole: string, isGemini3: boolean,
    isImageModel: boolean): void {
    const textSignature = asStringValue(message['signature']).trim();
    for (let index = 0; index < parts.length; index += 1) {
      const part = parts[index];
      if (part === null || Array.isArray(part) || typeof part !== 'object') {
        continue;
      }
      const record = part as JsonRecord;
      const isTextPart = asStringValue(record['text']).length > 0;
      if (textSignature.length > 0 && isTextPart) {
        record['thoughtSignature'] = textSignature;
        continue;
      }
      if (isGemini3 && record['functionCall'] !== undefined && record['thoughtSignature'] === undefined) {
        record['thoughtSignature'] = SKIP_THOUGHT_SIGNATURE_VALIDATOR;
      }
      if (isGemini3 && isImageModel && targetRole === 'model' &&
        (isTextPart || record['inlineData'] !== undefined) && record['thoughtSignature'] === undefined) {
        record['thoughtSignature'] = SKIP_THOUGHT_SIGNATURE_VALIDATOR;
      }
    }
  }

  private generationConfig(payload: JsonRecord, model: string, enableImageModality: boolean, aspectRatio: string,
    imageSize: string): JsonRecord {
    const config = emptyJsonRecord();
    config['candidateCount'] = 1;
    const maxTokens = payload['max_tokens'] ?? payload['max_completion_tokens'];
    if (maxTokens !== undefined && maxTokens !== null) {
      config['maxOutputTokens'] = cloneJsonValue(maxTokens);
    }
    if (payload['temperature'] !== undefined && payload['temperature'] !== null) {
      config['temperature'] = cloneJsonValue(payload['temperature']);
    }
    if (payload['top_p'] !== undefined && payload['top_p'] !== null) {
      config['topP'] = cloneJsonValue(payload['top_p']);
    }
    if (payload['top_k'] !== undefined && payload['top_k'] !== null && asNumberValue(payload['top_k']) !== 0) {
      config['topK'] = cloneJsonValue(payload['top_k']);
    }
    if (payload['seed'] !== undefined && payload['seed'] !== null) {
      config['seed'] = cloneJsonValue(payload['seed']);
    }
    const stop = asArrayValue(payload['stop']);
    if (stop.length > 0) {
      config['stopSequences'] = cloneJsonValue(stop);
    }
    const responseMimeType = this.responseMimeType(payload);
    if (responseMimeType.length > 0) {
      config['responseMimeType'] = responseMimeType;
    }
    const responseSchema = this.responseSchema(payload);
    if (responseSchema !== null) {
      config['responseSchema'] = responseSchema;
    }
    if (enableImageModality) {
      config['responseModalities'] = ['text', 'image'];
      const imageConfig = emptyJsonRecord();
      if (imageSize.length > 0 && this.isGoogleImageSizeModel(model)) {
        imageConfig['imageSize'] = imageSize;
      }
      if (aspectRatio.length > 0) {
        imageConfig['aspectRatio'] = aspectRatio;
      }
      if (Object.keys(imageConfig).length > 0) {
        config['imageConfig'] = imageConfig;
      }
    }
    this.injectGoogleThinkingConfig(payload, model, config);
    return config;
  }

  private responseMimeType(payload: JsonRecord): string {
    const explicit = asStringValue(payload['responseMimeType']).trim();
    if (explicit.length > 0) {
      return explicit;
    }
    const schema = asRecordValue(payload['json_schema']);
    if (schema['value'] !== undefined && schema['value'] !== null) {
      return 'application/json';
    }
    return '';
  }

  private responseSchema(payload: JsonRecord): Object | string | number | boolean | null | JsonArray {
    if (payload['responseSchema'] !== undefined && payload['responseSchema'] !== null) {
      return cloneJsonValue(payload['responseSchema']);
    }
    const schema = asRecordValue(payload['json_schema']);
    const value = schema['value'];
    if (value === undefined || value === null) {
      return null;
    }
    return cloneJsonValue(value);
  }

  private tools(payload: JsonRecord, model: string, enableImageModality: boolean, isGemma: boolean, isLearnLm: boolean,
    enableWebSearch: boolean): JsonArray {
    if (enableImageModality || isGemma) {
      return [];
    }
    const tools: JsonArray = [];
    const split = this.splitOpenAiTools(payload['tools']);
    if (split.functionDeclarations.length > 0) {
      const tool = emptyJsonRecord();
      tool['function_declarations'] = split.functionDeclarations;
      tools.push(tool);
    } else if (split.customTools.length > 0) {
      for (let index = 0; index < split.customTools.length; index += 1) {
        tools.push(split.customTools[index]);
      }
    }
    const modelBlocked = GOOGLE_NO_SEARCH_MODELS.includes(model);
    const hasFunctionDeclarations = tools.some((item: Object | string | number | boolean | null): boolean => {
      return item !== null && !Array.isArray(item) && typeof item === 'object' &&
        (item as JsonRecord)['function_declarations'] !== undefined;
    });
    if (enableWebSearch && !isLearnLm && !modelBlocked && !hasFunctionDeclarations) {
      const web = emptyJsonRecord();
      web['google_search'] = emptyJsonRecord();
      tools.push(web);
    }
    return tools;
  }

  private splitOpenAiTools(value: Object | string | number | boolean | null | JsonArray | undefined): GeminiToolSplit {
    const split = new GeminiToolSplit();
    const tools = asArrayValue(value);
    for (let index = 0; index < tools.length; index += 1) {
      const item = tools[index];
      if (item === null || Array.isArray(item) || typeof item !== 'object') {
        continue;
      }
      const tool = item as JsonRecord;
      const toolType = asStringValue(tool['type']).trim();
      if (toolType.length === 0) {
        continue;
      }
      if (toolType === 'function') {
        const fn = asRecordValue(tool['function']);
        if (Object.keys(fn).length === 0) {
          continue;
        }
        const mapped = cloneJsonValue(fn) as JsonRecord;
        const parameters = asRecordValue(mapped['parameters']);
        if (Object.keys(parameters).length > 0) {
          const cleanedParameters = this.withoutKey(parameters, '$schema');
          const properties = asRecordValue(cleanedParameters['properties']);
          if (Object.keys(properties).length > 0 || cleanedParameters['properties'] === undefined) {
            mapped['parameters'] = cleanedParameters;
          }
        }
        split.functionDeclarations.push(mapped);
        continue;
      }
      const customTool = tool[toolType];
      if (customTool !== undefined && customTool !== null) {
        const mapped = emptyJsonRecord();
        mapped[toolType] = cloneJsonValue(customTool);
        split.customTools.push(mapped);
      }
    }
    return split;
  }

  private withoutKey(source: JsonRecord, skippedKey: string): JsonRecord {
    const next = emptyJsonRecord();
    Object.keys(source).forEach((key: string) => {
      if (key !== skippedKey) {
        next[key] = cloneJsonValue(source[key]);
      }
    });
    return next;
  }

  private mapToolChoiceToMakersuite(value: Object | string | number | boolean | null | JsonArray | undefined): JsonRecord | null {
    if (typeof value === 'string') {
      const choice = value.trim();
      if (choice === 'none' || choice === 'required' || choice === 'auto') {
        const mapped = emptyJsonRecord();
        mapped['mode'] = choice === 'none' ? 'NONE' : choice === 'required' ? 'ANY' : 'AUTO';
        return mapped;
      }
      return null;
    }
    const object = asRecordValue(value);
    const fn = asRecordValue(object['function']);
    const functionName = asStringValue(fn['name']).trim();
    if (functionName.length > 0) {
      const mapped = emptyJsonRecord();
      mapped['mode'] = 'ANY';
      mapped['allowedFunctionNames'] = [functionName];
      return mapped;
    }
    return null;
  }

  private requestHasFunctionDeclarations(request: JsonRecord): boolean {
    const tools = asArrayValue(request['tools']);
    for (let index = 0; index < tools.length; index += 1) {
      const item = tools[index];
      if (item !== null && !Array.isArray(item) && typeof item === 'object' &&
        (item as JsonRecord)['function_declarations'] !== undefined) {
        return true;
      }
    }
    return false;
  }

  private injectGoogleThinkingConfig(payload: JsonRecord, model: string, generationConfig: JsonRecord): void {
    if (!this.isGoogleThinkingConfigModel(model)) {
      return;
    }
    const includeReasoning = asBooleanValue(payload['include_reasoning']);
    const reasoningEffort = asStringValue(payload['reasoning_effort']) || 'auto';
    const maxOutputTokens = Math.trunc(asNumberValue(generationConfig['maxOutputTokens'], 0));
    const budget = this.calculateGoogleBudget(maxOutputTokens, reasoningEffort, model);
    const thinkingConfig = emptyJsonRecord();
    let includeThoughts = includeReasoning;
    if (budget !== null) {
      if (budget.level.length > 0) {
        thinkingConfig['thinkingLevel'] = budget.level;
      } else {
        thinkingConfig['thinkingBudget'] = budget.tokens;
        if (this.vertexAi && budget.tokens === 0 && includeThoughts) {
          includeThoughts = false;
        }
      }
    }
    thinkingConfig['includeThoughts'] = includeThoughts;
    generationConfig['thinkingConfig'] = thinkingConfig;
  }

  private calculateGoogleBudget(maxTokens: number, rawEffort: string, model: string): GeminiThinkingBudget | null {
    const modelLower = model.trim().toLowerCase();
    const effort = rawEffort.trim().toLowerCase();
    const safeMax = Math.max(0, maxTokens);
    const budget = new GeminiThinkingBudget();

    if (modelLower.includes('gemini-3-pro')) {
      if (effort === 'auto') {
        return null;
      }
      if (effort === 'min' || effort === 'low' || effort === 'medium') {
        budget.level = 'low';
        return budget;
      }
      if (effort === 'high' || effort === 'max' || effort === 'xhigh') {
        budget.level = 'high';
        return budget;
      }
      return null;
    }

    if (modelLower.includes('gemini-3-flash')) {
      if (effort === 'auto') {
        return null;
      }
      if (effort === 'min') {
        budget.level = 'minimal';
      } else if (effort === 'low') {
        budget.level = 'low';
      } else if (effort === 'medium') {
        budget.level = 'medium';
      } else if (effort === 'high' || effort === 'max' || effort === 'xhigh') {
        budget.level = 'high';
      } else {
        return null;
      }
      return budget;
    }

    if (modelLower.includes('flash-lite')) {
      const tokens = this.tokensForEffort(effort, safeMax, 0);
      if (tokens === null) {
        return null;
      }
      budget.tokens = tokens < 0 ? -1 : this.clamp(tokens, 512, GOOGLE_FLASH_MAX_BUDGET);
      return budget;
    }

    if (modelLower.includes('flash')) {
      const tokens = this.tokensForEffort(effort, safeMax, 0);
      if (tokens === null) {
        return null;
      }
      budget.tokens = tokens < 0 ? -1 : this.clamp(tokens, 0, GOOGLE_FLASH_MAX_BUDGET);
      return budget;
    }

    if (modelLower.includes('pro')) {
      const tokens = this.tokensForEffort(effort, safeMax, 128);
      if (tokens === null) {
        return null;
      }
      budget.tokens = tokens < 0 ? -1 : this.clamp(tokens, 128, GOOGLE_PRO_MAX_BUDGET);
      return budget;
    }

    return null;
  }

  private tokensForEffort(effort: string, maxTokens: number, minTokens: number): number | null {
    switch (effort) {
      case 'auto':
        return -1;
      case 'min':
        return minTokens;
      case 'low':
        return Math.floor(maxTokens * 10 / 100);
      case 'medium':
        return Math.floor(maxTokens * 25 / 100);
      case 'high':
        return Math.floor(maxTokens * 50 / 100);
      case 'max':
      case 'xhigh':
        return maxTokens;
      default:
        return null;
    }
  }

  private isGoogleThinkingConfigModel(model: string): boolean {
    const value = model.trim().toLowerCase();
    const isGemini25 = (value.startsWith('gemini-2.5-flash') || value.startsWith('gemini-2.5-pro')) &&
      !value.endsWith('-image') && !value.endsWith('-image-preview');
    const isGemini3 = value.startsWith('gemini-3-flash') || value.startsWith('gemini-3-pro');
    return isGemini25 || isGemini3;
  }

  private isGoogleImageSizeModel(model: string): boolean {
    return model.trim().toLowerCase().startsWith('gemini-3');
  }

  private googleSafetySettings(): JsonArray {
    const settings: JsonArray = [
      this.safetySetting('HARM_CATEGORY_HARASSMENT'),
      this.safetySetting('HARM_CATEGORY_HATE_SPEECH'),
      this.safetySetting('HARM_CATEGORY_SEXUALLY_EXPLICIT'),
      this.safetySetting('HARM_CATEGORY_DANGEROUS_CONTENT'),
      this.safetySetting('HARM_CATEGORY_CIVIC_INTEGRITY'),
    ];
    if (this.vertexAi) {
      settings.push(this.safetySetting('HARM_CATEGORY_IMAGE_HATE'));
      settings.push(this.safetySetting('HARM_CATEGORY_IMAGE_DANGEROUS_CONTENT'));
      settings.push(this.safetySetting('HARM_CATEGORY_IMAGE_HARASSMENT'));
      settings.push(this.safetySetting('HARM_CATEGORY_IMAGE_SEXUALLY_EXPLICIT'));
      settings.push(this.safetySetting('HARM_CATEGORY_JAILBREAK'));
    }
    return settings;
  }

  private safetySetting(category: string): JsonRecord {
    const setting = emptyJsonRecord();
    setting['category'] = category;
    setting['threshold'] = 'OFF';
    return setting;
  }

  private content(role: string, parts: JsonArray): JsonRecord {
    const value = emptyJsonRecord();
    value['role'] = role;
    value['parts'] = parts;
    return value;
  }

  private textPart(text: string): JsonRecord {
    const part = emptyJsonRecord();
    part['text'] = text;
    return part;
  }

  private geminiMediaResolution(detail: string): string {
    const value = detail.trim();
    if (value === 'low') {
      return 'media_resolution_low';
    }
    if (value === 'high') {
      return 'media_resolution_high';
    }
    return '';
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }
}
