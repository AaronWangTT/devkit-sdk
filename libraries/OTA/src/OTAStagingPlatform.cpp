// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "OTAStagingPlatform.h"

#include <string.h>

#include "mico.h"

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

static int readPersistedBootTable(OTAStagingBootTable *bootTable);

static int readBootTable(OTAStagingBootTable *bootTable)
{
    mico_Context_t *context = mico_system_context_get();
    if (bootTable == NULL || context == NULL)
    {
        return -1;
    }
    memcpy(bootTable, &context->bootTable, sizeof(*bootTable));
    return 0;
}

static int writeBootTable(const OTAStagingBootTable *bootTable)
{
    mico_Context_t *context = mico_system_context_get();
    if (bootTable == NULL || context == NULL)
    {
        return -1;
    }
    memcpy(&context->bootTable, bootTable, sizeof(*bootTable));
    return mico_system_context_update(context);
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
        OTAStagingVerifySignature,
        readBootTable,
        writeBootTable,
        readPersistedBootTable
    };
    return &operations;
}
