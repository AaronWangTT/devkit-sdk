#include <cstdint>
#include <cstdio>

extern "C" {
uint16_t ethutil_htons(unsigned short value);
uint32_t ethutil_htonl(unsigned long value);
uint16_t ethutil_ntohs(unsigned short value);
uint32_t ethutil_ntohl(unsigned long value);
}

int main()
{
    if (ethutil_htons(0x1234) != 0x3412 ||
        ethutil_ntohs(0x3412) != 0x1234 ||
        ethutil_htonl(0x12345678UL) != 0x78563412UL ||
        ethutil_ntohl(0x78563412UL) != 0x12345678UL) {
        std::fprintf(stderr, "ArduinoMDNS byte-order conversion failed\n");
        return 1;
    }

    std::printf("ArduinoMDNS byte-order conversion passed\n");
    return 0;
}
