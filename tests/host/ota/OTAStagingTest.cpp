#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define OTA_STAGING_TEST
#include "../../../libraries/OTA/src/OTAStaging.cpp"

namespace
{
const uint32_t ApplicationStart = 0x0800C000;
const uint32_t PartitionSize = 0x000F4000;
const uint32_t OtaStart = 0x00070000;
const size_t PayloadSize = OTA_IMAGE_DESCRIPTOR_OFFSET + OTA_IMAGE_DESCRIPTOR_SIZE;

struct FakePlatform
{
    std::vector<uint8_t> flash;
    OTAStagingBootTable boot;
    OTAStagingBootTable persisted;
    OTAStagingPartition applicationPartition;
    OTAStagingPartition otaPartition;
    uint32_t now;
    int eraseCalls;
    int writeCalls;
    int readCalls;
    int bootWriteCalls;
    int persistedReadCalls;
    size_t maximumWriteSize;
    int failEraseCall;
    int failWriteCall;
    int shortWriteCall;
    int failReadCall;
    int corruptReadCall;
    int failBootWriteCall;
    int failPersistedReadCall;
    int mismatchPersistedReadCall;
    bool persistBeforeBootWriteFailure;
    bool failBootRead;
    bool signatureAccepted;
    bool acceptAnySignature;
    bool cancelRequested;
    bool admissionAccepted;
    uint32_t eraseDuration;
    uint32_t writeDuration;
    uint32_t readDuration;
    uint32_t signatureDuration;
    uint32_t bootWriteDuration;
    uint32_t bootReadDuration;

