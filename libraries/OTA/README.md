# AZ3166 OTA library

The OTA library has two deliberately separate update paths.

## Signed streaming package staging

`OTAStaging.h` provides the transport-independent path for new applications:

1. Call `OTAStagingBegin()` with the complete package size, a trusted P-256
   public key encoded as an RFC 5480 DER SubjectPublicKeyInfo, policy callbacks,
   and callback context.
2. Pass every package byte, in order and with arbitrary chunk boundaries, to
   `OTAStagingWritePackage()`.
3. Call `OTAStagingFinish()` and retain its nonzero session generation and
   SHA-256 digest.
4. After application policy permits reboot, call `OTAStagingActivate()` with
   that exact generation and digest.

The package is:

| Offset | Size | Content |
| ---: | ---: | --- |
| 0 | 64 | `AZPKG001` envelope prefix |
| 64 | 256 | authenticated `AZOTA001` compatibility descriptor |
| 320 | 64 | raw P-256 ECDSA signature (`r || s`) over the 320-byte header |
| 384 | variable | raw application image |

All integers are unsigned little-endian. The engine authenticates and admits
the fixed header before erasing Flash, streams only the raw image into
`MICO_PARTITION_OTA_TEMP`, and computes SHA-256 plus bootloader-compatible
CRC16/XMODEM. `OTAStagingFinish()` performs a complete Flash read-back and
checks the digest, CRC, vector table, and descriptor copy before entering
`OTA_STATE_READY`. It does not modify boot metadata.

Only the current in-memory Ready session may activate. Activation consumes its
generation/digest capability, writes the boot entry, and verifies both
parameter-partition copies. On failure it restores and verifies the previous
entry. `OTA_ERROR_ACTIVATION_UNCERTAIN` means neither the candidate nor the
previous entry can be proven durable; callers must not describe that result as
safe to retry or as proof that no update is pending.

The application owns the trust anchor and admission policy, including product,
board, and upgrade/downgrade decisions. Authenticated firmware versions are
strict canonical `MAJOR.MINOR.PATCH` values with components from 0 through
65535. A cancellation callback is checked between bounded Flash operations;
it is intentionally not called inside the activation metadata write/verify
critical section.

The normal state flow is `Idle -> Receiving -> Verifying -> Ready ->
Activating -> Activated`. Validation, I/O, or authentication failures enter
`Failed`; cooperative cancellation and `OTAStagingAbort()` enter `Cancelled`.
Callers may start a new session from any non-active state. Starting a new
session invalidates an earlier Ready generation.

Errors are typed by phase: argument/state and package-format errors, trust and
signature errors, admission/cancellation, partition bounds, erase/write/read
and timeout errors, digest/CRC/descriptor/vector verification, and activation
failure versus uncertain activation. `OTAStagingGetStatus()` exposes the last
error and package-received, payload-written, and payload-verified counters.

The public block and maximum-duration constants in `OTAStaging.h` are the
Core-enforced operation budgets. A timeout is detected after the underlying
synchronous primitive returns; it prevents a session from becoming Ready but
cannot preempt a blocked vendor Flash call. Hardware acceptance must measure
the actual worst-case primitive and activation times against those limits.

This is staged replacement, not A/B firmware. The existing bootloader provides
length-and-CRC installation only; it has no rollback, boot-attempt counter, or
health-confirmation protocol.

## Deprecated legacy raw-image download

`OTADownloadFirmware()` remains available for source and behavior
compatibility. It accepts a URL and writes an **unsigned raw application
image** directly to the OTA partition while calculating CRC16. It does not
parse or authenticate the signed package envelope and does not call the
streaming staging API. New applications must not use it for trusted updates.

`OTAApplyNewFirmware()` is retained with the same legacy behavior and return
codes. It does not provide the session-bound persistence verification of
`OTAStagingActivate()`.
