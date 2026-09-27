# Third-Party Notices

This notice records third-party software added by the maintained AZ3166 Core.
Other inherited SDK components retain their original notices and license files
in their component directories.

## ArduinoMDNS 1.1.1-az3166.1

ArduinoMDNS provides the mDNS and DNS-SD protocol implementation bundled under
`libraries/ArduinoMDNS`.

- Copyright (C) 2010 Georg Kaindl
- Copyright (c) 2017 Arduino LLC
- Maintained source: <https://github.com/AaronWangTT/ArduinoMDNS>
- Maintained tag: `1.1.1`
- Maintained commit: `7f206ac537a700edd1f90e55805cda6a3a8cdbe9`
- Upstream source: <https://github.com/arduino-libraries/ArduinoMDNS>
- Distributed license: GNU Lesser General Public License version 3 or later
- License text: `libraries/ArduinoMDNS/LICENSE.txt`
- Source and provenance: `libraries/ArduinoMDNS/` and
  `libraries/ArduinoMDNS/UPSTREAM.md`

The bundled source is based on the maintained 1.1.1 archive. devkit-sdk
clarifies the transport requirements and adds the `AZ3166RegisteringService`
example. Generic examples for other Arduino networking stacks are omitted. The
separate `AZ3166MulticastUDP` transport used by the example is Apache-2.0
licensed.

Some original source headers offer LGPL version 2.1 or later, while the protocol
sources offer LGPL version 3 or later. This package distributes their combined
work under LGPL version 3 or later and includes that complete license text.

Recipients may replace or modify ArduinoMDNS under the terms of the included
LGPL. The complete library source required to rebuild the bundled Arduino
library is included in the Board Package.
