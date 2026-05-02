# Resolve the in-tree mbedTLS targets for libgit2's FindmbedTLS.cmake.

set(MBEDTLS_FOUND TRUE)
set(MBEDTLS_INCLUDE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/mbedtls/include")
set(MBEDTLS_LIBRARY mbedtls)
set(MBEDX509_LIBRARY mbedx509)
set(MBEDCRYPTO_LIBRARY mbedcrypto)
set(MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto)

