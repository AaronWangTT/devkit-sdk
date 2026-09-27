#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include <ArduinoMDNS.h>

unsigned long testMillis = 4000;
int serviceCallbacks = 0;
unsigned short lastServicePort = 0;
bool failNextMalloc = false;

extern "C" void *__real_malloc(size_t size);

extern "C" void *__wrap_malloc(size_t size)
{
    if (failNextMalloc) {
        failNextMalloc = false;
        return NULL;
    }
    return __real_malloc(size);
}

unsigned long millis()
{
    return testMillis;
}

void delay(unsigned long milliseconds)
{
    testMillis += milliseconds;
}

class PacketTransport {
public:
    PacketTransport()
        : offset(0), sender(192, 0, 2, 20), senderPort(5353),
          sends(0), open(false) {}

    uint8_t beginMulticast(IPAddress, uint16_t) {
        open = true;
        return 1;
    }

    void stop() {
        open = false;
        packet.clear();
        offset = 0;
    }

    int beginPacket(IPAddress, uint16_t) {
        output.clear();
        return open ? 1 : 0;
    }

    size_t write(const uint8_t *buffer, size_t size) {
        output.insert(output.end(), buffer, buffer + size);
        return size;
    }

    int endPacket() {
        ++sends;
        return 1;
    }

    int parsePacket() {
        return static_cast<int>(packet.size());
    }

    int read(uint8_t *buffer, size_t size) {
        size_t available = packet.size() - offset;
        size = std::min(size, available);
        std::memcpy(buffer, packet.data() + offset, size);
        offset += size;
        return static_cast<int>(size);
    }

    void flush() {
        packet.clear();
        offset = 0;
    }

    IPAddress remoteIP() {
        return sender;
    }

    uint16_t remotePort() {
        return senderPort;
    }

    void queue(const uint8_t *data, size_t size) {
        packet.assign(data, data + size);
        offset = 0;
    }

    std::vector<uint8_t> packet;
    std::vector<uint8_t> output;
    size_t offset;
    IPAddress sender;
    uint16_t senderPort;
    int sends;
    bool open;
};

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                         __FILE__, __LINE__, #condition); \
            return false; \
        } \
    } while (0)

void ignoreService(
    const char *, MDNSServiceProtocol_t, const char *,
    IPAddress, unsigned short port, const char *)
{
    ++serviceCallbacks;
    lastServicePort = port;
}

void append16(std::vector<uint8_t> &packet, uint16_t value)
{
    packet.push_back(static_cast<uint8_t>(value >> 8));
    packet.push_back(static_cast<uint8_t>(value));
}

void append32(std::vector<uint8_t> &packet, uint32_t value)
{
    packet.push_back(static_cast<uint8_t>(value >> 24));
    packet.push_back(static_cast<uint8_t>(value >> 16));
    packet.push_back(static_cast<uint8_t>(value >> 8));
    packet.push_back(static_cast<uint8_t>(value));
}

void appendPointer(std::vector<uint8_t> &packet, uint16_t offset)
{
    packet.push_back(static_cast<uint8_t>(0xc0 | ((offset >> 8) & 0x3f)));
    packet.push_back(static_cast<uint8_t>(offset));
}

void writeHeader(
    std::vector<uint8_t> &packet,
    uint16_t questions,
    uint16_t answers,
    uint16_t additional = 0)
{
    const uint8_t header[] = {
        0x00, 0x00, 0x80, 0x00,
        static_cast<uint8_t>(questions >> 8),
        static_cast<uint8_t>(questions),
        static_cast<uint8_t>(answers >> 8),
        static_cast<uint8_t>(answers),
        0x00, 0x00,
        static_cast<uint8_t>(additional >> 8),
        static_cast<uint8_t>(additional)
    };
    packet.assign(header, header + sizeof(header));
}

bool removingMissingServiceRecordIsSafe()
{
    PacketTransport transport;
    MDNS mdns(transport, false);

    mdns.removeServiceRecord(80, MDNSServiceTCP);
    mdns.removeServiceRecord("missing._http", 80, MDNSServiceTCP);
    return true;
}

bool failedNameReplacementPreservesObject()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.setName("first") == 1);

    failNextMalloc = true;
    REQUIRE(mdns.setName("replacement") == 0);
    REQUIRE(mdns.setName("working") == 1);
    return true;
}

bool invalidServiceNamesAreRejected()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    int sendsBeforeInvalidNames = transport.sends;

    REQUIRE(mdns.addServiceRecord("http", 80, MDNSServiceTCP) == 0);
    REQUIRE(mdns.addServiceRecord(".http", 80, MDNSServiceTCP) == 0);
    REQUIRE(mdns.addServiceRecord("http.", 80, MDNSServiceTCP) == 0);
    REQUIRE(transport.sends == sendsBeforeInvalidNames);
    REQUIRE(mdns.addServiceRecord("device._http", 80, MDNSServiceTCP) == 1);
    return true;
}

