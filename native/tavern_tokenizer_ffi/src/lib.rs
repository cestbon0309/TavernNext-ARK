use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::slice;
use std::str;
use std::sync::OnceLock;

use miktik::TokenizerRegistry;

static REGISTRY: OnceLock<TokenizerRegistry> = OnceLock::new();

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

fn registry() -> &'static TokenizerRegistry {
    REGISTRY.get_or_init(TokenizerRegistry::new)
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

#[unsafe(no_mangle)]
pub extern "C" fn tavern_tokenizer_version() -> *mut c_char {
    CString::new("MikTik 0.2.0 openai")
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
    match registry().get(&requested).and_then(|tokenizer| tokenizer.encode(&input)) {
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
    let ids = if ids_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ids_ptr, ids_len) }
    };

    match registry()
        .get(&requested)
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
    match registry()
        .get(&requested)
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
