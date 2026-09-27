Core 3.1.0 adds a transport-independent, streaming OTA staging API for signed
`AZPKG001` packages.

- Authenticates the fixed package header and P-256 signature before application
  admission or OTA-partition erase.
- Validates runtime partition bounds, application vectors, canonical firmware
  metadata, and the embedded compatibility descriptor.
- Performs bounded erase/write operations, streaming SHA-256 and CRC16/XMODEM,
  and complete external-Flash read-back verification.
- Binds activation to the current verified session generation and digest.
- Verifies persisted boot metadata and restores the prior entry on a provable
  activation failure; reports uncertain activation when recovery cannot be
  proven.
- Retains `OTADownloadFirmware()` and `OTAApplyNewFirmware()` as deprecated
  unsigned raw-image compatibility APIs.

This release provides the Core staging engine and tests. It does not add
HomeTemperature HTTP routes or browser UI, automatic reboot, A/B rollback,
boot-attempt counters, or health-confirmation logic. The published package
contains no private signing key.
