# ArduinoMDNS

[![Check Arduino status](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/check-arduino.yml/badge.svg)](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/check-arduino.yml)
[![Compile Examples status](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/compile-examples.yml/badge.svg)](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/compile-examples.yml)
[![Spell Check status](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/spell-check.yml/badge.svg)](https://github.com/arduino-libraries/ArduinoMDNS/actions/workflows/spell-check.yml)

mDNS library for Arduino. Based on [@TrippyLighting](https://github.com/TrippyLighting)'s [EthernetBonjour](https://github.com/TrippyLighting/EthernetBonjour) library.

Supports mDNS (registering services) and DNS-SD (service discovery).

## HomeTemperature fork

Release 1.1.1 is maintained for
[AaronWangTT/HomeTemperature](https://github.com/AaronWangTT/HomeTemperature).
It adds bounded packet handling, send-error reporting, reusable responder
lifecycle methods, and a borrowed transport abstraction for platforms without
the Arduino `UDP` base class. Existing sketches remain source-compatible when
their `EthernetUDP` or `WiFiUDP` transport implements `beginMulticast()` and the
other operations listed below. The AZ3166 Core's legacy `WiFiUDP` does not
provide that API; use `AZ3166MulticastUDP` instead. Custom transports can pass
`false` as the second constructor argument to skip the legacy WIZnet boot
delay. Release 1.1.1 additionally validates DNS names and record payloads,
preserves state across allocation and transport failures, handles full 14-bit
compression offsets, and makes timeout callbacks safe to re-enter.

The AZ3166 Board Package identifies its downstream build as
`1.1.1-az3166.1`; see `UPSTREAM.md` for the maintained release and downstream
changes.

The `textContent` argument to `addServiceRecord()` uses the existing wire-format
contract: pass one or more DNS character-strings, each prefixed by its one-byte
length. For example, `"\x06" "path=/"` advertises `path=/`.

## Requirements

Any Arduino core and networking library that provides a UDP-compatible object
with the operations used by `MDNS`, including:

 * AVR core 1.6.18 or later (bundled with IDE 1.8.2 and later) for AVR boards
 * SAMD core 1.6.13 or later for SAMD boards
 * Arduino Ethernet and WiFi101 libraries
