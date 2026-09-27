#ifndef AZ3166_TEST_LWIP_SOCKETS_H
#define AZ3166_TEST_LWIP_SOCKETS_H

#include <stddef.h>
#include <stdint.h>

typedef unsigned int socklen_t;

struct in_addr {
    uint32_t s_addr;
};

struct sockaddr {
    uint8_t sa_len;
    uint8_t sa_family;
    char sa_data[14];
};

struct sockaddr_in {
    uint8_t sin_len;
    uint8_t sin_family;
    uint16_t sin_port;
    in_addr sin_addr;
    char sin_zero[8];
};

struct ip_mreq {
    in_addr imr_multiaddr;
    in_addr imr_interface;
};

#define AF_INET 2
#define SOCK_DGRAM 2
#define IPPROTO_IP 0
#define IPPROTO_UDP 17
#define SOL_SOCKET 0xfff
#define SO_REUSEADDR 0x0004
#define IP_TTL 2
#define IP_ADD_MEMBERSHIP 3
#define IP_DROP_MEMBERSHIP 4
#define IP_MULTICAST_TTL 5
#define IP_MULTICAST_IF 6
#define MSG_DONTWAIT 0x08
#define FIONREAD 0x4004667f
#define FIONBIO 0x8004667e
#define LWIP_EWOULDBLOCK 11

static inline uint16_t az3166TestSwap16(uint16_t value)
{
    return static_cast<uint16_t>((value << 8) | (value >> 8));
}

static inline uint32_t az3166TestSwap32(uint32_t value)
{
    return ((value & 0x000000ffUL) << 24) |
        ((value & 0x0000ff00UL) << 8) |
        ((value & 0x00ff0000UL) >> 8) |
        ((value & 0xff000000UL) >> 24);
}

#define htons(value) az3166TestSwap16(value)
#define ntohs(value) az3166TestSwap16(value)
#define htonl(value) az3166TestSwap32(value)
#define ntohl(value) az3166TestSwap32(value)

int lwip_socket(int domain, int type, int protocol);
int lwip_setsockopt(
    int socket, int level, int option, const void *value, socklen_t length);
int lwip_bind(int socket, const sockaddr *address, socklen_t length);
int lwip_ioctl(int socket, long command, void *argument);
int lwip_sendto(
    int socket, const void *data, size_t size, int flags,
    const sockaddr *address, socklen_t addressLength);
int lwip_recvfrom(
    int socket, void *data, size_t size, int flags,
    sockaddr *address, socklen_t *addressLength);
int lwip_close(int socket);

#endif
