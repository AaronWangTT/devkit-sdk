// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "OTAStagingPlatform.h"

#include <string.h>

#include "mico.h"
#include "mbedtls/ecdsa.h"
#include "mbedtls/pk.h"
#include "mbedtls/sha256.h"

static_assert(
    sizeof(OTAStagingBootTable) == sizeof(boot_table_t),
    "OTA boot table must match the MiCO bootloader ABI.");

static int getPartition(mico_partition_t id, OTAStagingPartition *partition)
{
    mico_logic_partition_t *info = MicoFlashGetInfo(id);
    if (info == NULL || partition == NULL)
    {
        return -1;
    }
    partition->start = info->partition_start_addr;
    partition->length = info->partition_length;
    return 0;
}

static int getApplicationPartition(OTAStagingPartition *partition)
{
    return getPartition(MICO_PARTITION_APPLICATION, partition);
}

static int getOtaPartition(OTAStagingPartition *partition)
{
    return getPartition(MICO_PARTITION_OTA_TEMP, partition);
}

static int eraseOta(uint32_t offset, size_t size)
{
    return MicoFlashErase(MICO_PARTITION_OTA_TEMP, offset, static_cast<uint32_t>(size));
}

static int writeOta(uint32_t *offset, const uint8_t *data, size_t size)
{
    volatile uint32_t current = *offset;
    int result = MicoFlashWrite(
        MICO_PARTITION_OTA_TEMP,
        &current,
        const_cast<uint8_t *>(data),
        static_cast<uint32_t>(size));
    *offset = current;
    return result;
}

static int readOta(uint32_t *offset, uint8_t *data, size_t size)
{
    volatile uint32_t current = *offset;
    int result = MicoFlashRead(
        MICO_PARTITION_OTA_TEMP,
        &current,
        data,
        static_cast<uint32_t>(size));
    *offset = current;
    return result;
}

static uint32_t timeMs(void)
{
    return mico_rtos_get_time();
}

static int verifySignature(
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

    if (mbedtls_pk_parse_public_key(&key, publicKeyDer, publicKeyDerSize) != 0 ||
        !mbedtls_pk_can_do(&key, MBEDTLS_PK_ECDSA))
    {
        result = -2;
        goto cleanup;
    }

    ec = mbedtls_pk_ec(key);
    if (ec == NULL || ec->grp.id != MBEDTLS_ECP_DP_SECP256R1 ||
        mbedtls_ecp_check_pubkey(&ec->grp, &ec->Q) != 0 ||
        mbedtls_mpi_read_binary(&r, signature, 32) != 0 ||
        mbedtls_mpi_read_binary(&s, signature + 32, 32) != 0)
    {
        result = -2;
        goto cleanup;
    }

    result = mbedtls_ecdsa_verify(&ec->grp, digest, 32, &ec->Q, &r, &s);

cleanup:
    mbedtls_mpi_free(&s);
    mbedtls_mpi_free(&r);
    mbedtls_pk_free(&key);
    return result;
}

static int readPersistedBootTable(OTAStagingBootTable *bootTable);

static int readBootTable(OTAStagingBootTable *bootTable)
{
    return readPersistedBootTable(bootTable);
}

static int writeBootTable(const OTAStagingBootTable *bootTable)
{
    return mico_system_para_write(
        bootTable,
        PARA_BOOT_TABLE_SECTION,
        0,
        sizeof(*bootTable));
}

static int readPersistedBootTable(OTAStagingBootTable *bootTable)
{
    OTAStagingBootTable primary;
    OTAStagingBootTable backup;
    if (bootTable == NULL)
    {
        return -1;
    }
    uint32_t offset = 0;
    if (MicoFlashRead(
            MICO_PARTITION_PARAMETER_1,
            &offset,
            reinterpret_cast<uint8_t *>(&primary),
            sizeof(primary)) != kNoErr)
    {
        return -1;
    }
    offset = 0;
    if (MicoFlashRead(
            MICO_PARTITION_PARAMETER_2,
            &offset,
            reinterpret_cast<uint8_t *>(&backup),
            sizeof(backup)) != kNoErr ||
        memcmp(&primary, &backup, sizeof(primary)) != 0)
    {
        return -1;
    }
    *bootTable = primary;
    return 0;
}

const OTAStagingPlatformOperations *OTAStagingDefaultPlatform(void)
{
    static const OTAStagingPlatformOperations operations = {
        getApplicationPartition,
        getOtaPartition,
        eraseOta,
        writeOta,
        readOta,
        timeMs,
        verifySignature,
        readBootTable,
        writeBootTable,
        readPersistedBootTable
    };
    return &operations;
}
