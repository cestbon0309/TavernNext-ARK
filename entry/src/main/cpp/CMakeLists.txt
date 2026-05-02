cmake_minimum_required(VERSION 3.5.0)
project(tavern_native)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../..)
set(CMAKE_SKIP_INSTALL_RULES TRUE CACHE BOOL "" FORCE)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
set(USE_HTTPS mbedTLS CACHE STRING "" FORCE)
set(USE_SSH OFF CACHE STRING "" FORCE)
set(USE_SHA1 CollisionDetection CACHE STRING "" FORCE)
set(USE_SHA256 mbedTLS CACHE STRING "" FORCE)
set(USE_HTTP_PARSER builtin CACHE STRING "" FORCE)
set(REGEX_BACKEND builtin CACHE STRING "" FORCE)
set(USE_BUNDLED_ZLIB Bundled CACHE STRING "" FORCE)
set(USE_NTLMCLIENT OFF CACHE BOOL "" FORCE)
set(SONAME OFF CACHE BOOL "" FORCE)
set(LIBGIT2_FILENAME git2_tavern CACHE STRING "" FORCE)

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

add_subdirectory("${REPO_ROOT}/third_party/mbedtls" "${CMAKE_CURRENT_BINARY_DIR}/mbedtls")
add_subdirectory("${REPO_ROOT}/third_party/libgit2" "${CMAKE_CURRENT_BINARY_DIR}/libgit2")

add_library(tavern_git SHARED git_native.cpp)
target_include_directories(tavern_git PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    "${REPO_ROOT}/third_party/libgit2/include"
    "${CMAKE_CURRENT_BINARY_DIR}/libgit2/include"
)
target_link_libraries(tavern_git PRIVATE libgit2package mbedtls mbedx509 mbedcrypto libace_napi.z.so)
target_compile_features(tavern_git PRIVATE cxx_std_17)

find_program(CARGO_EXECUTABLE cargo)
if(NOT CARGO_EXECUTABLE)
    message(FATAL_ERROR "cargo is required to build tavern_tokenizer native module")
endif()

if(OHOS_ARCH STREQUAL "x86_64")
    set(RUST_OHOS_TARGET "x86_64-unknown-linux-ohos")
    set(RUST_ENV_TARGET "x86_64_unknown_linux_ohos")
elseif(OHOS_ARCH STREQUAL "arm64-v8a")
    set(RUST_OHOS_TARGET "aarch64-unknown-linux-ohos")
    set(RUST_ENV_TARGET "aarch64_unknown_linux_ohos")
else()
    message(FATAL_ERROR "Unsupported OHOS_ARCH for tavern_tokenizer: ${OHOS_ARCH}")
endif()

set(RUST_CFLAGS "--target=${RUST_OHOS_TARGET} --sysroot=\"${CMAKE_SYSROOT}\"")
set(RUST_CXXFLAGS "${RUST_CFLAGS}")

set(TAVERN_TOKENIZER_FFI_DIR "${REPO_ROOT}/native/tavern_tokenizer_ffi")
set(TAVERN_TOKENIZER_FFI_LIB
    "${TAVERN_TOKENIZER_FFI_DIR}/target/${RUST_OHOS_TARGET}/release/libtavern_tokenizer_ffi.a")

add_custom_command(
    OUTPUT "${TAVERN_TOKENIZER_FFI_LIB}"
    COMMAND ${CMAKE_COMMAND} -E env
        "CC_${RUST_ENV_TARGET}=${CMAKE_C_COMPILER}"
        "CXX_${RUST_ENV_TARGET}=${CMAKE_CXX_COMPILER}"
        "AR_${RUST_ENV_TARGET}=${CMAKE_AR}"
        "CFLAGS_${RUST_ENV_TARGET}=${RUST_CFLAGS}"
        "CXXFLAGS_${RUST_ENV_TARGET}=${RUST_CXXFLAGS}"
        "CC_SHELL_ESCAPED_FLAGS=1"
        ${CARGO_EXECUTABLE} build --manifest-path "${TAVERN_TOKENIZER_FFI_DIR}/Cargo.toml"
        --target ${RUST_OHOS_TARGET} --release
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS
        "${TAVERN_TOKENIZER_FFI_DIR}/Cargo.toml"
        "${TAVERN_TOKENIZER_FFI_DIR}/Cargo.lock"
        "${TAVERN_TOKENIZER_FFI_DIR}/src/lib.rs"
        "${TAVERN_TOKENIZER_FFI_DIR}/resources/tokenizers/claude.json.gz"
        "${TAVERN_TOKENIZER_FFI_DIR}/resources/tokenizers/deepseek.json.gz"
        "${TAVERN_TOKENIZER_FFI_DIR}/resources/tokenizers/gemma.model.gz"
        "${REPO_ROOT}/third_party/miktik/Cargo.toml"
    COMMENT "Building Rust MikTik tokenizer bridge for ${RUST_OHOS_TARGET}"
    VERBATIM
)

add_custom_target(tavern_tokenizer_ffi DEPENDS "${TAVERN_TOKENIZER_FFI_LIB}")

add_library(tavern_tokenizer SHARED tokenizer_native.cpp)
add_dependencies(tavern_tokenizer tavern_tokenizer_ffi)
target_link_libraries(tavern_tokenizer PRIVATE "${TAVERN_TOKENIZER_FFI_LIB}" libace_napi.z.so)
target_compile_features(tavern_tokenizer PRIVATE cxx_std_17)