bool truncatedResponseNameIsRejected()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    mdns.setServiceFoundCallback(ignoreService);
    REQUIRE(mdns.startDiscoveringService("_http", MDNSServiceTCP, 1000) == 1);
    serviceCallbacks = 0;
    int sendsBeforeMalformedPacket = transport.sends;

    std::vector<uint8_t> packet;
    writeHeader(packet, 0, 1);
    packet.push_back(5);
    packet.push_back('a');
    transport.queue(packet.data(), packet.size());
    mdns.run();

    REQUIRE(transport.sends == sendsBeforeMalformedPacket);
    return true;
}

bool undersizedPtrRecordIsRejected()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    mdns.setServiceFoundCallback(ignoreService);
    REQUIRE(mdns.startDiscoveringService("_http", MDNSServiceTCP, 1000) == 1);

    std::vector<uint8_t> packet;
    writeHeader(packet, 0, 1);
    const uint8_t record[] = {
        0xc0, 0x0c,
        0x00, 0x0c,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x78,
        0x00, 0x01,
        0x00
    };
    packet.insert(packet.end(), record, record + sizeof(record));
    transport.queue(packet.data(), packet.size());
    mdns.run();

    REQUIRE(serviceCallbacks == 0);
    return true;
}

bool undersizedSrvRecordIsRejected()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    mdns.setServiceFoundCallback(ignoreService);
    REQUIRE(mdns.startDiscoveringService("_http", MDNSServiceTCP, 1000) == 1);
    serviceCallbacks = 0;

    std::vector<uint8_t> packet;
    writeHeader(packet, 0, 1, 1);
    packet[11] = 1;
    const uint8_t ptrRecord[] = {
        0xc0, 0x0c,
        0x00, 0x0c, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x78,
        0x00, 0x06,
        0x03, 'f', 'o', 'o', 0xc0, 0x0c
    };
    packet.insert(packet.end(), ptrRecord, ptrRecord + sizeof(ptrRecord));
    const uint8_t srvRecord[] = {
        0xc0, 0x18,
        0x00, 0x21, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x78,
        0x00, 0x07,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x00
    };
    packet.insert(packet.end(), srvRecord, srvRecord + sizeof(srvRecord));
    transport.queue(packet.data(), packet.size());
    mdns.run();

    REQUIRE(serviceCallbacks == 0);
    return true;
}

bool preservesFullCompressionOffsets()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    mdns.setServiceFoundCallback(ignoreService);
    REQUIRE(mdns.startDiscoveringService("_http", MDNSServiceTCP, 1000) == 1);
    serviceCallbacks = 0;
    lastServicePort = 0;

    std::vector<uint8_t> packet;
    writeHeader(packet, 1, 1, 2);
    for (int label = 0; label < 4; ++label) {
        packet.push_back(63);
        packet.insert(packet.end(), 63, static_cast<uint8_t>('a' + label));
    }
    packet.push_back(0);
    append16(packet, 1);
    append16(packet, 1);

    appendPointer(packet, 12);
    append16(packet, 12);
    append16(packet, 1);
    append32(packet, 120);
    append16(packet, 6);
    uint16_t ptrNameOffset = static_cast<uint16_t>(packet.size());
    packet.push_back(3);
    packet.push_back('f');
    packet.push_back('o');
    packet.push_back('o');
    appendPointer(packet, 12);
    REQUIRE(ptrNameOffset > 255);

    appendPointer(packet, ptrNameOffset);
    append16(packet, 33);
    append16(packet, 1);
    append32(packet, 120);
    append16(packet, 8);
    append16(packet, 0);
    append16(packet, 0);
    append16(packet, 80);
    const uint16_t targetOffset = 0x0123;
    appendPointer(packet, targetOffset);

    appendPointer(packet, targetOffset);
    append16(packet, 1);
    append16(packet, 1);
    append32(packet, 120);
    append16(packet, 4);
    packet.push_back(192);
    packet.push_back(0);
    packet.push_back(2);
    packet.push_back(55);

    transport.queue(packet.data(), packet.size());
    mdns.run();

    REQUIRE(serviceCallbacks == 1);
    REQUIRE(lastServicePort == 80);
    return true;
}

struct TestCase {
    const char *name;
    bool (*run)();
};

int main()
{
    const TestCase tests[] = {
        {"removing missing service record is safe", removingMissingServiceRecordIsSafe},
        {"failed name replacement preserves object", failedNameReplacementPreservesObject},
        {"invalid service names are rejected", invalidServiceNamesAreRejected},
        {"truncated response name is rejected", truncatedResponseNameIsRejected},
        {"undersized PTR record is rejected", undersizedPtrRecordIsRejected},
        {"undersized SRV record is rejected", undersizedSrvRecordIsRejected},
        {"preserves full compression offsets", preservesFullCompressionOffsets},
    };

    int failures = 0;
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        if (tests[index].run()) {
            std::printf("PASS: %s\n", tests[index].name);
        } else {
            std::fprintf(stderr, "FAIL: %s\n", tests[index].name);
            ++failures;
        }
    }

    std::printf(
        "%u tests, %d failures\n",
        static_cast<unsigned>(sizeof(tests) / sizeof(tests[0])), failures);
    return failures == 0 ? 0 : 1;
}
