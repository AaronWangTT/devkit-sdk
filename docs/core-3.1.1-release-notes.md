Core 3.1.1 supersedes Core 3.1.0 for HomeTemperature and includes all signed
OTA staging changes plus the production P-256 signature adapter remediation
merged after 3.1.0 was published. Core 3.1.0 must not be added to the
HomeTemperature Board Manager index.

- Authenticates the fixed `AZPKG001` package header and raw P-256 `r || s`
  signature before application admission or OTA-partition erase.
- Uses the production Mbed TLS signature adapter exercised by direct
  known-answer host tests, including tampered digest/signature, wrong-key, and
  malformed-key rejection.
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
contains no private signing key. The Board Manager index update is intentionally
handled in a separate repository, branch, and pull request.