    void reset()
    {
        flash.assign(PartitionSize, 0xA5);
        memset(&boot, 0x3C, sizeof(boot));
        persisted = boot;
        applicationPartition.start = ApplicationStart;
        applicationPartition.length = PartitionSize;
        otaPartition.start = OtaStart;
        otaPartition.length = PartitionSize;
        now = 0;
        eraseCalls = 0;
        writeCalls = 0;
        readCalls = 0;
        bootWriteCalls = 0;
        persistedReadCalls = 0;
        maximumWriteSize = 0;
        failEraseCall = 0;
        failWriteCall = 0;
        shortWriteCall = 0;
        failReadCall = 0;
        corruptReadCall = 0;
        failBootWriteCall = 0;
        failPersistedReadCall = 0;
        mismatchPersistedReadCall = 0;
        persistBeforeBootWriteFailure = false;
        failBootRead = false;
        signatureAccepted = true;
        acceptAnySignature = false;
        cancelRequested = false;
        admissionAccepted = true;
        eraseDuration = 1;
        writeDuration = 1;
        readDuration = 1;
        signatureDuration = 1;
        bootWriteDuration = 1;
        bootReadDuration = 1;
    }
};

FakePlatform fake;
int failures = 0;

void check(bool condition, const char *expression, int line)
{
    if (!condition)
    {
        std::fprintf(stderr, "line %d: check failed: %s\n", line, expression);
        ++failures;
    }
}

#define CHECK(expression) check((expression), #expression, __LINE__)

int getApplicationPartition(OTAStagingPartition *partition)
{
    *partition = fake.applicationPartition;
    return 0;
}

int getOtaPartition(OTAStagingPartition *partition)
{
    *partition = fake.otaPartition;
    return 0;
}

int eraseOta(uint32_t offset, size_t size)
{
    ++fake.eraseCalls;
    fake.now += fake.eraseDuration;
    if (fake.failEraseCall == fake.eraseCalls)
    {
        return -1;
    }
    std::fill(fake.flash.begin() + offset, fake.flash.begin() + offset + size, 0xFF);
    return 0;
}

int writeOta(uint32_t *offset, const uint8_t *data, size_t size)
{
    ++fake.writeCalls;
    fake.maximumWriteSize = std::max(fake.maximumWriteSize, size);
    fake.now += fake.writeDuration;
    if (fake.failWriteCall == fake.writeCalls)
    {
        return -1;
    }
    size_t written = fake.shortWriteCall == fake.writeCalls && size > 0 ? size - 1 : size;
    memcpy(&fake.flash[*offset], data, written);
    *offset += static_cast<uint32_t>(written);
    return 0;
}

int readOta(uint32_t *offset, uint8_t *data, size_t size)
{
    ++fake.readCalls;
    fake.now += fake.readDuration;
    if (fake.failReadCall == fake.readCalls)
    {
        return -1;
    }
    memcpy(data, &fake.flash[*offset], size);
    if (fake.corruptReadCall == fake.readCalls && size > 0)
    {
        data[0] ^= 1;
    }
    *offset += static_cast<uint32_t>(size);
    return 0;
}

uint32_t timeMs()
{
    return fake.now;
}

int verifySignature(
    const uint8_t *,
    size_t,
    const uint8_t digest[32],
    const uint8_t signature[64])
{
    fake.now += fake.signatureDuration;
    uint8_t zero[32] = {};
    return fake.signatureAccepted &&
           memcmp(digest, zero, sizeof(zero)) != 0 &&
           (fake.acceptAnySignature || signature[0] == 0x5A)
        ? 0
        : -1;
}

int readBootTable(OTAStagingBootTable *boot)
{
    if (fake.failBootRead)
    {
        return -1;
    }
    *boot = fake.boot;
    return 0;
}

int writeBootTable(const OTAStagingBootTable *boot)
{
    ++fake.bootWriteCalls;
    fake.now += fake.bootWriteDuration;
    bool fail = fake.failBootWriteCall == fake.bootWriteCalls;
    if (fail && !fake.persistBeforeBootWriteFailure)
    {
        return -1;
    }
    fake.boot = *boot;
    fake.persisted = *boot;
    return fail ? -1 : 0;
}

int readPersistedBootTable(OTAStagingBootTable *boot)
{
    ++fake.persistedReadCalls;
    fake.now += fake.bootReadDuration;
    if (fake.failPersistedReadCall == fake.persistedReadCalls)
    {
        return -1;
    }
    *boot = fake.persisted;
    if (fake.mismatchPersistedReadCall == fake.persistedReadCalls)
    {
        ++boot->length;
    }
    return 0;
}

const OTAStagingPlatformOperations operations = {
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

void write16(std::vector<uint8_t> &data, size_t offset, uint16_t value)
{
    data[offset] = static_cast<uint8_t>(value);
    data[offset + 1] = static_cast<uint8_t>(value >> 8);
}

void write32(std::vector<uint8_t> &data, size_t offset, uint32_t value)
{
    data[offset] = static_cast<uint8_t>(value);
    data[offset + 1] = static_cast<uint8_t>(value >> 8);
    data[offset + 2] = static_cast<uint8_t>(value >> 16);
    data[offset + 3] = static_cast<uint8_t>(value >> 24);
}

void writeString(std::vector<uint8_t> &data, size_t offset, size_t size, const char *value)
{
    memset(&data[offset], 0, size);
    memcpy(&data[offset], value, strlen(value));
}

std::vector<uint8_t> publicKey()
{
    std::vector<uint8_t> key(PublicKeyDerSize);
    memcpy(key.data(), PublicKeyPrefix, sizeof(PublicKeyPrefix));
    for (size_t i = sizeof(PublicKeyPrefix); i < key.size(); ++i)
    {
        key[i] = static_cast<uint8_t>(i + 1);
    }
    return key;
}

std::vector<uint8_t> validPackage()
{
    std::vector<uint8_t> package(OTA_PACKAGE_PAYLOAD_OFFSET + PayloadSize, 0);
    std::vector<uint8_t> key = publicKey();
    uint8_t *descriptor = package.data() + 64;
    uint8_t *payload = package.data() + OTA_PACKAGE_PAYLOAD_OFFSET;

    memcpy(descriptor, "AZOTA001", 8);
    write16(package, 64 + 8, 1);
    write16(package, 64 + 10, OTA_IMAGE_DESCRIPTOR_SIZE);
    write32(package, 64 + 12, 1);
    writeString(package, 64 + 16, 32, "HomeTemperature");
    writeString(package, 64 + 48, 32, "AZ3166");
    writeString(package, 64 + 80, 32, "3.1.4");
    memcpy(descriptor + 112, "0123456789abcdef0123456789abcdef01234567", 40);
    write32(package, 64 + 152, ApplicationStart);
    write32(package, 64 + 156, PartitionSize);
    write32(package, 64 + 160, 1);
    sha256(key.data(), key.size(), descriptor + 164);

    write32(package, OTA_PACKAGE_PAYLOAD_OFFSET, 0x20040000);
    write32(package, OTA_PACKAGE_PAYLOAD_OFFSET + 4, ApplicationStart + 0x101);
    for (size_t i = 8; i < PayloadSize; ++i)
    {
        payload[i] = static_cast<uint8_t>((i * 17U) & 0xFFU);
    }
    memcpy(
        payload + OTA_IMAGE_DESCRIPTOR_OFFSET,
        descriptor,
        OTA_IMAGE_DESCRIPTOR_SIZE);

    memcpy(package.data(), "AZPKG001", 8);
    write16(package, 8, 1);
    write16(package, 10, OTA_PACKAGE_HEADER_SIZE);
    write16(package, 12, 1);
    write16(package, 14, OTA_PACKAGE_SIGNATURE_SIZE);
    write32(package, 16, PayloadSize);
    sha256(payload, PayloadSize, package.data() + 20);
    package[OTA_PACKAGE_HEADER_SIZE] = 0x5A;
    return package;
}

int admit(const OTAStagingMetadata *metadata, void *)
{
    return fake.admissionAccepted &&
           strcmp(metadata->boardId, "AZ3166") == 0 &&
           metadata->versionMajor == 3 &&
           metadata->versionMinor == 1 &&
           metadata->versionPatch == 4;
}

int cancel(void *)
{
    return fake.cancelRequested;
}

void reset()
{
    OTAStagingResetForTest();
    fake.reset();
    OTAStagingSetPlatformForTest(&operations);
}

OTAStagingError beginPackage(const std::vector<uint8_t> &package)
{
    std::vector<uint8_t> key = publicKey();
    return OTAStagingBegin(package.size(), key.data(), key.size(), admit, cancel, NULL);
}

OTAStagingError stream(
    const std::vector<uint8_t> &package,
    size_t chunkSize = static_cast<size_t>(-1))
{
    for (size_t offset = 0; offset < package.size();)
    {
        size_t size = std::min(chunkSize, package.size() - offset);
        OTAStagingError error = OTAStagingWritePackage(package.data() + offset, size);
        if (error != OTA_OK)
        {
            return error;
        }
        offset += size;
    }
    return OTA_OK;
}

OTAStagedImageInfo stage(const std::vector<uint8_t> &package, size_t chunkSize)
{
    OTAStagedImageInfo info = {};
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package, chunkSize) == OTA_OK);
    CHECK(OTAStagingFinish(&info) == OTA_OK);
    return info;
}

