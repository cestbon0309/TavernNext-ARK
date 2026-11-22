use std::borrow::Cow;
use std::collections::HashSet;
use std::ffi::{CStr, CString, c_char};
use std::io::{Cursor, Read};
use std::ptr;
use std::slice;
use std::str;
use std::sync::{Arc, Mutex, OnceLock};

use miktik::{Tokenizer, TokenizerError, TokenizerRegistry};
use serde_json::Value;

static REGISTRY: OnceLock<TokenizerRegistry> = OnceLock::new();
static READY_MODELS: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();

const CLAUDE_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/claude.json.gz");
const DEEPSEEK_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/deepseek.json.gz");
const GEMMA_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/gemma.model.gz");
const LLAMA_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/llama.model.gz");
const MISTRAL_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/mistral.model.gz");
const YI_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/yi.model.gz");
const JAMBA_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/jamba.model.gz");
const NERDSTASH_MODEL_GZIP_BYTES: &[u8] =
    include_bytes!("../resources/tokenizers/nerdstash.model.gz");
const NERDSTASH_V2_MODEL_GZIP_BYTES: &[u8] =
    include_bytes!("../resources/tokenizers/nerdstash_v2.model.gz");
const LLAMA3_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/llama3.json.gz");
const COMMAND_R_JSON_GZIP_BYTES: &[u8] =
    include_bytes!("../resources/tokenizers/command-r.json.gz");
const COMMAND_A_JSON_GZIP_BYTES: &[u8] =
    include_bytes!("../resources/tokenizers/command-a.json.gz");
const QWEN2_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/qwen2.json.gz");
const NEMO_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/nemo.json.gz");
const OPENAI_MODELS: &[&str] = &[
    "o1",
    "gpt-4o",
    "gpt-4",
    "gpt-4-32k",
    "gpt-3.5-turbo",
    "gpt-3.5-turbo-0301",
    "gpt-3.5-turbo-instruct",
    "gpt-3.5-turbo-instruct-0914",
    "text-davinci-003",
    "text-davinci-002",
    "text-davinci-001",
    "text-curie-001",
    "text-babbage-001",
    "text-ada-001",
    "code-davinci-002",
    "code-davinci-001",
    "code-cushman-002",
    "code-cushman-001",
    "text-davinci-edit-001",
    "code-davinci-edit-001",
    "text-embedding-ada-002",
    "text-similarity-davinci-001",
    "text-similarity-curie-001",
    "text-similarity-babbage-001",
    "text-similarity-ada-001",
    "text-search-davinci-doc-001",
    "text-search-curie-doc-001",
    "text-search-babbage-doc-001",
    "text-search-ada-doc-001",
    "code-search-babbage-code-001",
    "code-search-ada-code-001",
    "gpt2",
];
const BUNDLED_HF_MODELS: &[&str] = &[
    "claude",
    "deepseek",
    "gemma",
    "llama",
    "llama3",
    "mistral",
    "yi",
    "jamba",
    "nerdstash",
    "nerdstash_v2",
    "qwen2",
    "command-r",
    "command-a",
    "nemo",
];

#[repr(C)]
pub struct TokenizerEncodeResult {
    ids_ptr: *mut u32,
    ids_len: usize,
    error: *mut c_char,
}

#[repr(C)]
pub struct TokenizerStringResult {
    bytes_ptr: *mut u8,
    bytes_len: usize,
    error: *mut c_char,
}

#[repr(C)]
pub struct TokenizerCountResult {
    count: usize,
    error: *mut c_char,
}

#[repr(C)]
pub struct TokenizerJsonStringArrayResult {
    bytes_ptr: *mut u8,
    bytes_len: usize,
    error: *mut c_char,
}

#[derive(Clone, Copy)]
enum ResourceCompression {
    Gzip,
}

#[derive(Clone, Copy)]
struct ModelResourceSpec {
    bytes: &'static [u8],
    compression: ResourceCompression,
}

