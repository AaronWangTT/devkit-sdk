#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#define IPAddress_h

class IPAddress {
public:
    IPAddress() {
        std::memset(bytes_, 0, sizeof(bytes_));
    }

    IPAddress(uint8_t first, uint8_t second, uint8_t third, uint8_t fourth) {
        bytes_[0] = first;
        bytes_[1] = second;
        bytes_[2] = third;
        bytes_[3] = fourth;
    }

    uint8_t operator[](int index) const {
        return bytes_[index];
    }

    bool operator==(const IPAddress &other) const {
        return std::memcmp(bytes_, other.bytes_, sizeof(bytes_)) == 0;
    }

private:
    uint8_t bytes_[4];
};

const IPAddress IP_ADDR_NONE(0, 0, 0, 0);

#include "lwip/sockets.h"

struct SocketOption {
    int level;
    int option;
};

struct FakeSocket {
    void reset() {
        socketResult = 3;
        bindResult = 0;
        failedOption = 0;
        sendResult = UsePayloadSize;
        receiveResult = UsePayloadSize;
        socketCalls = 0;
        bindCalls = 0;
        closeCalls = 0;
        sendCalls = 0;
        receiveCalls = 0;
        fionreadCalls = 0;
        boundPort = 0;
        nonblocking = false;
        pendingOverride = 0;
        incomingAddress = 0;
        incomingPort = 0;
        incoming.clear();
        sent.clear();
        options.clear();
    }

    bool hasOption(int level, int option) const {
        for (size_t index = 0; index < options.size(); ++index) {
            if (options[index].level == level &&
                options[index].option == option) {
                return true;
            }
        }
        return false;
    }

    static const int UsePayloadSize = 0x7fffffff;
    int socketResult;
    int bindResult;
    int failedOption;
    int sendResult;
    int receiveResult;
    int socketCalls;
    int bindCalls;
    int closeCalls;
    int sendCalls;
    int receiveCalls;
    int fionreadCalls;
    uint16_t boundPort;
    bool nonblocking;
    unsigned long pendingOverride;
    uint32_t incomingAddress;
    uint16_t incomingPort;
    std::vector<uint8_t> incoming;
    std::vector<uint8_t> sent;
    std::vector<SocketOption> options;
};

FakeSocket fakeSocket;

uint32_t makeNetworkAddress(
    uint8_t first, uint8_t second, uint8_t third, uint8_t fourth)
{
    uint32_t value = (static_cast<uint32_t>(first) << 24) |
        (static_cast<uint32_t>(second) << 16) |
        (static_cast<uint32_t>(third) << 8) |
        static_cast<uint32_t>(fourth);
    return htonl(value);
}

int lwip_socket(int, int, int)
{
    ++fakeSocket.socketCalls;
    return fakeSocket.socketResult;
}

int lwip_setsockopt(
    int, int level, int option, const void *, socklen_t)
{
    fakeSocket.options.push_back(SocketOption{level, option});
    return fakeSocket.failedOption == option ? -1 : 0;
}

int lwip_bind(int, const sockaddr *address, socklen_t)
{
    ++fakeSocket.bindCalls;
    const sockaddr_in *local =
        reinterpret_cast<const sockaddr_in *>(address);
    fakeSocket.boundPort = ntohs(local->sin_port);
    return fakeSocket.bindResult;
}

int lwip_ioctl(int, long command, void *argument)
{
    if (command == FIONBIO) {
        fakeSocket.nonblocking =
            *static_cast<unsigned long *>(argument) != 0;
    } else if (command == FIONREAD) {
        ++fakeSocket.fionreadCalls;
        *static_cast<unsigned long *>(argument) =
            fakeSocket.pendingOverride != 0
                ? fakeSocket.pendingOverride
                : static_cast<unsigned long>(fakeSocket.incoming.size());
    }
    return 0;
}

