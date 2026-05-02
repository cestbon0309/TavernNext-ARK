use std::borrow::Cow;
use std::collections::HashSet;
use std::ffi::{CStr, CString, c_char};
use std::io::{Cursor, Read};
use std::ptr;
use std::slice;
use std::str;
use std::sync::{Mutex, OnceLock};

use miktik::TokenizerRegistry;
use serde_json::Value;

static REGISTRY: OnceLock<TokenizerRegistry> = OnceLock::new();
static READY_MODELS: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();

const CLAUDE_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/claude.json.gz");
const DEEPSEEK_JSON_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/deepseek.json.gz");
const GEMMA_MODEL_GZIP_BYTES: &[u8] = include_bytes!("../resources/tokenizers/gemma.model.gz");
const OPENAI_MODELS: &[&str] = &[
    "o1",
    "gpt-4o",
    "gpt-4",
    "gpt-4-32k",
    "gpt-3.5-turbo",
    "gpt-3.5-turbo-0301",
];
const BUNDLED_HF_MODELS: &[&str] = &["claude", "deepseek", "gemma"];

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

fn canonical_model(requested: &str) -> &'static str {
    TokenizerRegistry::resolve_model_ref(requested)
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
    if !TokenizerRegistry::is_huggingface_model(canonical) {
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
    registry()
        .get_canonical(canonical)
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
    let tokenizer = registry()
        .get_canonical(canonical)
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
    CString::new("MikTik 0.2.0 openai+huggingface+sentencepiece")
        .expect("static string is valid")
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tavern_tokenizer_resolve_model(model: *const c_char) -> *mut c_char {
    let requested = unsafe { string_from_ptr(model, "") };
    let resolved = TokenizerRegistry::resolve_model(&requested);
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
    match registry()
        .get_canonical(canonical)
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

    match registry()
        .get_canonical(canonical)
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
    match registry()
        .get_canonical(canonical)
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

    let count = if TokenizerRegistry::is_sentencepiece_model(canonical) {
        let text = to_sentencepiece_count_input(&messages);
        registry()
            .count_tokens_canonical(canonical, &text)
            .map_err(|error| {
                format!("failed to count sentencepiece messages for '{canonical}': {error}")
            })
    } else if TokenizerRegistry::is_web_tokenizer_model(canonical) {
        let prompt = to_web_tokenizer_prompt(&messages);
        registry()
            .count_tokens_canonical(canonical, &prompt)
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