struct PromptMessage {
    role: String,
    name: Option<String>,
    content: String,
}

fn registry() -> &'static TokenizerRegistry {
    REGISTRY.get_or_init(TokenizerRegistry::new)
}

fn ready_models() -> &'static Mutex<HashSet<&'static str>> {
    READY_MODELS.get_or_init(|| Mutex::new(HashSet::new()))
}

unsafe fn string_from_ptr(value: *const c_char, fallback: &str) -> String {
    if value.is_null() {
        return fallback.to_string();
    }
    unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned()
}

unsafe fn text_from_parts<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    if ptr.is_null() && len > 0 {
        return Err("text pointer is null".to_string());
    }
    let bytes = if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    };
    str::from_utf8(bytes).map_err(|error| format!("text is not valid UTF-8: {error}"))
}

fn into_error(message: impl Into<String>) -> *mut c_char {
    let sanitized = message.into().replace('\0', " ");
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("tokenizer error").expect("static string is valid"))
        .into_raw()
}

fn into_bytes(text: String) -> (*mut u8, usize) {
    let mut boxed = text.into_bytes().into_boxed_slice();
    let bytes_ptr = boxed.as_mut_ptr();
    let bytes_len = boxed.len();
    std::mem::forget(boxed);
    (bytes_ptr, bytes_len)
}

fn into_json_bytes(value: &[String]) -> Result<(*mut u8, usize), String> {
    serde_json::to_string(value)
        .map(into_bytes)
        .map_err(|error| format!("failed to serialize tokenizer JSON result: {error}"))
}

const FALLBACK_MODEL: &str = "gpt-3.5-turbo";
const SENTENCEPIECE_MODELS: &[&str] = &[
    "llama",
    "mistral",
    "yi",
    "gemma",
    "jamba",
    "nerdstash",
    "nerdstash_v2",
];
const WEB_TOKENIZER_MODELS: &[&str] = &[
    "claude",
    "llama3",
    "command-r",
    "command-a",
    "qwen2",
    "nemo",
    "deepseek",
];
/// Substring rules for the bundled tokenizer families, in priority order.
const FAMILY_ALIASES: &[(&str, &str)] = &[
    ("claude", "claude"),
    ("llama3", "llama3"),
    ("llama-3", "llama3"),
    ("llama", "llama"),
    ("mistral", "mistral"),
    ("yi", "yi"),
    ("gemma", "gemma"),
    ("gemini", "gemma"),
    ("learnlm", "gemma"),
    ("jamba", "jamba"),
    ("nerdstash_v2", "nerdstash_v2"),
    ("nerdstash-v2", "nerdstash_v2"),
    ("nerdstash", "nerdstash"),
    ("command-r", "command-r"),
    ("command-a", "command-a"),
    ("qwen2", "qwen2"),
    ("nemo", "nemo"),
    ("deepseek", "deepseek"),
];

/// Maps a requested model name to one of this bridge's canonical names (`OPENAI_MODELS` and
/// `BUNDLED_HF_MODELS`). The names are this bridge's contract with the ArkTS side and are kept
/// independent of MikTik's model table; `backend_model` maps them onto it.
fn canonical_model(requested: &str) -> &'static str {
    let name = requested.trim().to_ascii_lowercase();
    if name == "gpt-2" {
        return "gpt2";
    }
    if let Some(exact) = OPENAI_MODELS
        .iter()
        .chain(BUNDLED_HF_MODELS)
        .find(|model| **model == name)
    {
        return exact;
    }
    if ["o1", "o3", "o4", "gpt-5"]
        .iter()
        .any(|prefix| name.starts_with(prefix))
    {
        return "o1";
    }
    if name.contains("gpt-4") || name.contains("chatgpt-4o") {
        if name.contains("32k") {
            return "gpt-4-32k";
        }
        if ["4o", "4.1", "4.5"].iter().any(|part| name.contains(part)) {
            return "gpt-4o";
        }
        return "gpt-4";
    }
    FAMILY_ALIASES
        .iter()
        .find(|(pattern, _)| name.contains(pattern))
        .map_or(FALLBACK_MODEL, |(_, canonical)| *canonical)
}

