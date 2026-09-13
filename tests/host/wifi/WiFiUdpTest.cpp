#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#define AZ3166_WiFi_h
#define wificlient_h
#define __SYSTEM_WIFI_H__
#define UDPSOCKET_H

class SocketAddress {
public:
    SocketAddress(const char *address = NULL, uint16_t port = 0)
        : _address(address == NULL ? "0.0.0.0" : address), _port(port) {}

    const char *get_ip_address() const { return _address.c_str(); }
    uint16_t get_port() const { return _port; }

    void set(const char *address, uint16_t port) {
        _address = address;
        _port = port;
    }

private:
    std::string _address;
    uint16_t _port;
};

class IPAddress {
public:
    IPAddress() : _address("0.0.0.0") {}

    IPAddress(uint8_t first, uint8_t second, uint8_t third, uint8_t fourth) {
        char address[16];
        snprintf(address, sizeof(address), "%u.%u.%u.%u", first, second, third, fourth);
        _address = address;
    }

    bool fromString(const char *address) {
        _address = address;
        return true;
    }

    char *get_address() { return const_cast<char *>(_address.c_str()); }

    bool operator==(const IPAddress &other) const { return _address == other._address; }

private:
    std::string _address;
};

const IPAddress IP_ADDR_NONE(0, 0, 0, 0);

class FakeNetworkInterface {
public:
    FakeNetworkInterface() { reset(); }

    void reset() {
        dnsResult = 0;
        resolvedAddress = "192.0.2.25";
        lastHostname.clear();
        dnsCalls = 0;
    }

    int gethostbyname(const char *hostname, SocketAddress *address) {
        ++dnsCalls;
        lastHostname = hostname;
        if (dnsResult == 0) {
            address->set(resolvedAddress.c_str(), address->get_port());
        }
        return dnsResult;
    }

    int dnsResult;
    std::string resolvedAddress;
    std::string lastHostname;
    int dnsCalls;
};

FakeNetworkInterface networkInterface;

FakeNetworkInterface *WiFiInterface() {
    return &networkInterface;
}

class UDPSocket {
public:
    UDPSocket()
        : openResult(0), bindResult(0), sendResult(UsePayloadSize),
          isOpen(false), isBound(false), blocking(true), timeout(0),
          openCalls(0), bindCalls(0), closeCalls(0),
          sendCalls(0), receiveCalls(0), boundPort(0), hasIncomingPacket(false),
          receiveError(-1) {
        lastCreated = this;
        ++constructionCount;
    }

    ~UDPSocket() {
        if (lastCreated == this) {
            lastCreated = NULL;
        }
        ++destructionCount;
    }

    static void reset() {
        lastCreated = NULL;
        constructionCount = 0;
        destructionCount = 0;
        totalCloseCalls = 0;
    }

    void set_blocking(bool value) { blocking = value; }
    void set_timeout(int value) { timeout = value; }

    int open(FakeNetworkInterface *) {
        ++openCalls;
        if (openResult != 0) {
            return openResult;
        }
        if (isOpen) {
            return -1;
        }
        isOpen = true;
        isBound = false;
        return 0;
    }

    int bind(uint16_t port) {
        ++bindCalls;
        if (bindResult != 0) {
            return bindResult;
        }
        if (!isOpen || isBound) {
            return -1;
        }
        isBound = true;
        boundPort = port;
        return 0;
    }

    int close() {
        ++closeCalls;
        ++totalCloseCalls;
        isOpen = false;
        isBound = false;
        boundPort = 0;
        return 0;
    }

    int sendto(const SocketAddress &address, const void *data, size_t size) {
        ++sendCalls;
        lastSendAddress = address;
        const unsigned char *bytes = static_cast<const unsigned char *>(data);
        lastPayload.assign(bytes, bytes + size);
        return sendResult == UsePayloadSize ? static_cast<int>(size) : sendResult;
    }

    int recvfrom(SocketAddress *address, void *data, size_t size) {
        ++receiveCalls;
        if (!hasIncomingPacket) {
            return receiveError;
        }

        address->set(incomingAddress.c_str(), incomingPort);
        const size_t copied = std::min(size, incomingPayload.size());
        std::memcpy(data, incomingPayload.data(), copied);
        hasIncomingPacket = false;
        return static_cast<int>(copied);
    }

    void queueIncoming(
        const char *address,
        uint16_t port,
        const unsigned char *payload,
        size_t size
    ) {
        incomingAddress = address;
        incomingPort = port;
        incomingPayload.assign(payload, payload + size);
        hasIncomingPacket = true;
    }

    static const int UsePayloadSize = 0x7fffffff;
    static UDPSocket *lastCreated;
    static int constructionCount;
    static int destructionCount;
    static int totalCloseCalls;