int lwip_sendto(
    int, const void *data, size_t size, int,
    const sockaddr *, socklen_t)
{
    ++fakeSocket.sendCalls;
    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    fakeSocket.sent.assign(bytes, bytes + size);
    return fakeSocket.sendResult == FakeSocket::UsePayloadSize
        ? static_cast<int>(size)
        : fakeSocket.sendResult;
}

int lwip_recvfrom(
    int, void *data, size_t size, int,
    sockaddr *address, socklen_t *)
{
    ++fakeSocket.receiveCalls;
    if (fakeSocket.incoming.empty()) {
        errno = LWIP_EWOULDBLOCK;
        return -1;
    }
    sockaddr_in *remote = reinterpret_cast<sockaddr_in *>(address);
    std::memset(remote, 0, sizeof(*remote));
    remote->sin_port = htons(fakeSocket.incomingPort);
    remote->sin_addr.s_addr = fakeSocket.incomingAddress;
    size_t copied = std::min(size, fakeSocket.incoming.size());
    std::memcpy(data, fakeSocket.incoming.data(), copied);
    fakeSocket.incoming.clear();
    return fakeSocket.receiveResult == FakeSocket::UsePayloadSize
        ? static_cast<int>(copied)
        : fakeSocket.receiveResult;
}

int lwip_close(int)
{
    ++fakeSocket.closeCalls;
    return 0;
}

#include "AZ3166MulticastUdp.cpp"

#define REQUIRE(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "%s:%d: requirement failed: %s\n", \
                         __FILE__, __LINE__, #condition); \
            return false; \
        } \
    } while (0)

void resetFake()
{
    fakeSocket.reset();
}

bool requiresLocalAddress()
{
    resetFake();
    AZ3166MulticastUDP udp;

    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 0);
    REQUIRE(fakeSocket.socketCalls == 0);
    REQUIRE(!udp.failed());
    return true;
}

bool configuresValidatedMulticastSocket()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));

    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    REQUIRE(fakeSocket.socketCalls == 1);
    REQUIRE(fakeSocket.bindCalls == 1);
    REQUIRE(fakeSocket.boundPort == 5353);
    REQUIRE(fakeSocket.nonblocking);
    REQUIRE(fakeSocket.hasOption(SOL_SOCKET, SO_REUSEADDR));
    REQUIRE(fakeSocket.hasOption(IPPROTO_IP, IP_ADD_MEMBERSHIP));
    REQUIRE(fakeSocket.hasOption(IPPROTO_IP, IP_MULTICAST_IF));
    REQUIRE(fakeSocket.hasOption(IPPROTO_IP, IP_MULTICAST_TTL));
    REQUIRE(fakeSocket.hasOption(IPPROTO_IP, IP_TTL));
    return true;
}

bool configurationFailureClosesSocket()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    fakeSocket.failedOption = IP_ADD_MEMBERSHIP;

    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 0);
    REQUIRE(fakeSocket.closeCalls == 1);
    REQUIRE(!udp.failed());
    return true;
}

bool multipleWritesProduceOneDatagram()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    const uint8_t first[] = {1, 2};
    const uint8_t second[] = {3, 4, 5};

    REQUIRE(udp.beginPacket(IPAddress(224, 0, 0, 251), 5353) == 1);
    REQUIRE(udp.write(first, sizeof(first)) == sizeof(first));
    REQUIRE(udp.write(second, sizeof(second)) == sizeof(second));
    REQUIRE(fakeSocket.sendCalls == 0);
    REQUIRE(udp.endPacket() == 1);
    REQUIRE(fakeSocket.sendCalls == 1);
    const uint8_t expected[] = {1, 2, 3, 4, 5};
    REQUIRE(fakeSocket.sent ==
            std::vector<uint8_t>(expected, expected + sizeof(expected)));
    REQUIRE(udp.endPacket() == 0);
    REQUIRE(fakeSocket.sendCalls == 1);
    REQUIRE(udp.write(first, sizeof(first)) == 0);
    REQUIRE(fakeSocket.sendCalls == 1);
    return true;
}

