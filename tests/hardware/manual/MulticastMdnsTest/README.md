# AZ3166 multicast mDNS hardware test

This manual test validates the `AZ3166MulticastUDP` transport and bundled
ArduinoMDNS library on a real DevKit.

Core CI compiles `MulticastMdnsTest.ino` with the normal sketch inventory, but
does not upload it or execute any hardware, network, serial, UAC, or PktMon
steps. Run the PowerShell entry point below explicitly for hardware validation.

## Prerequisites

- Connect the board through its ST-Link USB port.
- Store a working Wi-Fi configuration on the board.
- Connect the test PC and board to the same IPv4 LAN.
- Disable VPN software that may redirect or block multicast traffic.
- Install the pinned build tools with
  `tools/build/Install-Az3166BuildTools.ps1`.
- Run from an account that can approve a Windows UAC prompt. PktMon requires
  elevation only while capturing UDP port 5353.

## Run

From the repository root:

```powershell
& .\tests\hardware\manual\MulticastMdnsTest\Test-MulticastMdnsHardware.ps1 `
    -Port COM3 `
    -ArduinoCli C:\azsdk\arduino-cli.exe `
    -ArduinoDataDirectory C:\azsdk\portable
```

Use `-SkipTtlCapture` only when elevated packet capture is unavailable.

## Acceptance

The runner requires all of the following:

- compilation from the current checkout;
- OpenOCD upload success;
- connection using the board's stored Wi-Fi configuration;
- responder startup;
- Wi-Fi disconnect/reconnect and multicast rejoin;
- A, PTR, SRV, TXT, service port, and IPv4 response content;
- DNS-SD TXT character-string length;
- IPv4 TTL 255 on captured board mDNS responses.

The test installs a validation sketch. Restore the intended production firmware
afterward.
