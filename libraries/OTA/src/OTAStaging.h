// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#ifndef __OTA_STAGING_H__
#define __OTA_STAGING_H__

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define OTA_PACKAGE_HEADER_SIZE 320U
#define OTA_PACKAGE_SIGNATURE_SIZE 64U
#define OTA_PACKAGE_PAYLOAD_OFFSET 384U
#define OTA_IMAGE_DESCRIPTOR_OFFSET 0x200U
#define OTA_IMAGE_DESCRIPTOR_SIZE 256U
#define OTA_SHA256_SIZE 32U
#define OTA_STAGING_ERASE_BLOCK_SIZE 4096U
#define OTA_STAGING_WRITE_BLOCK_SIZE 512U
#define OTA_STAGING_READ_BACK_BLOCK_SIZE 512U
#define OTA_STAGING_FLASH_OPERATION_MAX_MS 2000U
#define OTA_STAGING_SIGNATURE_MAX_MS 5000U
#define OTA_STAGING_ACTIVATION_MAX_MS 5000U

typedef enum
{
    OTA_STATE_IDLE = 0,
    OTA_STATE_RECEIVING,
    OTA_STATE_VERIFYING,
    OTA_STATE_READY,
    OTA_STATE_ACTIVATING,
    OTA_STATE_FAILED,
    OTA_STATE_CANCELLED,
    OTA_STATE_ACTIVATED
} OTAStagingState;

typedef enum
{
    OTA_OK = 0,
    OTA_ERROR_INVALID_ARGUMENT,
    OTA_ERROR_INVALID_STATE,
    OTA_ERROR_BUSY,
    OTA_ERROR_PACKAGE_SIZE,
    OTA_ERROR_PACKAGE_FORMAT,
    OTA_ERROR_UNSUPPORTED,
    OTA_ERROR_OVERFLOW,
    OTA_ERROR_PARTITION,
    OTA_ERROR_IMAGE_BOUNDS,
    OTA_ERROR_KEY_FORMAT,
    OTA_ERROR_KEY_MISMATCH,
    OTA_ERROR_SIGNATURE,
    OTA_ERROR_SIGNATURE_TIMEOUT,
    OTA_ERROR_ADMISSION_REJECTED,
    OTA_ERROR_CANCELLED,
    OTA_ERROR_ERASE,
    OTA_ERROR_ERASE_TIMEOUT,
    OTA_ERROR_WRITE,
    OTA_ERROR_SHORT_WRITE,
    OTA_ERROR_WRITE_TIMEOUT,
    OTA_ERROR_INCOMPLETE,
    OTA_ERROR_TRAILING_DATA,
    OTA_ERROR_HASH_MISMATCH,
    OTA_ERROR_READ_BACK,
    OTA_ERROR_READ_BACK_TIMEOUT,
    OTA_ERROR_READ_BACK_HASH_MISMATCH,
    OTA_ERROR_READ_BACK_CRC_MISMATCH,
    OTA_ERROR_DESCRIPTOR_MISMATCH,
    OTA_ERROR_VECTOR_TABLE,
    OTA_ERROR_ACTIVATION,
    OTA_ERROR_ACTIVATION_UNCERTAIN
} OTAStagingError;

typedef struct
{
    char productId[32];
    char boardId[32];
    char firmwareVersion[32];
    uint16_t versionMajor;
    uint16_t versionMinor;
    uint16_t versionPatch;
    char sourceCommit[41];
    uint32_t applicationAddress;
    uint32_t applicationCapacity;
    uint32_t payloadSize;
    uint8_t sha256[OTA_SHA256_SIZE];
} OTAStagingMetadata;

typedef struct
{
    uint32_t sessionGeneration;
    uint32_t payloadSize;
    uint16_t crc16;
    uint8_t sha256[OTA_SHA256_SIZE];
    OTAStagingMetadata metadata;
} OTAStagedImageInfo;

typedef struct
{
    OTAStagingState state;
    OTAStagingError lastError;
    size_t packageSize;
    size_t packageReceived;
    size_t payloadWritten;
    size_t payloadVerified;
} OTAStagingStatus;

typedef int (*OTAAdmissionCallback)(const OTAStagingMetadata *metadata, void *context);
typedef int (*OTACancellationCallback)(void *context);

/**
 * Begin an exclusively owned signed-package staging session.
 *
 * The public key must be a DER RFC 5480 SubjectPublicKeyInfo for secp256r1.
 * Header and signature validation, admission, and bounds checks complete before
 * the OTA partition is erased.
 */
OTAStagingError OTAStagingBegin(
    size_t packageSize,
    const uint8_t *trustedPublicKeyDer,
    size_t trustedPublicKeyDerSize,
    OTAAdmissionCallback admissionCallback,
    OTACancellationCallback cancellationCallback,
    void *context);

/** Stream complete package bytes in arbitrary chunk sizes. */
OTAStagingError OTAStagingWritePackage(const uint8_t *data, size_t size);

/** Verify the complete payload from Flash and publish a session-bound result. */
OTAStagingError OTAStagingFinish(OTAStagedImageInfo *stagedImageInfo);

/** Persist and verify boot metadata for the current Ready session. */
OTAStagingError OTAStagingActivate(
    uint32_t sessionGeneration,
    const uint8_t expectedSha256[OTA_SHA256_SIZE]);

/** Cancel and invalidate the current receiving or ready session. */
OTAStagingError OTAStagingAbort(void);

/** Return current state, error, and byte progress counters. */
OTAStagingStatus OTAStagingGetStatus(void);

/** Return a stable symbolic name for logging and diagnostics. */
const char *OTAStagingErrorName(OTAStagingError error);

#ifdef __cplusplus
}
#endif

#endif