std::vector<uint8_t> readFile(const char *path)
{
    std::FILE *file = std::fopen(path, "rb");
    CHECK(file != NULL);
    if (file == NULL)
    {
        return {};
    }
    std::fseek(file, 0, SEEK_END);
    long length = std::ftell(file);
    std::rewind(file);
    CHECK(length >= 0);
    std::vector<uint8_t> data(length > 0 ? static_cast<size_t>(length) : 0);
    CHECK(data.empty() || std::fread(data.data(), 1, data.size(), file) == data.size());
    std::fclose(file);
    return data;
}

void testHostToolingGoldenPackage(const char *packagePath, const char *publicKeyPath)
{
    static const uint8_t expectedDigest[32] = {
        0x5E, 0x8C, 0x1D, 0x75, 0x69, 0xB8, 0xA3, 0x38,
        0x34, 0x30, 0x63, 0xBA, 0xB9, 0xC7, 0xE1, 0x45,
        0x50, 0xB8, 0xEE, 0xC0, 0x77, 0xCF, 0x28, 0x5C,
        0x65, 0x37, 0x21, 0xCA, 0x0F, 0x0A, 0x4B, 0x5E
    };
    std::vector<uint8_t> package = readFile(packagePath);
    std::vector<uint8_t> key = readFile(publicKeyPath);
    reset();
    fake.acceptAnySignature = true;
    OTAStagedImageInfo info = {};
    CHECK(package.size() == 1408);
    CHECK(key.size() == 91);
    CHECK(OTAStagingBegin(
              package.size(), key.data(), key.size(), admit, cancel, NULL) == OTA_OK);
    CHECK(stream(package, 37) == OTA_OK);
    CHECK(OTAStagingFinish(&info) == OTA_OK);
    CHECK(strcmp(info.metadata.productId, "AZ3166GoldenVector") == 0);
    CHECK(strcmp(info.metadata.boardId, "MXCHIP_AZ3166") == 0);
    CHECK(strcmp(info.metadata.firmwareVersion, "1.2.3") == 0);
    CHECK(info.payloadSize == 1024);
    CHECK(memcmp(info.sha256, expectedDigest, sizeof(expectedDigest)) == 0);
}