    int openResult;
    int bindResult;
    int sendResult;
    bool isOpen;
    bool isBound;
    bool blocking;
    int timeout;
    int openCalls;
    int bindCalls;
    int closeCalls;
    int sendCalls;
    int receiveCalls;
    uint16_t boundPort;
    SocketAddress lastSendAddress;
    std::vector<unsigned char> lastPayload;
    std::string incomingAddress;
    uint16_t incomingPort;
    std::vector<unsigned char> incomingPayload;
    bool hasIncomingPacket;
    int receiveError;
};

UDPSocket *UDPSocket::lastCreated = NULL;
int UDPSocket::constructionCount = 0;
int UDPSocket::destructionCount = 0;
int UDPSocket::totalCloseCalls = 0;

#include "../../../AZ3166/src/libraries/WiFi/src/AZ3166WiFiUdp.cpp"

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "%s:%d: requirement failed: %s\n", __FILE__, __LINE__, #condition); \
            return false; \
        } \
    } while (0)

void resetFakes() {
    networkInterface.reset();
    UDPSocket::reset();
}

bool constructorStartsWithoutRemoteEndpoint() {
    resetFakes();
    alignas(WiFiUDP) unsigned char storage[sizeof(WiFiUDP)];
    std::memset(storage, 0xA5, sizeof(storage));

    WiFiUDP *udp = new (storage) WiFiUDP();
    REQUIRE(udp->remotePort() == 0);
    REQUIRE(udp->remoteIP() == IP_ADDR_NONE);
    udp->~WiFiUDP();
    REQUIRE(UDPSocket::constructionCount == 1);
    REQUIRE(UDPSocket::destructionCount == 1);

    return true;
}

bool beginReopensBeforeRebinding() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;

    REQUIRE(udp.begin(2390) == 1);
    REQUIRE(socket->openCalls == 1);
    REQUIRE(socket->bindCalls == 1);
    REQUIRE(socket->boundPort == 2390);
    REQUIRE(!socket->blocking);
    REQUIRE(socket->timeout == 5000);

    REQUIRE(udp.begin(5353) == 1);
    REQUIRE(socket->closeCalls == 1);
    REQUIRE(socket->openCalls == 2);
    REQUIRE(socket->bindCalls == 2);
    REQUIRE(socket->boundPort == 5353);

    return true;
}

bool beginReportsOpenAndBindFailures() {
    resetFakes();
    {
        WiFiUDP udp;
        UDPSocket *socket = UDPSocket::lastCreated;
        socket->openResult = -1;

        REQUIRE(udp.begin(2390) == 0);
        REQUIRE(socket->openCalls == 1);
        REQUIRE(socket->bindCalls == 0);
        REQUIRE(socket->closeCalls == 0);
    }

    resetFakes();
    {
        WiFiUDP udp;
        UDPSocket *socket = UDPSocket::lastCreated;
        socket->bindResult = -2;

        REQUIRE(udp.begin(2390) == 0);
        REQUIRE(socket->openCalls == 1);
        REQUIRE(socket->bindCalls == 1);
        REQUIRE(socket->closeCalls == 1);
    }

    return true;
}

bool stopIsIdempotentAndAllowsRestart() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;

    udp.stop();
    REQUIRE(socket->closeCalls == 0);
    REQUIRE(udp.begin(2390) == 1);
    udp.stop();
    REQUIRE(socket->closeCalls == 1);
    udp.stop();
    REQUIRE(socket->closeCalls == 1);

    REQUIRE(udp.begin(5353) == 1);
    REQUIRE(socket->openCalls == 2);
    REQUIRE(socket->bindCalls == 2);

    return true;
}

bool sendsBufferToIpEndpoint() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;
    IPAddress destination(192, 0, 2, 10);
    const unsigned char payload[] = {0x01, 0x02, 0x03};

    REQUIRE(udp.beginPacket(destination, 123) == 1);
    REQUIRE(udp.remoteIP() == destination);
    REQUIRE(udp.remotePort() == 123);
    REQUIRE(udp.write(payload, sizeof(payload)) == sizeof(payload));
    REQUIRE(udp.endPacket() == 1);
    REQUIRE(socket->sendCalls == 1);
    REQUIRE(socket->lastSendAddress.get_ip_address() == std::string("192.0.2.10"));
    REQUIRE(socket->lastSendAddress.get_port() == 123);
    REQUIRE(socket->lastPayload == std::vector<unsigned char>(payload, payload + sizeof(payload)));

    return true;
}

bool resolvesHostnameAndSendsByte() {
    resetFakes();
    networkInterface.resolvedAddress = "198.51.100.8";
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;

    REQUIRE(udp.beginPacket("time.example", 123) == 1);
    REQUIRE(networkInterface.dnsCalls == 1);
    REQUIRE(networkInterface.lastHostname == "time.example");
    REQUIRE(udp.remoteIP() == IPAddress(198, 51, 100, 8));
    REQUIRE(udp.write(0xE3) == 1);
    REQUIRE(udp.endPacket() == 1);
    REQUIRE(socket->lastPayload.size() == 1);
    REQUIRE(socket->lastPayload[0] == 0xE3);

    return true;
}

