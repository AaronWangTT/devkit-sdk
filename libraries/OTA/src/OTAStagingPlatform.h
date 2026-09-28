// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#ifndef __OTA_STAGING_PLATFORM_H__
#define __OTA_STAGING_PLATFORM_H__

#include <stddef.h>
#include <stdint.h>

struct OTAStagingPartition
{
    uint32_t start;
    uint32_t length;
};

struct OTAStagingBootTable
{
    uint32_t startAddress;
    uint32_t length;
    uint8_t version[8];
    uint8_t type;
    uint8_t upgradeType;
    uint16_t crc16;
    uint8_t reserved[4];
};

struct OTAStagingPlatformOperations
{
    int (*getApplicationPartition)(OTAStagingPartition *partition);
    int (*getOtaPartition)(OTAStagingPartition *partition);
    int (*eraseOta)(uint32_t offset, size_t size);
    int (*writeOta)(uint32_t *offset, const uint8_t *data, size_t size);
    int (*readOta)(uint32_t *offset, uint8_t *data, size_t size);
    uint32_t (*timeMs)(void);
    // Returns 0 when valid, -2 for an invalid key, and another value for a bad signature.
    int (*verifySignature)(
        const uint8_t *publicKeyDer,
        size_t publicKeyDerSize,
        const uint8_t digest[32],
        const uint8_t signature[64]);
    int (*readBootTable)(OTAStagingBootTable *bootTable);
    int (*writeBootTable)(const OTAStagingBootTable *bootTable);
    int (*readPersistedBootTable)(OTAStagingBootTable *bootTable);
};

int OTAStagingVerifySignature(
    const uint8_t *publicKeyDer,
    size_t publicKeyDerSize,
    const uint8_t digest[32],
    const uint8_t signature[64]);

const OTAStagingPlatformOperations *OTAStagingDefaultPlatform(void);

#ifdef OTA_STAGING_TEST
void OTAStagingSetPlatformForTest(const OTAStagingPlatformOperations *operations);
void OTAStagingResetForTest(void);
#endif

#endif