void testSha256KnownAnswer()
{
    static const uint8_t expected[32] = {
        0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
        0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
        0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
        0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD
    };
    uint8_t actual[32];
    sha256(reinterpret_cast<const uint8_t *>("abc"), 3, actual);
    CHECK(memcmp(actual, expected, sizeof(expected)) == 0);
    uint16_t crc = 0;
    crc16Update(&crc, reinterpret_cast<const uint8_t *>("123456789"), 9);
    CHECK(crc == 0x31C3);
}

#ifdef OTA_STAGING_SIGNATURE_KAT
void testProductionSignatureAdapter()
{
    static const uint8_t publicKeyDer[91] = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02,
        0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00, 0x04, 0x6B, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47, 0xF8,
        0xBC, 0xE6, 0xE5, 0x63, 0xA4, 0x40, 0xF2, 0x77, 0x03, 0x7D, 0x81, 0x2D,
        0xEB, 0x33, 0xA0, 0xF4, 0xA1, 0x39, 0x45, 0xD8, 0x98, 0xC2, 0x96, 0x4F,
        0xE3, 0x42, 0xE2, 0xFE, 0x1A, 0x7F, 0x9B, 0x8E, 0xE7, 0xEB, 0x4A, 0x7C,
        0x0F, 0x9E, 0x16, 0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE, 0xCB,
        0xB6, 0x40, 0x68, 0x37, 0xBF, 0x51, 0xF5
    };
    static const uint8_t digest[32] = {
        0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
        0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
        0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
        0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD
    };
    static const uint8_t signature[64] = {
        0x0A, 0x0A, 0xE3, 0x0C, 0x0A, 0xBA, 0x64, 0x10,
        0xA9, 0x20, 0xFC, 0x71, 0xB7, 0x1C, 0x0C, 0x04,
        0x90, 0xA5, 0xB9, 0xAD, 0xE5, 0x8B, 0x8F, 0x29,
        0xF3, 0x5C, 0xDD, 0x27, 0x62, 0x1A, 0x29, 0x44,
        0x46, 0x06, 0x68, 0x04, 0x1B, 0x71, 0x16, 0x6E,
        0x13, 0xBD, 0x8D, 0x09, 0xE9, 0xB4, 0x89, 0x81,
        0x59, 0xA2, 0xC0, 0xE6, 0xBB, 0x18, 0xE7, 0x86,
        0x90, 0xDC, 0xE5, 0xA7, 0x19, 0x97, 0x0B, 0x4D
    };
    static const uint8_t otherPublicKeyDer[91] = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02,
        0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00, 0x04, 0x7C, 0xF2, 0x7B, 0x18, 0x8D, 0x03, 0x4F, 0x7E, 0x8A,
        0x52, 0x38, 0x03, 0x04, 0xB5, 0x1A, 0xC3, 0xC0, 0x89, 0x69, 0xE2, 0x77,
        0xF2, 0x1B, 0x35, 0xA6, 0x0B, 0x48, 0xFC, 0x47, 0x66, 0x99, 0x78, 0x07,
        0x77, 0x55, 0x10, 0xDB, 0x8E, 0xD0, 0x40, 0x29, 0x3D, 0x9A, 0xC6, 0x9F,
        0x74, 0x30, 0xDB, 0xBA, 0x7D, 0xAD, 0xE6, 0x3C, 0xE9, 0x82, 0x29, 0x9E,
        0x04, 0xB7, 0x9D, 0x22, 0x78, 0x73, 0xD1
    };

    CHECK(OTAStagingVerifySignature(
              publicKeyDer,
              sizeof(publicKeyDer),
              digest,
              signature) == 0);

    uint8_t tamperedSignature[sizeof(signature)];
    memcpy(tamperedSignature, signature, sizeof(signature));
    tamperedSignature[63] ^= 1;
    CHECK(OTAStagingVerifySignature(
              publicKeyDer,
              sizeof(publicKeyDer),
              digest,
              tamperedSignature) != 0);

    uint8_t tamperedDigest[sizeof(digest)];
    memcpy(tamperedDigest, digest, sizeof(digest));
    tamperedDigest[0] ^= 1;
    CHECK(OTAStagingVerifySignature(
              publicKeyDer,
              sizeof(publicKeyDer),
              tamperedDigest,
              signature) != 0);

    CHECK(OTAStagingVerifySignature(
              otherPublicKeyDer,
              sizeof(otherPublicKeyDer),
              digest,
              signature) != 0);

    uint8_t malformedKey[sizeof(publicKeyDer)];
    memcpy(malformedKey, publicKeyDer, sizeof(publicKeyDer));
    malformedKey[0] ^= 1;
    CHECK(OTAStagingVerifySignature(
              malformedKey,
              sizeof(malformedKey),
              digest,
              signature) == -2);

    CHECK(OTAStagingVerifySignature(NULL, 0, digest, signature) == -2);
}
#endif

