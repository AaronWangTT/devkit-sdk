// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license.

#include "OTAStaging.h"
#include "OTAStagingPlatform.h"

#include <limits.h>
#include <string.h>

namespace
{
const size_t EnvelopePrefixSize = 64;
const size_t DescriptorOffset = 64;
const size_t VectorSize = 8;
const size_t PublicKeyDerSize = 91;
const uint32_t RamStartExclusive = 0x200001C4;
const uint32_t RamEndInclusive = 0x20040000;

const uint8_t PublicKeyPrefix[27] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48,
    0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48,
    0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04
};

struct Sha256Context
{
    uint32_t state[8];
    uint64_t bitCount;
    uint8_t block[64];
    size_t blockSize;
};

struct Session
{
    OTAStagingStatus status;
    size_t expectedPackageSize;
    uint32_t payloadSize;
    uint32_t writeOffset;
    uint8_t header[OTA_PACKAGE_HEADER_SIZE];
    uint8_t signature[OTA_PACKAGE_SIGNATURE_SIZE];
    uint8_t publicKey[PublicKeyDerSize];
    uint8_t vectors[VectorSize];
    size_t vectorsSize;
    bool authenticated;
    bool erased;
    Sha256Context payloadSha;
    uint16_t payloadCrc;
    OTAStagingMetadata metadata;
    OTAStagedImageInfo ready;
    OTAAdmissionCallback admission;
    OTACancellationCallback cancellation;
    void *callbackContext;
    OTAStagingPartition applicationPartition;
    OTAStagingPartition otaPartition;
};

Session session = {};
uint32_t nextGeneration = 1;
const OTAStagingPlatformOperations *platform = NULL;

uint32_t rotateRight(uint32_t value, uint32_t count)
{
    return (value >> count) | (value << (32 - count));
}

uint32_t readBigEndian32(const uint8_t *bytes)
{
    return (static_cast<uint32_t>(bytes[0]) << 24) |
           (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) |
           static_cast<uint32_t>(bytes[3]);
}

uint32_t readLittleEndian32(const uint8_t *bytes)
{
    return static_cast<uint32_t>(bytes[0]) |
           (static_cast<uint32_t>(bytes[1]) << 8) |
           (static_cast<uint32_t>(bytes[2]) << 16) |
           (static_cast<uint32_t>(bytes[3]) << 24);
}

