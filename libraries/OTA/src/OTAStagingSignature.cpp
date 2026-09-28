// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "OTAStagingPlatform.h"

#include "mbedtls/ecdsa.h"
#include "mbedtls/pk.h"
#include "mbedtls/version.h"

#if MBEDTLS_VERSION_MAJOR >= 3
#define OTA_ECP_GROUP(key) ((key)->MBEDTLS_PRIVATE(grp))
#define OTA_ECP_PUBLIC_POINT(key) ((key)->MBEDTLS_PRIVATE(Q))
#else
#define OTA_ECP_GROUP(key) ((key)->grp)
#define OTA_ECP_PUBLIC_POINT(key) ((key)->Q)
#endif

int OTAStagingVerifySignature(
    const uint8_t *publicKeyDer,
    size_t publicKeyDerSize,
    const uint8_t digest[32],
    const uint8_t signature[64])
{
    int result = -1;
    mbedtls_pk_context key;
    mbedtls_mpi r;
    mbedtls_mpi s;
    mbedtls_ecp_keypair *ec = NULL;
    mbedtls_pk_init(&key);
    mbedtls_mpi_init(&r);
    mbedtls_mpi_init(&s);

    if (publicKeyDer == NULL || digest == NULL || signature == NULL ||
        mbedtls_pk_parse_public_key(&key, publicKeyDer, publicKeyDerSize) != 0 ||
        !mbedtls_pk_can_do(&key, MBEDTLS_PK_ECDSA))
    {
        result = -2;
        goto cleanup;
    }

    ec = mbedtls_pk_ec(key);
    if (ec == NULL ||
        OTA_ECP_GROUP(ec).id != MBEDTLS_ECP_DP_SECP256R1 ||
        mbedtls_ecp_check_pubkey(
            &OTA_ECP_GROUP(ec),
            &OTA_ECP_PUBLIC_POINT(ec)) != 0 ||
        mbedtls_mpi_read_binary(&r, signature, 32) != 0 ||
        mbedtls_mpi_read_binary(&s, signature + 32, 32) != 0)
    {
        result = -2;
        goto cleanup;
    }

    result = mbedtls_ecdsa_verify(
        &OTA_ECP_GROUP(ec),
        digest,
        32,
        &OTA_ECP_PUBLIC_POINT(ec),
        &r,
        &s);

cleanup:
    mbedtls_mpi_free(&s);
    mbedtls_mpi_free(&r);
    mbedtls_pk_free(&key);
    return result;
}

#undef OTA_ECP_GROUP
#undef OTA_ECP_PUBLIC_POINT
