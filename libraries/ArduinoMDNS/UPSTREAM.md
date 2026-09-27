# ArduinoMDNS provenance

This directory contains ArduinoMDNS `1.1.1-az3166.1`, based on:

- Source: <https://github.com/AaronWangTT/ArduinoMDNS>
- Release: `1.1.1`
- Commit: `7f206ac537a700edd1f90e55805cda6a3a8cdbe9`
- Upstream project: <https://github.com/arduino-libraries/ArduinoMDNS>
- Distributed license: GNU Lesser General Public License version 3 or later

The bundled source is based on that release. devkit-sdk applies these
downstream changes:

- clarify that the AZ3166 legacy `WiFiUDP` lacks `beginMulticast()`; and
- add the `AZ3166RegisteringService` example using the separately licensed
  `AZ3166MulticastUDP` transport.

Generic upstream examples are omitted because they expect networking transports
supplied by other Arduino cores. Source headers that offer LGPL 2.1 or later are
compatible with this package's selected LGPLv3-or-later distribution.