void testArbitraryChunkingAndActivation()
{
    for (size_t chunk : {
             size_t(1),
             size_t(7),
             size_t(320),
             size_t(383),
             size_t(511),
             size_t(OTA_PACKAGE_PAYLOAD_OFFSET + PayloadSize)})
    {
        reset();
        std::vector<uint8_t> package = validPackage();
        OTAStagedImageInfo info = stage(package, chunk);
        CHECK(info.sessionGeneration != 0);
        CHECK(info.payloadSize == PayloadSize);
        CHECK(fake.eraseCalls > 0);
        CHECK(fake.maximumWriteSize <= OTA_STAGING_WRITE_BLOCK_SIZE);
        CHECK(memcmp(fake.flash.data(), package.data() + OTA_PACKAGE_PAYLOAD_OFFSET, PayloadSize) == 0);
        CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_OK);
        CHECK(fake.persisted.startAddress == OtaStart);
        CHECK(fake.persisted.length == PayloadSize);
        CHECK(fake.persisted.crc16 == info.crc16);
        CHECK(fake.persisted.type == 'A');
        CHECK(fake.persisted.upgradeType == 'U');
        CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_ERROR_INVALID_STATE);
    }
}

void testPreEraseRejections()
{
    std::vector<uint8_t> package = validPackage();
    const size_t offsets[] = {0, 8, 10, 12, 14, 52, 64, 64 + 8, 64 + 10, 64 + 12, 64 + 196};
    for (size_t offset : offsets)
    {
        reset();
        std::vector<uint8_t> invalid = package;
        invalid[offset] ^= 1;
        CHECK(beginPackage(invalid) == OTA_OK);
        CHECK(stream(invalid) != OTA_OK);
        CHECK(fake.eraseCalls == 0);
    }

    reset();
    fake.signatureAccepted = false;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_SIGNATURE);
    CHECK(fake.eraseCalls == 0);

    reset();
    fake.admissionAccepted = false;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_ADMISSION_REJECTED);
    CHECK(fake.eraseCalls == 0);

    reset();
    std::vector<uint8_t> badKey = publicKey();
    badKey[0] ^= 1;
    CHECK(OTAStagingBegin(package.size(), badKey.data(), badKey.size(), admit, cancel, NULL) ==
          OTA_ERROR_KEY_FORMAT);
    CHECK(fake.eraseCalls == 0);
}