/// The MikTik model whose tokenizer serves a canonical name.
///
/// MikTik ships o200k_base, cl100k_base and r50k_base. The p50k_base and p50k_edit models
/// (text-davinci-002/003, code-* and the edit models) use r50k_base here: the vocabularies agree
/// except for p50k's extra tokens for runs of spaces, so counts are exact for text without such
/// runs and higher for text with them.
fn backend_model(canonical: &str) -> &str {
    match canonical {
        "o1" | "gpt-4o" => "gpt-4o",
        "gpt-4"
        | "gpt-4-32k"
        | "gpt-3.5-turbo"
        | "gpt-3.5-turbo-0301"
        | "gpt-3.5-turbo-instruct"
        | "gpt-3.5-turbo-instruct-0914"
        | "text-embedding-ada-002" => "gpt-4",
        _ if OPENAI_MODELS.contains(&canonical) => "gpt2",
        _ => canonical,
    }
}

/// One string per token id. A character split across byte-fallback tokens (an emoji in a
/// SentencePiece model) is attached to its last token; the tokens before it get an empty string.
fn decode_pieces(tokenizer: &Tokenizer, ids: &[u32]) -> Vec<String> {
    const MAX_UTF8_LEN: usize = 4;
    let mut pieces = Vec::with_capacity(ids.len());
    let mut start = 0;
    for end in 1..=ids.len() {
        if end - start > MAX_UTF8_LEN {
            start = end - 1;
        }
        match tokenizer.decode(&ids[start..end]) {
            Ok(piece) => {
                pieces.push(piece);
                start = end;
            }
            Err(_) => pieces.push(String::new()),
        }
    }
    pieces
}

fn tokenizer_for(canonical: &str) -> Result<Arc<Tokenizer>, TokenizerError> {
    registry().get(backend_model(canonical))
}