bool beginPacketReportsDnsAndOpenFailures() {
    resetFakes();
    {
        networkInterface.dnsResult = -1;
        WiFiUDP udp;
        UDPSocket *socket = UDPSocket::lastCreated;

        REQUIRE(udp.beginPacket("missing.example", 53) == 0);
        REQUIRE(socket->openCalls == 0);
        REQUIRE(udp.remotePort() == 0);
    }

    resetFakes();
    {
        WiFiUDP udp;
        UDPSocket *socket = UDPSocket::lastCreated;
        socket->openResult = -2;

        REQUIRE(udp.beginPacket(IPAddress(203, 0, 113, 9), 53) == 0);
        REQUIRE(socket->openCalls == 1);
        REQUIRE(socket->sendCalls == 0);
    }

    return true;
}

bool writeRequiresSocketAndDestinationAndReportsFailures() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;
    const unsigned char payload[] = {0x01};

    REQUIRE(udp.write(payload, sizeof(payload)) == 0);
    REQUIRE(socket->sendCalls == 0);
    REQUIRE(udp.begin(5353) == 1);
    REQUIRE(udp.write(payload, sizeof(payload)) == 0);
    REQUIRE(socket->sendCalls == 0);
    REQUIRE(udp.beginPacket(IPAddress(203, 0, 113, 9), 53) == 1);
    socket->sendResult = -1;
    REQUIRE(udp.write(payload, sizeof(payload)) == 0);
    REQUIRE(socket->sendCalls == 1);
    REQUIRE(udp.endPacket() == 0);

    socket->sendResult = UDPSocket::UsePayloadSize;
    REQUIRE(udp.beginPacket(IPAddress(203, 0, 113, 10), 53) == 1);
    REQUIRE(udp.write(payload, sizeof(payload)) == sizeof(payload));
    REQUIRE(socket->sendCalls == 2);
    REQUIRE(udp.endPacket() == 1);

    return true;
}

bool readsRequireInitializedSocketAndNormalizeNoData() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;
    unsigned char buffer[2] = {};

    REQUIRE(udp.read() == -1);
    REQUIRE(udp.read(buffer, sizeof(buffer)) == 0);
    REQUIRE(socket->receiveCalls == 0);
    REQUIRE(udp.begin(5353) == 1);
    socket->receiveError = -2;
    REQUIRE(udp.read(buffer, sizeof(buffer)) == 0);
    REQUIRE(socket->receiveCalls == 1);

    return true;
}

bool receivesBufferAndReportsSender() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;
    const unsigned char payload[] = {'m', 'D', 'N', 'S'};
    unsigned char buffer[8] = {};

    REQUIRE(udp.begin(5353) == 1);
    socket->queueIncoming("192.0.2.44", 5353, payload, sizeof(payload));
    REQUIRE(udp.read(buffer, sizeof(buffer)) == static_cast<int>(sizeof(payload)));
    REQUIRE(std::memcmp(buffer, payload, sizeof(payload)) == 0);
    REQUIRE(udp.remoteIP() == IPAddress(192, 0, 2, 44));
    REQUIRE(udp.remotePort() == 5353);
    udp.flush();

    return true;
}

bool readsByteAsUnsignedAndReportsNoData() {
    resetFakes();
    WiFiUDP udp;
    UDPSocket *socket = UDPSocket::lastCreated;
    const unsigned char payload[] = {0xFE};

    REQUIRE(udp.begin(5353) == 1);
    socket->queueIncoming("192.0.2.45", 5353, payload, sizeof(payload));
    REQUIRE(udp.read() == 0xFE);
    REQUIRE(udp.read() == -1);

    return true;
}

struct TestCase {
    const char *name;
    bool (*run)();
};

int main() {
    const TestCase tests[] = {
        {"constructor starts without remote endpoint", constructorStartsWithoutRemoteEndpoint},
        {"begin reopens before rebinding", beginReopensBeforeRebinding},
        {"begin reports open and bind failures", beginReportsOpenAndBindFailures},
        {"stop is idempotent and allows restart", stopIsIdempotentAndAllowsRestart},
        {"send buffer to IP endpoint", sendsBufferToIpEndpoint},
        {"resolve hostname and send byte", resolvesHostnameAndSendsByte},
        {"beginPacket reports DNS and open failures", beginPacketReportsDnsAndOpenFailures},
        {"write requires socket and destination and reports failures", writeRequiresSocketAndDestinationAndReportsFailures},
        {"reads require initialized socket and normalize no data", readsRequireInitializedSocketAndNormalizeNoData},
        {"receive buffer and report sender", receivesBufferAndReportsSender},
        {"read byte as unsigned and report no data", readsByteAsUnsignedAndReportsNoData},
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

    std::printf("%u tests, %d failures\n", static_cast<unsigned>(sizeof(tests) / sizeof(tests[0])), failures);
    return failures == 0 ? 0 : 1;
}