Core 3.1.2 supersedes the mutable Core 3.1.0 and 3.1.1 releases for
HomeTemperature Board Manager publication. Those releases were correctly built,
but repository release immutability was not enabled when they were published.
The existing Board Manager index pull request for 3.1.1 must not merge. Publish
only Core 3.1.2 after repository release immutability is confirmed enabled.

Core 3.1.2 contains the same latest maintenance OTA fixes as 3.1.1:

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
boot-attempt counters, or health-confirmation logic. The package contains no
private signing key. The Board Manager index update remains a separate
repository, branch, and pull request after the immutable 3.1.2 release exists.
