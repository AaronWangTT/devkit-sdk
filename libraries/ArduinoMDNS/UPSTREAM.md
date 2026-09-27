# ArduinoMDNS provenance

This directory contains the maintained ArduinoMDNS 1.1.0 library from:

- Source: <https://github.com/AaronWangTT/ArduinoMDNS>
- Tag: `1.1.0`
- Commit: `f6806819281a2395fd72894f5479a096e56446b2`
- Upstream project: <https://github.com/arduino-libraries/ArduinoMDNS>
- License: GNU Lesser General Public License version 3 or later

The protocol sources, public headers, utility sources, metadata, README, and
license are unchanged from that tag. The generic upstream examples are omitted
from the AZ3166 board package because they expect networking transports supplied
by other Arduino cores. The `AZ3166RegisteringService` example is maintained in
devkit-sdk and uses the separately licensed `AZ3166MulticastUDP` transport.
