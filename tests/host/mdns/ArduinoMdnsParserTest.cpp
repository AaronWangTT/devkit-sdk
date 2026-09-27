#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include <ArduinoMDNS.h>

unsigned long testMillis = 4000;

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
    IPAddress, unsigned short, const char *)
{
}

void writeHeader(std::vector<uint8_t> &packet, uint16_t answers)
{
    const uint8_t header[] = {
        0x00, 0x00, 0x80, 0x00,
        0x00, 0x00,
        static_cast<uint8_t>(answers >> 8),
        static_cast<uint8_t>(answers),
        0x00, 0x00, 0x00, 0x00
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

bool truncatedResponseNameIsRejected()
{
    PacketTransport transport;
    MDNS mdns(transport, false);
    REQUIRE(mdns.begin(IPAddress(192, 0, 2, 10), "az3166") == 1);
    mdns.setServiceFoundCallback(ignoreService);
    REQUIRE(mdns.startDiscoveringService("_http", MDNSServiceTCP, 1000) == 1);
    int sendsBeforeMalformedPacket = transport.sends;

    std::vector<uint8_t> packet;
    writeHeader(packet, 1);
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
    writeHeader(packet, 1);
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
        {"truncated response name is rejected", truncatedResponseNameIsRejected},
        {"undersized PTR record is rejected", undersizedPtrRecordIsRejected},
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