void testBoundsVectorsAndStreamErrors()
{
    std::vector<uint8_t> package = validPackage();

    reset();
    write32(package, 16, PartitionSize + 1);
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_IMAGE_BOUNDS);
    CHECK(fake.eraseCalls == 0);

    package = validPackage();
    reset();
    fake.otaPartition.start = UINT32_MAX - PartitionSize + 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_IMAGE_BOUNDS);
    CHECK(fake.eraseCalls == 0);

    package = validPackage();
    reset();
    write32(package, OTA_PACKAGE_PAYLOAD_OFFSET, 0x200001C4);
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_VECTOR_TABLE);
    CHECK(fake.eraseCalls == 0);

    package = validPackage();
    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(OTAStagingWritePackage(package.data(), package.size() - 1) == OTA_OK);
    OTAStagedImageInfo info = {};
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_INCOMPLETE);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(OTAStagingWritePackage(package.data(), package.size() + 1) == OTA_ERROR_TRAILING_DATA);
    CHECK(fake.eraseCalls == 0);
}

void testFlashAndReadBackFailures()
{
    std::vector<uint8_t> package = validPackage();

    reset();
    fake.failEraseCall = 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_ERASE);

    reset();
    fake.failWriteCall = 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_WRITE);

    reset();
    fake.shortWriteCall = 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_SHORT_WRITE);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    fake.failReadCall = 1;
    OTAStagedImageInfo info = {};
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_READ_BACK);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    fake.corruptReadCall = 1;
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_READ_BACK_HASH_MISMATCH);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    session.payloadCrc ^= 1;
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_READ_BACK_CRC_MISMATCH);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    package = validPackage();
    package[OTA_PACKAGE_PAYLOAD_OFFSET + OTA_IMAGE_DESCRIPTOR_OFFSET] ^= 1;
    sha256(
        package.data() + OTA_PACKAGE_PAYLOAD_OFFSET,
        PayloadSize,
        package.data() + 20);
    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_DESCRIPTOR_MISMATCH);
}

void testOperationTimeouts()
{
    std::vector<uint8_t> package = validPackage();

    reset();
    fake.signatureDuration = OTA_STAGING_SIGNATURE_MAX_MS + 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_SIGNATURE_TIMEOUT);
    CHECK(fake.eraseCalls == 0);

    reset();
    fake.eraseDuration = OTA_STAGING_FLASH_OPERATION_MAX_MS + 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_ERASE_TIMEOUT);

    reset();
    fake.writeDuration = OTA_STAGING_FLASH_OPERATION_MAX_MS + 1;
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_ERROR_WRITE_TIMEOUT);

    reset();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(stream(package) == OTA_OK);
    fake.readDuration = OTA_STAGING_FLASH_OPERATION_MAX_MS + 1;
    OTAStagedImageInfo info = {};
    CHECK(OTAStagingFinish(&info) == OTA_ERROR_READ_BACK_TIMEOUT);
}