fn model_resource_spec(canonical: &str) -> Option<ModelResourceSpec> {
    match canonical {
        "claude" => Some(ModelResourceSpec {
            bytes: CLAUDE_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "deepseek" => Some(ModelResourceSpec {
            bytes: DEEPSEEK_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "gemma" => Some(ModelResourceSpec {
            bytes: GEMMA_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "llama" => Some(ModelResourceSpec {
            bytes: LLAMA_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "llama3" => Some(ModelResourceSpec {
            bytes: LLAMA3_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "mistral" => Some(ModelResourceSpec {
            bytes: MISTRAL_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "yi" => Some(ModelResourceSpec {
            bytes: YI_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "jamba" => Some(ModelResourceSpec {
            bytes: JAMBA_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "nerdstash" => Some(ModelResourceSpec {
            bytes: NERDSTASH_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "nerdstash_v2" => Some(ModelResourceSpec {
            bytes: NERDSTASH_V2_MODEL_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "command-r" => Some(ModelResourceSpec {
            bytes: COMMAND_R_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "command-a" => Some(ModelResourceSpec {
            bytes: COMMAND_A_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "qwen2" => Some(ModelResourceSpec {
            bytes: QWEN2_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        "nemo" => Some(ModelResourceSpec {
            bytes: NEMO_JSON_GZIP_BYTES,
            compression: ResourceCompression::Gzip,
        }),
        _ => None,
    }
}

fn is_bundled_native_request(requested: &str, canonical: &str) -> bool {
    if BUNDLED_HF_MODELS.contains(&canonical) {
        return true;
    }
    if !OPENAI_MODELS.contains(&canonical) {
        return false;
    }
    let trimmed = requested.trim();
    if trimmed.is_empty() {
        return true;
    }
    let lower = trimmed.to_ascii_lowercase();
    match canonical {
        "o1" => {
            lower == "o1"
                || lower.contains("o1-preview")
                || lower.contains("o1-mini")
                || lower.starts_with("o3")
                || lower.starts_with("o4")
                || lower.starts_with("gpt-5")
        }
        "gpt-4o" => {
            lower.contains("gpt-4o")
                || lower.contains("chatgpt-4o-latest")
                || lower.contains("gpt-4.1")
                || lower.contains("gpt-4.5")
        }
        "gpt-4-32k" => lower.contains("gpt-4-32k"),
        "gpt-4" => lower.contains("gpt-4"),
        "gpt-3.5-turbo-0301" => lower.contains("gpt-3.5-turbo-0301"),
        "gpt-3.5-turbo" => lower.contains("gpt-3.5-turbo"),
        "gpt2" => lower == "gpt2" || lower == "gpt-2",
        "gpt-3.5-turbo-instruct"
        | "gpt-3.5-turbo-instruct-0914"
        | "text-davinci-003"
        | "text-davinci-002"
        | "text-davinci-001"
        | "text-curie-001"
        | "text-babbage-001"
        | "text-ada-001"
        | "code-davinci-002"
        | "code-davinci-001"
        | "code-cushman-002"
        | "code-cushman-001"
        | "text-davinci-edit-001"
        | "code-davinci-edit-001"
        | "text-embedding-ada-002"
        | "text-similarity-davinci-001"
        | "text-similarity-curie-001"
        | "text-similarity-babbage-001"
        | "text-similarity-ada-001"
        | "text-search-davinci-doc-001"
        | "text-search-curie-doc-001"
        | "text-search-babbage-doc-001"
        | "text-search-ada-doc-001"
        | "code-search-babbage-code-001"
        | "code-search-ada-code-001" => lower == canonical,
        _ => false,
    }
}

fn decode_model_payload(spec: ModelResourceSpec) -> Result<Vec<u8>, String> {
    match spec.compression {
        ResourceCompression::Gzip => {
            let mut decoder = flate2::read::GzDecoder::new(Cursor::new(spec.bytes));
            let mut decompressed = Vec::new();
            decoder
                .read_to_end(&mut decompressed)
                .map_err(|error| format!("failed to decompress tokenizer payload: {error}"))?;
            Ok(decompressed)
        }
    }
}

fn ensure_model_ready_canonical(canonical: &'static str) -> Result<(), String> {
    if !BUNDLED_HF_MODELS.contains(&canonical) {
        return Ok(());
    }

    {
        let ready = ready_models()
            .lock()
            .map_err(|error| format!("tokenizer ready set lock poisoned: {error}"))?;
        if ready.contains(canonical) {
            return Ok(());
        }
    }

    let spec = model_resource_spec(canonical).ok_or_else(|| {
        format!("tokenizer resource is not bundled for canonical model '{canonical}'")
    })?;
    let bytes = decode_model_payload(spec)?;
    registry()
        .register_model_bytes(canonical, bytes)
        .map_err(|error| {
            format!("failed to register tokenizer resource for '{canonical}': {error}")
        })?;
    tokenizer_for(canonical)
        .map_err(|error| format!("failed to load tokenizer for '{canonical}': {error}"))?;

    let mut ready = ready_models()
        .lock()
        .map_err(|error| format!("tokenizer ready set lock poisoned: {error}"))?;
    ready.insert(canonical);
    Ok(())
}

fn ensure_model_ready(requested: &str) -> Result<&'static str, String> {
    let canonical = canonical_model(requested);
    if !is_bundled_native_request(requested, canonical) {
        return Err(format!(
            "canonical tokenizer model '{canonical}' is not supported by the bundled native bridge"
        ));
    }
    ensure_model_ready_canonical(canonical)?;
    Ok(canonical)
}

fn value_to_text(value: &Value) -> Cow<'_, str> {
    match value {
        Value::String(text) => Cow::Borrowed(text),
        _ => Cow::Owned(value.to_string()),
    }
}

fn to_sentencepiece_count_input(messages: &[Value]) -> String {
    let mut values = Vec::new();
    for message in messages {
        match message {
            Value::Object(map) => {
                for value in map.values() {
                    values.push(value_to_text(value).into_owned());
                }
            }
            _ => values.push(value_to_text(message).into_owned()),
        }
    }
    values.join("\n\n")
}

fn to_web_tokenizer_prompt(messages: &[Value]) -> String {
    let mut mapped = messages
        .iter()
        .map(|value| match value {
            Value::Object(map) => {
                let role = map
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("system")
                    .to_string();
                let name = map.get("name").and_then(Value::as_str).map(str::to_string);
                let mut content = map
                    .get("content")
                    .map(value_to_text)
                    .map(Cow::into_owned)
                    .unwrap_or_default();
                if let Some(tool_calls) = map.get("tool_calls") {
                    content.push_str(&tool_calls.to_string());
                }
                PromptMessage {
                    role,
                    name,
                    content,
                }
            }
            _ => PromptMessage {
                role: "system".to_string(),
                name: None,
                content: value_to_text(value).into_owned(),
            },
        })
        .collect::<Vec<_>>();

    if !mapped.is_empty() {
        mapped[0].role = "system".to_string();

        let mut first_assistant_index = None;
        for (index, message) in mapped.iter().enumerate() {
            if index > 0 && message.role == "assistant" {
                first_assistant_index = Some(index);
                break;
            }
        }

        mapped[0].role = "user".to_string();
        if let Some(index) = first_assistant_index {
            let candidate_index = index.saturating_sub(1);
            if candidate_index != 0 && mapped[candidate_index].role == "user" {
                mapped[candidate_index].role = "FixHumMsg".to_string();
            }
        }
    }

    let mut prompt = String::new();
    for (index, message) in mapped.iter().enumerate() {
        let prefix = match message.role.as_str() {
            "assistant" => "\n\nAssistant: ",
            "user" => "\n\nHuman: ",
            "system" => {
                if index == 0 {
                    ""
                } else if message.name.as_deref() == Some("example_assistant") {
                    "\n\nA: "
                } else if message.name.as_deref() == Some("example_user") {
                    "\n\nH: "
                } else {
                    "\n\n"
                }
            }
            "FixHumMsg" => "\n\nFirst message: ",
            _ => "",
        };
        prompt.push_str(prefix);

        if message.role != "system" {
            if let Some(name) = message.name.as_deref() {
                if !name.is_empty() {
                    prompt.push_str(name);
                    prompt.push_str(": ");
                }
            }
        }

        prompt.push_str(&message.content);
    }
    prompt
}

fn count_openai_messages(canonical: &'static str, messages: &[Value]) -> Result<usize, String> {
    let is_legacy = canonical == "gpt-3.5-turbo-0301";
    let tokens_per_message = if is_legacy { 4_i32 } else { 3_i32 };
    let tokens_per_name = if is_legacy { -1_i32 } else { 1_i32 };
    let tokenizer = tokenizer_for(canonical)
        .map_err(|error| format!("failed to load tokenizer for '{canonical}': {error}"))?;
    let mut total = 0_i32;

    for message in messages {
        total += tokens_per_message;
        match message {
            Value::Object(map) => {
                for (key, value) in map {
                    let text = value_to_text(value);
                    let count = tokenizer.count_tokens(text.as_ref()).map_err(|error| {
                        format!("failed to count tokens for '{canonical}': {error}")
                    })?;
                    total += count as i32;
                    if key == "name" {
                        total += tokens_per_name;
                    }
                }
            }
            _ => {
                let text = value_to_text(message);
                let count = tokenizer.count_tokens(text.as_ref()).map_err(|error| {
                    format!("failed to count tokens for '{canonical}': {error}")
                })?;
                total += count as i32;
            }
        }
    }

    total += 3;
    if is_legacy {
        total += 9;
    }
    Ok(total.max(0) as usize)
}

#[unsafe(no_mangle)]
pub extern "C" fn tavern_tokenizer_version() -> *mut c_char {
    CString::new("MikTik 0.5.2 openai+huggingface+sentencepiece")
        .expect("static string is valid")
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_resolve_model(model: *const c_char) -> *mut c_char {
    let requested = unsafe { string_from_ptr(model, "") };
    let resolved = canonical_model(&requested);
    CString::new(resolved)
        .expect("resolved tokenizer model never contains NUL")
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_can_use_model(model: *const c_char) -> bool {
    let requested = unsafe { string_from_ptr(model, "") };
    is_bundled_native_request(&requested, canonical_model(&requested))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_encode(
    model: *const c_char,
    text_ptr: *const u8,
    text_len: usize,
) -> TokenizerEncodeResult {
    let requested = unsafe { string_from_ptr(model, "gpt-3.5-turbo") };
    let input = match unsafe { text_from_parts(text_ptr, text_len) } {
        Ok(value) => value,
        Err(error) => {
            return TokenizerEncodeResult {
                ids_ptr: ptr::null_mut(),
                ids_len: 0,
                error: into_error(error),
            };
        }
    };
    let canonical = match ensure_model_ready(&requested) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerEncodeResult {
                ids_ptr: ptr::null_mut(),
                ids_len: 0,
                error: into_error(error),
            };
        }
    };
    match tokenizer_for(canonical)
        .and_then(|tokenizer| tokenizer.encode(&input))
    {
        Ok(ids) => {
            let mut boxed = ids.into_boxed_slice();
            let ids_ptr = boxed.as_mut_ptr();
            let ids_len = boxed.len();
            std::mem::forget(boxed);
            TokenizerEncodeResult {
                ids_ptr,
                ids_len,
                error: ptr::null_mut(),
            }
        }
        Err(error) => TokenizerEncodeResult {
            ids_ptr: ptr::null_mut(),
            ids_len: 0,
            error: into_error(error.to_string()),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_decode(
    model: *const c_char,
    ids_ptr: *const u32,
    ids_len: usize,
) -> TokenizerStringResult {
    if ids_ptr.is_null() && ids_len > 0 {
        return TokenizerStringResult {
            bytes_ptr: ptr::null_mut(),
            bytes_len: 0,
            error: into_error("token id pointer is null"),
        };
    }

    let requested = unsafe { string_from_ptr(model, "gpt-3.5-turbo") };
    let canonical = match ensure_model_ready(&requested) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerStringResult {
                bytes_ptr: ptr::null_mut(),
                bytes_len: 0,
                error: into_error(error),
            };
        }
    };
    let ids = if ids_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ids_ptr, ids_len) }
    };

    match tokenizer_for(canonical)
        .and_then(|tokenizer| tokenizer.decode(ids))
    {
        Ok(text) => {
            let (bytes_ptr, bytes_len) = into_bytes(text);
            TokenizerStringResult {
                bytes_ptr,
                bytes_len,
                error: ptr::null_mut(),
            }
        }
        Err(error) => TokenizerStringResult {
            bytes_ptr: ptr::null_mut(),
            bytes_len: 0,
            error: into_error(error.to_string()),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_count(
    model: *const c_char,
    text_ptr: *const u8,
    text_len: usize,
) -> TokenizerCountResult {
    let requested = unsafe { string_from_ptr(model, "gpt-3.5-turbo") };
    let input = match unsafe { text_from_parts(text_ptr, text_len) } {
        Ok(value) => value,
        Err(error) => {
            return TokenizerCountResult {
                count: 0,
                error: into_error(error),
            };
        }
    };
    let canonical = match ensure_model_ready(&requested) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerCountResult {
                count: 0,
                error: into_error(error),
            };
        }
    };
    match tokenizer_for(canonical)
        .and_then(|tokenizer| tokenizer.count_tokens(&input))
    {
        Ok(count) => TokenizerCountResult {
            count,
            error: ptr::null_mut(),
        },
        Err(error) => TokenizerCountResult {
            count: 0,
            error: into_error(error.to_string()),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_encode_pieces(
    model: *const c_char,
    text_ptr: *const u8,
    text_len: usize,
) -> TokenizerJsonStringArrayResult {
    let requested = unsafe { string_from_ptr(model, "gpt-3.5-turbo") };
    let input = match unsafe { text_from_parts(text_ptr, text_len) } {
        Ok(value) => value,
        Err(error) => {
            return TokenizerJsonStringArrayResult {
                bytes_ptr: ptr::null_mut(),
                bytes_len: 0,
                error: into_error(error),
            };
        }
    };
    let canonical = match ensure_model_ready(&requested) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerJsonStringArrayResult {
                bytes_ptr: ptr::null_mut(),
                bytes_len: 0,
                error: into_error(error),
            };
        }
    };

    let pieces = match tokenizer_for(canonical).and_then(|tokenizer| {
        let ids = tokenizer.encode(input)?;
        Ok(decode_pieces(&tokenizer, &ids))
    }) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerJsonStringArrayResult {
                bytes_ptr: ptr::null_mut(),
                bytes_len: 0,
                error: into_error(error.to_string()),
            };
        }
    };

    match into_json_bytes(&pieces) {
        Ok((bytes_ptr, bytes_len)) => TokenizerJsonStringArrayResult {
            bytes_ptr,
            bytes_len,
            error: ptr::null_mut(),
        },
        Err(error) => TokenizerJsonStringArrayResult {
            bytes_ptr: ptr::null_mut(),
            bytes_len: 0,
            error: into_error(error),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_count_messages(
    model: *const c_char,
    json_ptr: *const u8,
    json_len: usize,
) -> TokenizerCountResult {
    let requested = unsafe { string_from_ptr(model, "gpt-3.5-turbo") };
    let canonical = match ensure_model_ready(&requested) {
        Ok(value) => value,
        Err(error) => {
            return TokenizerCountResult {
                count: 0,
                error: into_error(error),
            };
        }
    };
    let input = match unsafe { text_from_parts(json_ptr, json_len) } {
        Ok(value) => value,
        Err(error) => {
            return TokenizerCountResult {
                count: 0,
                error: into_error(error),
            };
        }
    };
    let messages = match serde_json::from_str::<Value>(input) {
        Ok(Value::Array(values)) => values,
        Ok(value) => vec![value],
        Err(error) => {
            return TokenizerCountResult {
                count: 0,
                error: into_error(format!("message payload is not valid JSON: {error}")),
            };
        }
    };

    let count = if SENTENCEPIECE_MODELS.contains(&canonical) {
        let text = to_sentencepiece_count_input(&messages);
        tokenizer_for(canonical)
            .and_then(|tokenizer| tokenizer.count_tokens(&text))
            .map_err(|error| {
                format!("failed to count sentencepiece messages for '{canonical}': {error}")
            })
    } else if WEB_TOKENIZER_MODELS.contains(&canonical) {
        let prompt = to_web_tokenizer_prompt(&messages);
        tokenizer_for(canonical)
            .and_then(|tokenizer| tokenizer.count_tokens(&prompt))
            .map_err(|error| {
                format!("failed to count web-tokenizer messages for '{canonical}': {error}")
            })
    } else {
        count_openai_messages(canonical, &messages)
    };

    match count {
        Ok(count) => TokenizerCountResult {
            count,
            error: ptr::null_mut(),
        },
        Err(error) => TokenizerCountResult {
            count: 0,
            error: into_error(error),
        },
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_free_ids(ids_ptr: *mut u32, ids_len: usize) {
    if ids_ptr.is_null() {
        return;
    }
    let slice = ptr::slice_from_raw_parts_mut(ids_ptr, ids_len);
    unsafe {
        drop(Box::from_raw(slice));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_free_bytes(bytes_ptr: *mut u8, bytes_len: usize) {
    if bytes_ptr.is_null() {
        return;
    }
    let slice = ptr::slice_from_raw_parts_mut(bytes_ptr, bytes_len);
    unsafe {
        drop(Box::from_raw(slice));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_all_sillytavern_tokenizer_families() {
        let cases = [
            ("gpt2", "gpt2"),
            ("gpt-2", "gpt2"),
            ("llama-3.3-70b", "llama3"),
            ("llama-2-13b", "llama"),
            ("mistral-large", "mistral"),
            ("yi-34b", "yi"),
            ("gemini-2.0-flash", "gemma"),
            ("jamba-1.5", "jamba"),
            ("nerdstash", "nerdstash"),
            ("nerdstash_v2", "nerdstash_v2"),
            ("nerdstash-v2", "nerdstash_v2"),
            ("qwen2.5-coder", "qwen2"),
            ("command-r-plus", "command-r"),
            ("command-a-03", "command-a"),
            ("nemo", "nemo"),
            ("deepseek-chat", "deepseek"),
        ];

        for (requested, expected) in cases {
            assert_eq!(canonical_model(requested), expected, "{requested}");
            assert!(
                is_bundled_native_request(requested, expected),
                "{requested} should be supported by bundled native bridge"
            );
        }
    }

    #[test]
    fn bundled_tokenizer_resources_load_and_encode() {
        for model in [
            "claude",
            "deepseek",
            "gemma",
            "llama",
            "llama3",
            "mistral",
            "yi",
            "jamba",
            "nerdstash",
            "nerdstash_v2",
            "qwen2",
            "command-r",
            "command-a",
            "nemo",
        ] {
            let canonical = ensure_model_ready(model).expect("model should prepare");
            let tokenizer = tokenizer_for(canonical)
                .expect("tokenizer should load");
            let ids = tokenizer
                .encode("Hello world")
                .expect("tokenizer should encode");
            assert!(!ids.is_empty(), "{model} should return token ids");
            assert!(
                tokenizer.count_tokens("Hello world").expect("count") > 0,
                "{model} should count tokens"
            );
            if SENTENCEPIECE_MODELS.contains(&canonical) {
                let pieces = ids
                    .iter()
                    .map(|id| tokenizer.decode(&[*id]))
                    .collect::<Result<Vec<_>, _>>()
                    .expect("sentencepiece pieces");
                assert_eq!(pieces.len(), ids.len(), "{model} pieces should match ids");
            }
        }
    }

    #[test]
    fn tiktoken_explicit_models_are_native() {
        for model in [
            "gpt2",
            "text-davinci-003",
            "code-davinci-002",
            "text-embedding-ada-002",
        ] {
            assert!(
                is_bundled_native_request(model, canonical_model(model)),
                "{model} should be native"
            );
            let canonical = ensure_model_ready(model).expect("tiktoken model should prepare");
            let ids = tokenizer_for(canonical)
                .expect("tokenizer should load")
                .encode("Hello world")
                .expect("tokenizer should encode");
            assert!(!ids.is_empty(), "{model} should return token ids");
        }
    }

    #[test]
    fn unknown_custom_model_still_uses_openai_fallback() {
        let requested = "my-openai-compatible-model";
        let canonical = canonical_model(requested);
        assert_eq!(canonical, "gpt-3.5-turbo");
        assert!(
            !is_bundled_native_request(requested, canonical),
            "explicit unknown model should not be native unless ArkTS resolves openai routes first"
        );
        assert!(is_bundled_native_request(canonical, canonical));
    }

    #[test]
    fn pieces_keep_characters_split_across_tokens() {
        let canonical = ensure_model_ready("llama").expect("llama should load");
        let tokenizer = tokenizer_for(canonical).expect("llama tokenizer");
        let ids = tokenizer.encode("hi \u{1F600} there").expect("encode");
        let pieces = decode_pieces(&tokenizer, &ids);
        assert_eq!(pieces.len(), ids.len());
        assert!(pieces.concat().contains('\u{1F600}'));
    }
}
