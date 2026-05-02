cmake_minimum_required(VERSION 3.5.0)
project(tavern_git)

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