bool overflowRejectsDatagramAndSetsFailure()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    std::vector<uint8_t> payload(
        AZ3166_MULTICAST_UDP_TX_CAPACITY + 1, 0x5a);

    REQUIRE(udp.beginPacket(IPAddress(224, 0, 0, 251), 5353) == 1);
    REQUIRE(udp.write(payload.data(), payload.size()) == 0);
    REQUIRE(udp.endPacket() == 0);
    REQUIRE(fakeSocket.sendCalls == 0);
    REQUIRE(udp.failed());
    udp.stop();
    REQUIRE(!udp.failed());
    return true;
}

bool receivesOnePacketAndReportsSender()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    fakeSocket.incoming = std::vector<uint8_t>{'m', 'D', 'N', 'S'};
    fakeSocket.incomingAddress = makeNetworkAddress(192, 0, 2, 44);
    fakeSocket.incomingPort = 5353;
    uint8_t first[2] = {};
    uint8_t second[4] = {};

    REQUIRE(udp.parsePacket() == 4);
    REQUIRE(udp.read(first, sizeof(first)) == 2);
    REQUIRE(udp.read(second, sizeof(second)) == 2);
    REQUIRE(first[0] == 'm' && first[1] == 'D');
    REQUIRE(second[0] == 'N' && second[1] == 'S');
    REQUIRE(udp.remoteIP() == IPAddress(192, 0, 2, 44));
    REQUIRE(udp.remotePort() == 5353);
    udp.flush();
    REQUIRE(udp.read(second, sizeof(second)) == 0);
    return true;
}

bool queuedByteTotalDoesNotRejectNextDatagram()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    fakeSocket.pendingOverride = AZ3166_MULTICAST_UDP_RX_CAPACITY + 100;
    fakeSocket.incoming = std::vector<uint8_t>{1, 2, 3, 4};

    REQUIRE(udp.parsePacket() == 4);
    REQUIRE(!udp.failed());
    REQUIRE(fakeSocket.fionreadCalls == 0);
    return true;
}

bool noPacketIsNotAFailure()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);

    REQUIRE(udp.parsePacket() == 0);
    REQUIRE(!udp.failed());
    return true;
}

bool rejectsOversizedIncomingPacket()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    fakeSocket.incoming = std::vector<uint8_t>(
        AZ3166_MULTICAST_UDP_RX_CAPACITY + 1, 0x5a);

    REQUIRE(udp.parsePacket() == 0);
    REQUIRE(fakeSocket.receiveCalls == 1);
    uint8_t byte = 0;
    REQUIRE(udp.read(&byte, 1) == 0);
    REQUIRE(udp.failed());
    return true;
}

bool receiveFailureSetsFailure()
{
    resetFake();
    AZ3166MulticastUDP udp;
    udp.setLocalIPv4Address(IPAddress(192, 0, 2, 10));
    REQUIRE(udp.beginMulticast(IPAddress(224, 0, 0, 251), 5353) == 1);
    fakeSocket.incoming = std::vector<uint8_t>{0x01};
    fakeSocket.receiveResult = -1;
    errno = 5;

    REQUIRE(udp.parsePacket() == 0);
    REQUIRE(udp.failed());
    return true;
}

struct TestCase {
    const char *name;
    bool (*run)();
};

int main()
{
    const TestCase tests[] = {
        {"requires local address", requiresLocalAddress},
        {"configures multicast socket", configuresValidatedMulticastSocket},
        {"configuration failure closes socket", configurationFailureClosesSocket},
        {"multiple writes produce one datagram", multipleWritesProduceOneDatagram},
        {"overflow rejects datagram", overflowRejectsDatagramAndSetsFailure},
        {"receives packet and sender", receivesOnePacketAndReportsSender},
        {"queued byte total does not reject datagram", queuedByteTotalDoesNotRejectNextDatagram},
        {"no packet is not a failure", noPacketIsNotAFailure},
        {"rejects oversized incoming packet", rejectsOversizedIncomingPacket},
        {"receive failure sets failure", receiveFailureSetsFailure},
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