void testCancellationAndState()
{
    reset();
    std::vector<uint8_t> package = validPackage();
    CHECK(beginPackage(package) == OTA_OK);
    CHECK(beginPackage(package) == OTA_ERROR_BUSY);
    fake.cancelRequested = true;
    CHECK(OTAStagingWritePackage(package.data(), 1) == OTA_ERROR_CANCELLED);
    CHECK(OTAStagingFinish(NULL) == OTA_ERROR_INVALID_STATE);

    reset();
    OTAStagedImageInfo info = stage(package, 13);
    CHECK(OTAStagingAbort() == OTA_OK);
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_ERROR_INVALID_STATE);
    CHECK(OTAStagingAbort() == OTA_ERROR_INVALID_STATE);

    reset();
    info = stage(package, 29);
    uint8_t wrongDigest[OTA_SHA256_SIZE] = {};
    CHECK(OTAStagingActivate(info.sessionGeneration, wrongDigest) == OTA_ERROR_INVALID_ARGUMENT);
    CHECK(OTAStagingActivate(info.sessionGeneration + 1, info.sha256) == OTA_ERROR_INVALID_ARGUMENT);
}

void testActivationRecovery()
{
    std::vector<uint8_t> package = validPackage();

    reset();
    OTAStagedImageInfo info = stage(package, 31);
    fake.failBootRead = true;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_ERROR_ACTIVATION);
    CHECK(fake.bootWriteCalls == 0);

    reset();
    info = stage(package, 31);
    fake.failBootWriteCall = 1;
    fake.persistBeforeBootWriteFailure = true;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_OK);

    reset();
    OTAStagingBootTable original = fake.boot;
    info = stage(package, 31);
    fake.failBootWriteCall = 1;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_ERROR_ACTIVATION);
    CHECK(memcmp(&fake.persisted, &original, sizeof(original)) == 0);

    reset();
    original = fake.boot;
    info = stage(package, 31);
    fake.failPersistedReadCall = 1;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) == OTA_ERROR_ACTIVATION);
    CHECK(memcmp(&fake.persisted, &original, sizeof(original)) == 0);

    reset();
    info = stage(package, 31);
    fake.failBootWriteCall = 2;
    fake.mismatchPersistedReadCall = 1;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) ==
          OTA_ERROR_ACTIVATION_UNCERTAIN);

    reset();
    info = stage(package, 31);
    fake.mismatchPersistedReadCall = 2;
    fake.failPersistedReadCall = 1;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) ==
          OTA_ERROR_ACTIVATION_UNCERTAIN);

    reset();
    info = stage(package, 31);
    fake.bootWriteDuration = OTA_STAGING_ACTIVATION_MAX_MS + 1;
    CHECK(OTAStagingActivate(info.sessionGeneration, info.sha256) ==
          OTA_ERROR_ACTIVATION_UNCERTAIN);
}

} // namespace

const OTAStagingPlatformOperations *OTAStagingDefaultPlatform(void)
{
    return &operations;
}

int main(int argc, char **argv)
{
    testSha256KnownAnswer();
#ifdef OTA_STAGING_SIGNATURE_KAT
    testProductionSignatureAdapter();
#endif
    testArbitraryChunkingAndActivation();
    testPreEraseRejections();
    testBoundsVectorsAndStreamErrors();
    testFlashAndReadBackFailures();
    testOperationTimeouts();
    testCancellationAndState();
    testActivationRecovery();
    if (argc == 3)
    {
        testHostToolingGoldenPackage(argv[1], argv[2]);
    }
    else
    {
        CHECK(argc == 1);
    }

    if (failures != 0)
    {
        std::fprintf(stderr, "%d OTA staging checks failed\n", failures);
        return EXIT_FAILURE;
    }
    std::puts("OTA staging tests passed");
    return EXIT_SUCCESS;
}
