# Third-Party Notices

This notice records third-party software added by the maintained AZ3166 Core.
Other inherited SDK components retain their original notices and license files
in their component directories.

## ArduinoMDNS 1.1.0

ArduinoMDNS provides the mDNS and DNS-SD protocol implementation bundled under
`libraries/ArduinoMDNS`.

- Copyright (C) 2010 Georg Kaindl
- Copyright (c) 2017 Arduino LLC
- Maintained source: <https://github.com/AaronWangTT/ArduinoMDNS>
- Maintained tag: `1.1.0`
- Maintained commit: `f6806819281a2395fd72894f5479a096e56446b2`
- Upstream source: <https://github.com/arduino-libraries/ArduinoMDNS>
- License: GNU Lesser General Public License version 3 or later
- License text: `libraries/ArduinoMDNS/LICENSE.txt`
- Source and provenance: `libraries/ArduinoMDNS/` and
  `libraries/ArduinoMDNS/UPSTREAM.md`

The protocol sources, public headers, utility sources, metadata, README, and
license are distributed from the maintained 1.1.0 archive without source
changes. Generic examples for other Arduino networking stacks are omitted.
devkit-sdk adds the `AZ3166RegisteringService` example and supplies the separate
Apache-2.0-licensed `AZ3166MulticastUDP` transport used by that example.

Recipients may replace or modify ArduinoMDNS under the terms of the included
LGPL. The complete library source required to rebuild the bundled Arduino
library is included in the Board Package.
