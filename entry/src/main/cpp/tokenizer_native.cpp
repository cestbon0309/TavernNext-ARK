#include "napi/native_api.h"

#include <cstdint>
#include <string>
#include <vector>

extern "C" {

struct TokenizerEncodeResult {
    uint32_t *ids_ptr;
    size_t ids_len;
    char *error;
};

struct TokenizerStringResult {
    uint8_t *bytes_ptr;
    size_t bytes_len;
    char *error;
};

struct TokenizerCountResult {
    size_t count;
    char *error;
};

char *tavern_tokenizer_version();
char *tavern_tokenizer_resolve_model(const char *model);
bool tavern_tokenizer_can_use_model(const char *model);
TokenizerEncodeResult tavern_tokenizer_encode(const char *model, const uint8_t *text_ptr, size_t text_len);
TokenizerStringResult tavern_tokenizer_decode(const char *model, const uint32_t *ids_ptr, size_t ids_len);
TokenizerCountResult tavern_tokenizer_count(const char *model, const uint8_t *text_ptr, size_t text_len);
TokenizerCountResult tavern_tokenizer_count_messages(const char *model, const uint8_t *json_ptr, size_t json_len);
void tavern_tokenizer_free_ids(uint32_t *ids_ptr, size_t ids_len);
void tavern_tokenizer_free_bytes(uint8_t *bytes_ptr, size_t bytes_len);
void tavern_tokenizer_free_string(char *value);

}

namespace {

struct NativeString {
    char *value { nullptr };

    explicit NativeString(char *input) : value(input) {}
    ~NativeString()
    {
        if (value != nullptr) {
            tavern_tokenizer_free_string(value);
        }
    }

    NativeString(const NativeString &) = delete;
    NativeString &operator=(const NativeString &) = delete;

    std::string str() const
    {
        return value == nullptr ? "" : std::string(value);
    }
};

struct NativeBytes {
    uint8_t *value { nullptr };
    size_t length { 0 };

    NativeBytes(uint8_t *input, size_t inputLength) : value(input), length(inputLength) {}
    ~NativeBytes()
    {
        if (value != nullptr) {
            tavern_tokenizer_free_bytes(value, length);
        }
    }

    NativeBytes(const NativeBytes &) = delete;
    NativeBytes &operator=(const NativeBytes &) = delete;

    std::string str() const
    {
        return value == nullptr ? "" : std::string(reinterpret_cast<const char *>(value), length);
    }
};

std::string GetStringArg(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

napi_value CreateString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value CreateNumber(napi_env env, uint32_t value)
{
    napi_value result = nullptr;
    napi_create_uint32(env, value, &result);
    return result;
}

napi_value CreateSizeNumber(napi_env env, size_t value)
{
    napi_value result = nullptr;
    napi_create_double(env, static_cast<double>(value), &result);
    return result;
}

void ThrowNativeError(napi_env env, char *error, const char *fallback)
{
    NativeString nativeError(error);
    const std::string message = nativeError.str().empty() ? fallback : nativeError.str();
    napi_throw_error(env, nullptr, message.c_str());
}

std::vector<uint32_t> ReadIds(napi_env env, napi_value value)
{
    bool isArray = false;
    napi_is_array(env, value, &isArray);
    if (!isArray) {
        return {};
    }

    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    std::vector<uint32_t> ids;
    ids.reserve(length);

    for (uint32_t index = 0; index < length; ++index) {
        napi_value element = nullptr;
        napi_get_element(env, value, index, &element);
        napi_valuetype type;
        napi_typeof(env, element, &type);
        if (type != napi_number) {
            continue;
        }

        double number = 0;
        napi_get_value_double(env, element, &number);
        if (number < 0 || number > static_cast<double>(UINT32_MAX)) {
            continue;
        }
        ids.push_back(static_cast<uint32_t>(number));
    }

    return ids;
}

napi_value GetNativeVersion(napi_env env, napi_callback_info)
{
    NativeString version(tavern_tokenizer_version());
    return CreateString(env, version.str());
}

napi_value ResolveModel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    NativeString resolved(tavern_tokenizer_resolve_model(model.c_str()));
    return CreateString(env, resolved.str());
}

napi_value CanUseModel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    napi_value result = nullptr;
    napi_get_boolean(env, tavern_tokenizer_can_use_model(model.c_str()), &result);
    return result;
}

napi_value Encode(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    const std::string text = argc > 1 ? GetStringArg(env, args[1]) : "";
    TokenizerEncodeResult native = tavern_tokenizer_encode(model.c_str(),
        reinterpret_cast<const uint8_t *>(text.data()), text.size());
    if (native.error != nullptr) {
        ThrowNativeError(env, native.error, "Tokenizer encode failed");
        return nullptr;
    }

    napi_value ids = nullptr;
    napi_create_array_with_length(env, native.ids_len, &ids);
    for (size_t index = 0; index < native.ids_len; ++index) {
        napi_set_element(env, ids, index, CreateNumber(env, native.ids_ptr[index]));
    }

    tavern_tokenizer_free_ids(native.ids_ptr, native.ids_len);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "ids", ids);
    napi_set_named_property(env, result, "count", CreateSizeNumber(env, native.ids_len));
    return result;
}

napi_value Decode(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    std::vector<uint32_t> ids = argc > 1 ? ReadIds(env, args[1]) : std::vector<uint32_t>();
    TokenizerStringResult native = tavern_tokenizer_decode(model.c_str(), ids.data(), ids.size());
    if (native.error != nullptr) {
        ThrowNativeError(env, native.error, "Tokenizer decode failed");
        return nullptr;
    }

    NativeBytes text(native.bytes_ptr, native.bytes_len);
    return CreateString(env, text.str());
}

napi_value Count(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    const std::string text = argc > 1 ? GetStringArg(env, args[1]) : "";
    TokenizerCountResult native = tavern_tokenizer_count(model.c_str(),
        reinterpret_cast<const uint8_t *>(text.data()), text.size());
    if (native.error != nullptr) {
        ThrowNativeError(env, native.error, "Tokenizer count failed");
        return nullptr;
    }

    return CreateSizeNumber(env, native.count);
}

napi_value CountMessages(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string model = argc > 0 ? GetStringArg(env, args[0]) : "";
    const std::string json = argc > 1 ? GetStringArg(env, args[1]) : "[]";
    TokenizerCountResult native = tavern_tokenizer_count_messages(model.c_str(),
        reinterpret_cast<const uint8_t *>(json.data()), json.size());
    if (native.error != nullptr) {
        ThrowNativeError(env, native.error, "Tokenizer message count failed");
        return nullptr;
    }

    return CreateSizeNumber(env, native.count);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "getNativeVersion", nullptr, GetNativeVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resolveModel", nullptr, ResolveModel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "canUseModel", nullptr, CanUseModel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "encode", nullptr, Encode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decode", nullptr, Decode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "count", nullptr, Count, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "countMessages", nullptr, CountMessages, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tavernTokenizerModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tavern_tokenizer",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTavernTokenizerModule(void)
{
    napi_module_register(&tavernTokenizerModule);
}

}
