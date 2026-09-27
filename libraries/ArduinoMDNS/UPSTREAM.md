# ArduinoMDNS provenance

This directory contains the maintained ArduinoMDNS 1.1.0 library from:

- Source: <https://github.com/AaronWangTT/ArduinoMDNS>
- Tag: `1.1.0`
- Commit: `f6806819281a2395fd72894f5479a096e56446b2`
- Upstream project: <https://github.com/arduino-libraries/ArduinoMDNS>
- Distributed license: GNU Lesser General Public License version 3 or later

The bundled source is based on that tag. devkit-sdk applies these downstream
changes:

- guard empty service-record slots during removal;
- select byte-order conversion using compiler and AZ3166 platform macros;
- clarify that the AZ3166 legacy `WiFiUDP` lacks `beginMulticast()`; and
- add the `AZ3166RegisteringService` example using the separately licensed
  `AZ3166MulticastUDP` transport.

Generic upstream examples are omitted because they expect networking transports
supplied by other Arduino cores. Source headers that offer LGPL 2.1 or later are
compatible with this package's selected LGPLv3-or-later distribution.
