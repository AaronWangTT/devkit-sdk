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

#ifndef AZ3166_MULTICAST_UDP_H
#define AZ3166_MULTICAST_UDP_H

#include <stddef.h>
#include <stdint.h>
#include "IPAddress.h"

#define AZ3166_MULTICAST_UDP_TX_CAPACITY 512
#define AZ3166_MULTICAST_UDP_RX_CAPACITY 1536

class AZ3166MulticastUDP
{
public:
    AZ3166MulticastUDP();
    ~AZ3166MulticastUDP();

    void setLocalIPv4Address(IPAddress address);
    bool failed() const;

    uint8_t beginMulticast(IPAddress address, uint16_t port);
    void stop();
    int beginPacket(IPAddress address, uint16_t port);
    size_t write(const uint8_t *buffer, size_t size);
    int endPacket();
    int parsePacket();
    int read(uint8_t *buffer, size_t size);
    void flush();
    IPAddress remoteIP();
    uint16_t remotePort();

private:
    AZ3166MulticastUDP(const AZ3166MulticastUDP &) = delete;
    AZ3166MulticastUDP &operator=(const AZ3166MulticastUDP &) = delete;

    int socket_;
    IPAddress localAddress_;
    IPAddress destination_;
    IPAddress remoteAddress_;
    uint16_t destinationPort_;
    uint16_t remotePort_;
    size_t receiveLength_;
    size_t receiveOffset_;
    size_t sendLength_;
    bool packetActive_;
    bool overflow_;
    bool failed_;
    uint8_t receiveBuffer_[AZ3166_MULTICAST_UDP_RX_CAPACITY + 1];
    uint8_t sendBuffer_[AZ3166_MULTICAST_UDP_TX_CAPACITY];
};

#endif
