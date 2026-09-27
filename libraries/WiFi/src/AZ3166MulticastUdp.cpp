/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "AZ3166MulticastUdp.h"

#include <string.h>
#include "lwip/sockets.h"

namespace {

uint32_t networkAddress(IPAddress address)
{
    uint32_t value = (static_cast<uint32_t>(address[0]) << 24) |
        (static_cast<uint32_t>(address[1]) << 16) |
        (static_cast<uint32_t>(address[2]) << 8) |
        static_cast<uint32_t>(address[3]);
    return htonl(value);
}

bool isZeroAddress(IPAddress address)
{
    return address[0] == 0 && address[1] == 0 &&
        address[2] == 0 && address[3] == 0;
}

}

AZ3166MulticastUDP::AZ3166MulticastUDP()
    : socket_(-1),
      destinationPort_(0),
      remotePort_(0),
      receiveLength_(0),
      receiveOffset_(0),
      sendLength_(0),
      packetActive_(false),
      overflow_(false),
      failed_(false)
{
}

AZ3166MulticastUDP::~AZ3166MulticastUDP()
{
    stop();
}

void AZ3166MulticastUDP::setLocalIPv4Address(IPAddress address)
{
    localAddress_ = address;
}

bool AZ3166MulticastUDP::failed() const
{
    return failed_;
}

uint8_t AZ3166MulticastUDP::beginMulticast(IPAddress address, uint16_t port)
{
    stop();
    if (isZeroAddress(localAddress_) || port == 0)
    {
        return 0;
    }

    socket_ = lwip_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_ < 0)
    {
        return 0;
    }

    sockaddr_in local = {};
    local.sin_len = sizeof(local);
    local.sin_family = AF_INET;
    local.sin_port = htons(port);
    ip_mreq membership = {};
    membership.imr_multiaddr.s_addr = networkAddress(address);
    membership.imr_interface.s_addr = networkAddress(localAddress_);
    int reuse = 1;
    int unicastTtl = 255;
    unsigned char multicastTtl = 255;
    unsigned long nonblocking = 1;

    if (lwip_setsockopt(
            socket_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0 ||
        lwip_bind(
            socket_, reinterpret_cast<sockaddr *>(&local), sizeof(local)) != 0 ||
        lwip_setsockopt(
            socket_, IPPROTO_IP, IP_ADD_MEMBERSHIP,
            &membership, sizeof(membership)) != 0 ||
        lwip_setsockopt(
            socket_, IPPROTO_IP, IP_MULTICAST_IF,
            &membership.imr_interface, sizeof(membership.imr_interface)) != 0 ||
        lwip_setsockopt(
            socket_, IPPROTO_IP, IP_MULTICAST_TTL,
            &multicastTtl, sizeof(multicastTtl)) != 0 ||
        lwip_setsockopt(
            socket_, IPPROTO_IP, IP_TTL, &unicastTtl, sizeof(unicastTtl)) != 0 ||
        lwip_ioctl(socket_, FIONBIO, &nonblocking) != 0)
    {
        stop();
        return 0;
    }

    return 1;
}

void AZ3166MulticastUDP::stop()
{
    if (socket_ >= 0)
    {
        lwip_close(socket_);
    }
    socket_ = -1;
    receiveLength_ = receiveOffset_ = sendLength_ = 0;
    packetActive_ = false;
    overflow_ = failed_ = false;
}

int AZ3166MulticastUDP::beginPacket(IPAddress address, uint16_t port)
{
    destination_ = address;
    destinationPort_ = port;
    sendLength_ = 0;
    packetActive_ = socket_ >= 0 && port != 0;
    overflow_ = false;
    return packetActive_;
}

size_t AZ3166MulticastUDP::write(const uint8_t *buffer, size_t size)
{
    if (!packetActive_ || buffer == NULL || overflow_ ||
        size > sizeof(sendBuffer_) - sendLength_)
    {
        overflow_ = true;
        failed_ = true;
        return 0;
    }
    memcpy(sendBuffer_ + sendLength_, buffer, size);
    sendLength_ += size;
    return size;
}

int AZ3166MulticastUDP::endPacket()
{
    if (!packetActive_ || socket_ < 0 || overflow_ || sendLength_ == 0)
    {
        failed_ = true;
        packetActive_ = false;
        sendLength_ = 0;
        return 0;
    }

    sockaddr_in destination = {};
    destination.sin_len = sizeof(destination);
    destination.sin_family = AF_INET;
    destination.sin_port = htons(destinationPort_);
    destination.sin_addr.s_addr = networkAddress(destination_);
    int sent = lwip_sendto(
        socket_, sendBuffer_, sendLength_, 0,
        reinterpret_cast<sockaddr *>(&destination), sizeof(destination));
    if (sent != static_cast<int>(sendLength_))
    {
        failed_ = true;
        packetActive_ = false;
        sendLength_ = 0;
        return 0;
    }
    packetActive_ = false;
    sendLength_ = 0;
    return 1;
}

int AZ3166MulticastUDP::parsePacket()
{
    flush();
    if (socket_ < 0)
    {
        return 0;
    }

    sockaddr_in remote = {};
    socklen_t remoteSize = sizeof(remote);
    int received = lwip_recvfrom(
        socket_, receiveBuffer_, sizeof(receiveBuffer_), MSG_DONTWAIT,
        reinterpret_cast<sockaddr *>(&remote), &remoteSize);
    if (received < 0)
    {
        if (errno != LWIP_EWOULDBLOCK)
        {
            failed_ = true;
        }
        return 0;
    }
    if (received == 0)
    {
        return 0;
    }
    if (received > AZ3166_MULTICAST_UDP_RX_CAPACITY)
    {
        failed_ = true;
        return 0;
    }

    uint32_t address = ntohl(remote.sin_addr.s_addr);
    remoteAddress_ = IPAddress(
        static_cast<uint8_t>(address >> 24),
        static_cast<uint8_t>(address >> 16),
        static_cast<uint8_t>(address >> 8),
        static_cast<uint8_t>(address));
    remotePort_ = ntohs(remote.sin_port);
    receiveLength_ = static_cast<size_t>(received);
    return received;
}

int AZ3166MulticastUDP::read(uint8_t *buffer, size_t size)
{
    if (buffer == NULL)
    {
        return 0;
    }
    size_t remaining = receiveLength_ - receiveOffset_;
    if (size > remaining)
    {
        size = remaining;
    }
    memcpy(buffer, receiveBuffer_ + receiveOffset_, size);
    receiveOffset_ += size;
    return static_cast<int>(size);
}

void AZ3166MulticastUDP::flush()
{
    receiveLength_ = receiveOffset_ = 0;
}

IPAddress AZ3166MulticastUDP::remoteIP()
{
    return remoteAddress_;
}

uint16_t AZ3166MulticastUDP::remotePort()
{
    return remotePort_;
}