uint16_t readLittleEndian16(const uint8_t *bytes)
{
    return static_cast<uint16_t>(
        static_cast<uint16_t>(bytes[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(bytes[1]) << 8));
}

void sha256Transform(Sha256Context *context, const uint8_t block[64])
{
    static const uint32_t constants[64] = {
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
        0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
        0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
        0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
        0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
        0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    };
    uint32_t words[64];
    for (size_t i = 0; i < 16; ++i)
    {
        words[i] = readBigEndian32(block + (i * 4));
    }
    for (size_t i = 16; i < 64; ++i)
    {
        uint32_t s0 = rotateRight(words[i - 15], 7) ^
                      rotateRight(words[i - 15], 18) ^ (words[i - 15] >> 3);
        uint32_t s1 = rotateRight(words[i - 2], 17) ^
                      rotateRight(words[i - 2], 19) ^ (words[i - 2] >> 10);
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    uint32_t a = context->state[0];
    uint32_t b = context->state[1];
    uint32_t c = context->state[2];
    uint32_t d = context->state[3];
    uint32_t e = context->state[4];
    uint32_t f = context->state[5];
    uint32_t g = context->state[6];
    uint32_t h = context->state[7];
    for (size_t i = 0; i < 64; ++i)
    {
        uint32_t sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        uint32_t choice = (e & f) ^ (~e & g);
        uint32_t temp1 = h + sum1 + choice + constants[i] + words[i];
        uint32_t sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

void sha256Init(Sha256Context *context)
{
    static const uint32_t initial[8] = {
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    };
    memcpy(context->state, initial, sizeof(initial));
    context->bitCount = 0;
    context->blockSize = 0;
}

void sha256Update(Sha256Context *context, const uint8_t *data, size_t size)
{
    while (size > 0)
    {
        size_t available = sizeof(context->block) - context->blockSize;
        size_t copied = size < available ? size : available;
        memcpy(context->block + context->blockSize, data, copied);
        context->blockSize += copied;
        context->bitCount += static_cast<uint64_t>(copied) * 8U;
        data += copied;
        size -= copied;
        if (context->blockSize == sizeof(context->block))
        {
            sha256Transform(context, context->block);
            context->blockSize = 0;
        }
    }
}

void sha256Finish(Sha256Context *context, uint8_t digest[32])
{
    uint64_t bitCount = context->bitCount;
    context->block[context->blockSize++] = 0x80;
    if (context->blockSize > 56)
    {
        memset(context->block + context->blockSize, 0, 64 - context->blockSize);
        sha256Transform(context, context->block);
        context->blockSize = 0;
    }
    memset(context->block + context->blockSize, 0, 56 - context->blockSize);
    for (size_t i = 0; i < 8; ++i)
    {
        context->block[63 - i] = static_cast<uint8_t>(bitCount >> (i * 8));
    }
    sha256Transform(context, context->block);
    for (size_t i = 0; i < 8; ++i)
    {
        digest[i * 4] = static_cast<uint8_t>(context->state[i] >> 24);
        digest[i * 4 + 1] = static_cast<uint8_t>(context->state[i] >> 16);
        digest[i * 4 + 2] = static_cast<uint8_t>(context->state[i] >> 8);
        digest[i * 4 + 3] = static_cast<uint8_t>(context->state[i]);
    }
}

void sha256(const uint8_t *data, size_t size, uint8_t digest[32])
{
    Sha256Context context;
    sha256Init(&context);
    sha256Update(&context, data, size);
    sha256Finish(&context, digest);
}

void crc16Update(uint16_t *crc, const uint8_t *data, size_t size)
{
    while (size-- > 0)
    {
        *crc ^= static_cast<uint16_t>(*data++) << 8;
        for (int bit = 0; bit < 8; ++bit)
        {
            *crc = (*crc & 0x8000U) != 0
                ? static_cast<uint16_t>((*crc << 1) ^ 0x1021U)
                : static_cast<uint16_t>(*crc << 1);
        }
    }
}

bool allZero(const uint8_t *data, size_t size)
{
    uint8_t value = 0;
    for (size_t i = 0; i < size; ++i)
    {
        value |= data[i];
    }
    return value == 0;
}

bool canonicalString(const uint8_t *field, size_t size, char *output)
{
    size_t terminator = 0;
    while (terminator < size && field[terminator] != 0)
    {
        ++terminator;
    }
    if (terminator == 0 || terminator == size ||
        !allZero(field + terminator, size - terminator))
    {
        return false;
    }
    memcpy(output, field, size);
    return true;
}

bool parseVersionComponent(const char *&cursor, uint16_t *value, char separator)
{
    if (*cursor < '0' || *cursor > '9' ||
        (*cursor == '0' && cursor[1] >= '0' && cursor[1] <= '9'))
    {
        return false;
    }
    uint32_t parsed = 0;
    do
    {
        parsed = parsed * 10U + static_cast<uint32_t>(*cursor - '0');
        if (parsed > UINT16_MAX)
        {
            return false;
        }
        ++cursor;
    } while (*cursor >= '0' && *cursor <= '9');
    if (*cursor != separator)
    {
        return false;
    }
    *value = static_cast<uint16_t>(parsed);
    if (separator != '\0')
    {
        ++cursor;
    }
    return true;
}

bool parseVersion(OTAStagingMetadata *metadata)
{
    const char *cursor = metadata->firmwareVersion;
    return parseVersionComponent(cursor, &metadata->versionMajor, '.') &&
           parseVersionComponent(cursor, &metadata->versionMinor, '.') &&
           parseVersionComponent(cursor, &metadata->versionPatch, '\0');
}

bool validSourceCommit(const uint8_t *source)
{
    for (size_t i = 0; i < 40; ++i)
    {
        if (!((source[i] >= '0' && source[i] <= '9') ||
              (source[i] >= 'a' && source[i] <= 'f')))
        {
            return false;
        }
    }
    return true;
}

bool cancelled()
{
    return session.cancellation != NULL &&
           session.cancellation(session.callbackContext) != 0;
}

OTAStagingError fail(OTAStagingError error)
{
    session.status.lastError = error;
    session.status.state = error == OTA_ERROR_CANCELLED
        ? OTA_STATE_CANCELLED
        : OTA_STATE_FAILED;
    session.ready.sessionGeneration = 0;
    return error;
}

bool elapsedExceeded(uint32_t started, uint32_t limit)
{
    return static_cast<uint32_t>(platform->timeMs() - started) > limit;
}

OTAStagingError validateHeader()
{
    const uint8_t *descriptor = session.header + DescriptorOffset;
    if (memcmp(session.header, "AZPKG001", 8) != 0 ||
        readLittleEndian16(session.header + 10) != OTA_PACKAGE_HEADER_SIZE ||
        readLittleEndian16(session.header + 14) != OTA_PACKAGE_SIGNATURE_SIZE ||
        !allZero(session.header + 52, 12))
    {
        return OTA_ERROR_PACKAGE_FORMAT;
    }
    if (readLittleEndian16(session.header + 8) != 1 ||
        readLittleEndian16(session.header + 12) != 1)
    {
        return OTA_ERROR_UNSUPPORTED;
    }

    session.payloadSize = readLittleEndian32(session.header + 16);
    if (session.payloadSize < OTA_IMAGE_DESCRIPTOR_OFFSET + OTA_IMAGE_DESCRIPTOR_SIZE ||
        session.payloadSize > session.otaPartition.length ||
        session.payloadSize > session.applicationPartition.length)
    {
        return OTA_ERROR_IMAGE_BOUNDS;
    }
    if (session.payloadSize > SIZE_MAX - OTA_PACKAGE_PAYLOAD_OFFSET ||
        static_cast<size_t>(session.payloadSize) + OTA_PACKAGE_PAYLOAD_OFFSET !=
            session.expectedPackageSize)
    {
        return OTA_ERROR_PACKAGE_SIZE;
    }

    if (memcmp(descriptor, "AZOTA001", 8) != 0 ||
        readLittleEndian16(descriptor + 10) != OTA_IMAGE_DESCRIPTOR_SIZE ||
        !allZero(descriptor + 196, 60))
    {
        return OTA_ERROR_PACKAGE_FORMAT;
    }
    if (readLittleEndian16(descriptor + 8) != 1 ||
        readLittleEndian32(descriptor + 12) != 1 ||
        readLittleEndian32(descriptor + 160) != 1)
    {
        return OTA_ERROR_UNSUPPORTED;
    }
    memset(&session.metadata, 0, sizeof(session.metadata));
    if (!canonicalString(descriptor + 16, 32, session.metadata.productId) ||
        !canonicalString(descriptor + 48, 32, session.metadata.boardId) ||
        !canonicalString(descriptor + 80, 32, session.metadata.firmwareVersion) ||
        !validSourceCommit(descriptor + 112))
    {
        return OTA_ERROR_PACKAGE_FORMAT;
    }
    memcpy(session.metadata.sourceCommit, descriptor + 112, 40);
    session.metadata.applicationAddress = readLittleEndian32(descriptor + 152);
    session.metadata.applicationCapacity = readLittleEndian32(descriptor + 156);
    session.metadata.payloadSize = session.payloadSize;
    memcpy(session.metadata.sha256, session.header + 20, OTA_SHA256_SIZE);
    if (!parseVersion(&session.metadata))
    {
        return OTA_ERROR_PACKAGE_FORMAT;
    }
    if ((session.metadata.applicationAddress & 0x1FFU) != 0 ||
        session.metadata.applicationAddress != session.applicationPartition.start ||
        session.metadata.applicationCapacity != session.applicationPartition.length ||
        session.applicationPartition.start >
            UINT32_MAX - session.applicationPartition.length ||
        session.otaPartition.start > UINT32_MAX - session.otaPartition.length)
    {
        return OTA_ERROR_IMAGE_BOUNDS;
    }

    uint8_t keyId[OTA_SHA256_SIZE];
    sha256(session.publicKey, sizeof(session.publicKey), keyId);
    if (memcmp(keyId, descriptor + 164, sizeof(keyId)) != 0)
    {
        return OTA_ERROR_KEY_MISMATCH;
    }

    uint8_t headerDigest[OTA_SHA256_SIZE];
    sha256(session.header, sizeof(session.header), headerDigest);
    if (cancelled())
    {
        return OTA_ERROR_CANCELLED;
    }
    uint32_t started = platform->timeMs();
    int verification = platform->verifySignature(
            session.publicKey,
            sizeof(session.publicKey),
            headerDigest,
            session.signature);
    if (verification == -2)
    {
        return OTA_ERROR_KEY_FORMAT;
    }
    if (verification != 0)
    {
        return OTA_ERROR_SIGNATURE;
    }
    if (elapsedExceeded(started, OTA_STAGING_SIGNATURE_MAX_MS))
    {
        return OTA_ERROR_SIGNATURE_TIMEOUT;
    }
    if (cancelled())
    {
        return OTA_ERROR_CANCELLED;
    }
    if (session.admission != NULL &&
        session.admission(&session.metadata, session.callbackContext) == 0)
    {
        return OTA_ERROR_ADMISSION_REJECTED;
    }
    session.authenticated = true;
    return OTA_OK;
}

OTAStagingError validateVectors()
{
    uint32_t stackPointer = readLittleEndian32(session.vectors);
    uint32_t resetVector = readLittleEndian32(session.vectors + 4);
    if ((stackPointer & 7U) != 0 ||
        stackPointer <= RamStartExclusive ||
        stackPointer > RamEndInclusive ||
        (resetVector & 1U) == 0)
    {
        return OTA_ERROR_VECTOR_TABLE;
    }
    uint32_t resetHandler = resetVector & ~1U;
    if (resetHandler < session.applicationPartition.start ||
        session.payloadSize < 2 ||
        resetHandler > UINT32_MAX - 2 ||
        session.applicationPartition.start > UINT32_MAX - session.payloadSize ||
        resetHandler + 2 > session.applicationPartition.start + session.payloadSize)
    {
        return OTA_ERROR_VECTOR_TABLE;
    }
    return OTA_OK;
}

OTAStagingError erasePayloadRange()
{
    uint32_t offset = 0;
    while (offset < session.payloadSize)
    {
        if (cancelled())
        {
            return OTA_ERROR_CANCELLED;
        }
        size_t size = session.payloadSize - offset;
        if (size > OTA_STAGING_ERASE_BLOCK_SIZE)
        {
            size = OTA_STAGING_ERASE_BLOCK_SIZE;
        }
        uint32_t started = platform->timeMs();
        if (platform->eraseOta(offset, size) != 0)
        {
            return OTA_ERROR_ERASE;
        }
        if (elapsedExceeded(started, OTA_STAGING_FLASH_OPERATION_MAX_MS))
        {
            return OTA_ERROR_ERASE_TIMEOUT;
        }
        offset += static_cast<uint32_t>(size);
    }
    session.erased = true;
    return OTA_OK;
}

OTAStagingError writePayload(const uint8_t *data, size_t size)
{
    while (size > 0)
    {
        if (cancelled())
        {
            return OTA_ERROR_CANCELLED;
        }
        size_t blockSize = size < OTA_STAGING_WRITE_BLOCK_SIZE
            ? size
            : OTA_STAGING_WRITE_BLOCK_SIZE;
        uint32_t start = session.writeOffset;
        uint32_t started = platform->timeMs();
        if (platform->writeOta(&session.writeOffset, data, blockSize) != 0)
        {
            return OTA_ERROR_WRITE;
        }
        if (session.writeOffset < start || session.writeOffset - start != blockSize)
        {
            return OTA_ERROR_SHORT_WRITE;
        }
        if (elapsedExceeded(started, OTA_STAGING_FLASH_OPERATION_MAX_MS))
        {
            return OTA_ERROR_WRITE_TIMEOUT;
        }
        sha256Update(&session.payloadSha, data, blockSize);
        crc16Update(&session.payloadCrc, data, blockSize);
        session.status.payloadWritten += blockSize;
        data += blockSize;
        size -= blockSize;
    }
    return OTA_OK;
}

OTAStagingError acceptPayload(const uint8_t *data, size_t size)
{
    if (!session.erased)
    {
        size_t needed = VectorSize - session.vectorsSize;
        size_t copied = size < needed ? size : needed;
        memcpy(session.vectors + session.vectorsSize, data, copied);
        session.vectorsSize += copied;
        data += copied;
        size -= copied;
        if (session.vectorsSize < VectorSize)
        {
            return OTA_OK;
        }
        OTAStagingError error = validateVectors();
        if (error != OTA_OK)
        {
            return error;
        }
        error = erasePayloadRange();
        if (error != OTA_OK)
        {
            return error;
        }
        error = writePayload(session.vectors, sizeof(session.vectors));
        if (error != OTA_OK)
        {
            return error;
        }
    }
    return writePayload(data, size);
}

bool validPublicKey(const uint8_t *key, size_t size)
{
    return key != NULL &&
           size == PublicKeyDerSize &&
           memcmp(key, PublicKeyPrefix, sizeof(PublicKeyPrefix)) == 0;
}

void initializeStatus(OTAStagingState state)
{
    session.status.state = state;
    session.status.lastError = OTA_OK;
    session.status.packageSize = session.expectedPackageSize;
    session.status.packageReceived = 0;
    session.status.payloadWritten = 0;
    session.status.payloadVerified = 0;
}

} // namespace

OTAStagingError OTAStagingBegin(
    size_t packageSize,
    const uint8_t *trustedPublicKeyDer,
    size_t trustedPublicKeyDerSize,
    OTAAdmissionCallback admissionCallback,
    OTACancellationCallback cancellationCallback,
    void *context)
{
    if (session.status.state == OTA_STATE_RECEIVING ||
        session.status.state == OTA_STATE_VERIFYING ||
        session.status.state == OTA_STATE_ACTIVATING)
    {
        return OTA_ERROR_BUSY;
    }
    if (!validPublicKey(trustedPublicKeyDer, trustedPublicKeyDerSize))
    {
        return OTA_ERROR_KEY_FORMAT;
    }
    if (packageSize < OTA_PACKAGE_PAYLOAD_OFFSET + 1 ||
        packageSize > UINT32_MAX)
    {
        return OTA_ERROR_PACKAGE_SIZE;
    }

    const OTAStagingPlatformOperations *selected =
        platform == NULL ? OTAStagingDefaultPlatform() : platform;
    OTAStagingPartition applicationPartition;
    OTAStagingPartition otaPartition;
    if (selected == NULL ||
        selected->getApplicationPartition == NULL ||
        selected->getOtaPartition == NULL ||
        selected->eraseOta == NULL ||
        selected->writeOta == NULL ||
        selected->readOta == NULL ||
        selected->timeMs == NULL ||
        selected->verifySignature == NULL ||
        selected->readBootTable == NULL ||
        selected->writeBootTable == NULL ||
        selected->readPersistedBootTable == NULL ||
        selected->getApplicationPartition(&applicationPartition) != 0 ||
        selected->getOtaPartition(&otaPartition) != 0 ||
        applicationPartition.length == 0 ||
        otaPartition.length == 0)
    {
        return OTA_ERROR_PARTITION;
    }

    memset(&session, 0, sizeof(session));
    platform = selected;
    session.expectedPackageSize = packageSize;
    session.applicationPartition = applicationPartition;
    session.otaPartition = otaPartition;
    session.admission = admissionCallback;
    session.cancellation = cancellationCallback;
    session.callbackContext = context;
    memcpy(session.publicKey, trustedPublicKeyDer, sizeof(session.publicKey));
    sha256Init(&session.payloadSha);
    initializeStatus(OTA_STATE_RECEIVING);
    return OTA_OK;
}

OTAStagingError OTAStagingWritePackage(const uint8_t *data, size_t size)
{
    if (session.status.state != OTA_STATE_RECEIVING)
    {
        return OTA_ERROR_INVALID_STATE;
    }
    if (size > 0 && data == NULL)
    {
        return fail(OTA_ERROR_INVALID_ARGUMENT);
    }
    if (size > session.expectedPackageSize - session.status.packageReceived)
    {
        return fail(OTA_ERROR_TRAILING_DATA);
    }
    if (cancelled())
    {
        return fail(OTA_ERROR_CANCELLED);
    }

    while (size > 0)
    {
        size_t offset = session.status.packageReceived;
        if (offset < OTA_PACKAGE_HEADER_SIZE)
        {
            size_t copied = OTA_PACKAGE_HEADER_SIZE - offset;
            if (copied > size)
            {
                copied = size;
            }
            memcpy(session.header + offset, data, copied);
            data += copied;
            size -= copied;
            session.status.packageReceived += copied;
            continue;
        }
        if (offset < OTA_PACKAGE_PAYLOAD_OFFSET)
        {
            size_t signatureOffset = offset - OTA_PACKAGE_HEADER_SIZE;
            size_t copied = OTA_PACKAGE_SIGNATURE_SIZE - signatureOffset;
            if (copied > size)
            {
                copied = size;
            }
            memcpy(session.signature + signatureOffset, data, copied);
            data += copied;
            size -= copied;
            session.status.packageReceived += copied;
            if (session.status.packageReceived == OTA_PACKAGE_PAYLOAD_OFFSET)
            {
                OTAStagingError error = validateHeader();
                if (error != OTA_OK)
                {
                    return fail(error);
                }
            }
            continue;
        }

        size_t payloadRemaining = session.payloadSize - session.status.payloadWritten;
        size_t accepted = size < payloadRemaining ? size : payloadRemaining;
        OTAStagingError error = acceptPayload(data, accepted);
        if (error != OTA_OK)
        {
            return fail(error);
        }
        data += accepted;
        size -= accepted;
        session.status.packageReceived += accepted;
    }
    return OTA_OK;
}

OTAStagingError OTAStagingFinish(OTAStagedImageInfo *stagedImageInfo)
{
    if (session.status.state != OTA_STATE_RECEIVING)
    {
        return OTA_ERROR_INVALID_STATE;
    }
    if (stagedImageInfo == NULL)
    {
        return fail(OTA_ERROR_INVALID_ARGUMENT);
    }
    if (session.status.packageReceived != session.expectedPackageSize ||
        !session.authenticated ||
        session.status.payloadWritten != session.payloadSize)
    {
        return fail(OTA_ERROR_INCOMPLETE);
    }
    if (cancelled())
    {
        return fail(OTA_ERROR_CANCELLED);
    }
    session.status.state = OTA_STATE_VERIFYING;

    uint8_t streamingDigest[OTA_SHA256_SIZE];
    Sha256Context streaming = session.payloadSha;
    sha256Finish(&streaming, streamingDigest);
    if (memcmp(streamingDigest, session.metadata.sha256, sizeof(streamingDigest)) != 0)
    {
        return fail(OTA_ERROR_HASH_MISMATCH);
    }

    Sha256Context readBackSha;
    sha256Init(&readBackSha);
    uint16_t readBackCrc = 0;
    uint8_t block[OTA_STAGING_READ_BACK_BLOCK_SIZE];
    uint8_t descriptor[OTA_IMAGE_DESCRIPTOR_SIZE];
    uint32_t offset = 0;
    while (offset < session.payloadSize)
    {
        if (cancelled())
        {
            return fail(OTA_ERROR_CANCELLED);
        }
        size_t size = session.payloadSize - offset;
        if (size > sizeof(block))
        {
            size = sizeof(block);
        }
        uint32_t started = platform->timeMs();
        uint32_t readOffset = offset;
        if (platform->readOta(&readOffset, block, size) != 0 ||
            readOffset < offset ||
            readOffset - offset != size)
        {
            return fail(OTA_ERROR_READ_BACK);
        }
        if (elapsedExceeded(started, OTA_STAGING_FLASH_OPERATION_MAX_MS))
        {
            return fail(OTA_ERROR_READ_BACK_TIMEOUT);
        }
        sha256Update(&readBackSha, block, size);
        crc16Update(&readBackCrc, block, size);
        if (offset <= OTA_IMAGE_DESCRIPTOR_OFFSET &&
            offset + size > OTA_IMAGE_DESCRIPTOR_OFFSET)
        {
            size_t start = OTA_IMAGE_DESCRIPTOR_OFFSET - offset;
            size_t copied = size - start;
            if (copied > sizeof(descriptor))
            {
                copied = sizeof(descriptor);
            }
            memcpy(descriptor, block + start, copied);
        }
        else if (offset > OTA_IMAGE_DESCRIPTOR_OFFSET &&
                 offset < OTA_IMAGE_DESCRIPTOR_OFFSET + sizeof(descriptor))
        {
            size_t destination = offset - OTA_IMAGE_DESCRIPTOR_OFFSET;
            size_t copied = size;
            if (copied > sizeof(descriptor) - destination)
            {
                copied = sizeof(descriptor) - destination;
            }
            memcpy(descriptor + destination, block, copied);
        }
        offset += static_cast<uint32_t>(size);
        session.status.payloadVerified = offset;
    }

    uint8_t readBackDigest[OTA_SHA256_SIZE];
    sha256Finish(&readBackSha, readBackDigest);
    if (memcmp(readBackDigest, session.metadata.sha256, sizeof(readBackDigest)) != 0)
    {
        return fail(OTA_ERROR_READ_BACK_HASH_MISMATCH);
    }
    if (readBackCrc != session.payloadCrc)
    {
        return fail(OTA_ERROR_READ_BACK_CRC_MISMATCH);
    }
    if (memcmp(
            descriptor,
            session.header + DescriptorOffset,
            sizeof(descriptor)) != 0)
    {
        return fail(OTA_ERROR_DESCRIPTOR_MISMATCH);
    }

    memset(&session.ready, 0, sizeof(session.ready));
    session.ready.sessionGeneration = nextGeneration++;
    if (nextGeneration == 0)
    {
        nextGeneration = 1;
    }
    session.ready.payloadSize = session.payloadSize;
    session.ready.crc16 = readBackCrc;
    memcpy(session.ready.sha256, readBackDigest, sizeof(readBackDigest));
    session.ready.metadata = session.metadata;
    *stagedImageInfo = session.ready;
    session.status.state = OTA_STATE_READY;
    session.status.lastError = OTA_OK;
    return OTA_OK;
}

OTAStagingError OTAStagingActivate(
    uint32_t sessionGeneration,
    const uint8_t expectedSha256[OTA_SHA256_SIZE])
{
    if (session.status.state != OTA_STATE_READY)
    {
        return OTA_ERROR_INVALID_STATE;
    }
    if (expectedSha256 == NULL ||
        sessionGeneration == 0 ||
        sessionGeneration != session.ready.sessionGeneration ||
        memcmp(expectedSha256, session.ready.sha256, OTA_SHA256_SIZE) != 0)
    {
        return OTA_ERROR_INVALID_ARGUMENT;
    }

    session.status.state = OTA_STATE_ACTIVATING;
    session.ready.sessionGeneration = 0;
    OTAStagingBootTable previous;
    OTAStagingBootTable candidate;
    OTAStagingBootTable persisted;
    uint32_t started = platform->timeMs();
    if (platform->readBootTable(&previous) != 0 ||
        elapsedExceeded(started, OTA_STAGING_ACTIVATION_MAX_MS))
    {
        return fail(OTA_ERROR_ACTIVATION);
    }
    memset(&candidate, 0, sizeof(candidate));
    candidate.startAddress = session.otaPartition.start;
    candidate.length = session.payloadSize;
    candidate.type = 'A';
    candidate.upgradeType = 'U';
    candidate.crc16 = session.ready.crc16;

    started = platform->timeMs();
    platform->writeBootTable(&candidate);
    bool candidateWriteInTime =
        !elapsedExceeded(started, OTA_STAGING_ACTIVATION_MAX_MS);
    started = platform->timeMs();
    bool candidateRead =
        platform->readPersistedBootTable(&persisted) == 0;
    bool candidateReadInTime =
        !elapsedExceeded(started, OTA_STAGING_ACTIVATION_MAX_MS);
    bool candidateVerified =
        candidateWriteInTime && candidateRead && candidateReadInTime &&
        memcmp(&persisted, &candidate, sizeof(candidate)) == 0;
    if (candidateVerified)
    {
        session.status.state = OTA_STATE_ACTIVATED;
        session.status.lastError = OTA_OK;
        return OTA_OK;
    }

    started = platform->timeMs();
    platform->writeBootTable(&previous);
    bool restoreWriteInTime =
        !elapsedExceeded(started, OTA_STAGING_ACTIVATION_MAX_MS);
    started = platform->timeMs();
    bool restoreRead =
        platform->readPersistedBootTable(&persisted) == 0;
    bool restoreReadInTime =
        !elapsedExceeded(started, OTA_STAGING_ACTIVATION_MAX_MS);
    bool restored =
        restoreWriteInTime && restoreRead && restoreReadInTime &&
        memcmp(&persisted, &previous, sizeof(previous)) == 0;
    return fail(restored ? OTA_ERROR_ACTIVATION : OTA_ERROR_ACTIVATION_UNCERTAIN);
}

OTAStagingError OTAStagingAbort(void)
{
    if (session.status.state != OTA_STATE_RECEIVING &&
        session.status.state != OTA_STATE_VERIFYING &&
        session.status.state != OTA_STATE_READY)
    {
        return OTA_ERROR_INVALID_STATE;
    }
    session.ready.sessionGeneration = 0;
    session.status.state = OTA_STATE_CANCELLED;
    session.status.lastError = OTA_ERROR_CANCELLED;
    return OTA_OK;
}

OTAStagingStatus OTAStagingGetStatus(void)
{
    return session.status;
}

const char *OTAStagingErrorName(OTAStagingError error)
{
    static const char *const names[] = {
        "OTA_OK",
        "OTA_ERROR_INVALID_ARGUMENT",
        "OTA_ERROR_INVALID_STATE",
        "OTA_ERROR_BUSY",
        "OTA_ERROR_PACKAGE_SIZE",
        "OTA_ERROR_PACKAGE_FORMAT",
        "OTA_ERROR_UNSUPPORTED",
        "OTA_ERROR_OVERFLOW",
        "OTA_ERROR_PARTITION",
        "OTA_ERROR_IMAGE_BOUNDS",
        "OTA_ERROR_KEY_FORMAT",
        "OTA_ERROR_KEY_MISMATCH",
        "OTA_ERROR_SIGNATURE",
        "OTA_ERROR_SIGNATURE_TIMEOUT",
        "OTA_ERROR_ADMISSION_REJECTED",
        "OTA_ERROR_CANCELLED",
        "OTA_ERROR_ERASE",
        "OTA_ERROR_ERASE_TIMEOUT",
        "OTA_ERROR_WRITE",
        "OTA_ERROR_SHORT_WRITE",
        "OTA_ERROR_WRITE_TIMEOUT",
        "OTA_ERROR_INCOMPLETE",
        "OTA_ERROR_TRAILING_DATA",
        "OTA_ERROR_HASH_MISMATCH",
        "OTA_ERROR_READ_BACK",
        "OTA_ERROR_READ_BACK_TIMEOUT",
        "OTA_ERROR_READ_BACK_HASH_MISMATCH",
        "OTA_ERROR_READ_BACK_CRC_MISMATCH",
        "OTA_ERROR_DESCRIPTOR_MISMATCH",
        "OTA_ERROR_VECTOR_TABLE",
        "OTA_ERROR_ACTIVATION",
        "OTA_ERROR_ACTIVATION_UNCERTAIN"
    };
    size_t index = static_cast<size_t>(error);
    return index < sizeof(names) / sizeof(names[0]) ? names[index] : "OTA_ERROR_UNKNOWN";
}

#ifdef OTA_STAGING_TEST
void OTAStagingSetPlatformForTest(const OTAStagingPlatformOperations *operations)
{
    platform = operations;
}

void OTAStagingResetForTest(void)
{
    memset(&session, 0, sizeof(session));
    platform = NULL;
    nextGeneration = 1;
}
#endif
