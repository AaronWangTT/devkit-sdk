# Azure IoT Separation

## Release Contract

Keep one Board Manager package identity and numeric version line. Normal future
releases use a `base` profile without Azure IoT. Publish a complete `azure-iot`
board package only for selected releases that need Azure support. This is not a
separately distributed Arduino library or an automatically downloaded add-on.

Publish only one profile for each version. Record the profile, source revision,
archive hash, and validation results in release evidence. An upgrade from an
Azure-enabled version to a newer base version removes Azure support; document
the last supported full version and how Azure users pin it. Introduce the
default-profile change in a major release, never by replacing an existing tag.

## Current Work

Starting revision: `4be352297a739e4678ba1d94d200039ced0ef069`.
Branch: `refactor/azure-iot-separation`.

Steps 1-4 established the boundary. Steps 5-7 now implement production profiles,
both-profile CI, and guarded release tooling. Checkout staging defaults to `base`;
request `azure-iot` explicitly for a complete Azure-enabled board package.
Neither profile ships the original monolithic archive. It remains an immutable
repository input to the deterministic splitter.

No version bump, release tag, external index edit, or release publication
is included. The runtime version is still the development baseline;
release tooling rejects publication until the next major version is approved.

Hosted validation and review results belong to the pull request for the exact
committed head. The local evidence below is a separate validation checkpoint.

## Ownership Boundary

| Surface | Base responsibility | Azure-enabled responsibility |
| --- | --- | --- |
| Arduino, BSP, Sensors | Runtime, peripherals, sensor APIs, neutral logging and timing | Cloud connection-string convenience APIs move out of Sensors |
| WiFi, sockets, TLS, HTTP, generic MQTT, WebSocket, NTP | Retain existing non-cloud transport APIs | Azure SDK transport adapters consume these lower layers |
| EEPROM and STSAFE | Preserve hardware access, existing storage offsets, and stored bytes | IoT Hub/DPS credential interpretation and configuration |
| Configuration CLI and HTTP server | WiFi and neutral settings, extension integration | IoT Hub/DPS commands, fields, credential handlers |
| OTA | Generic firmware downloader and board update mechanism | IoT Hub twin/version orchestration |
| Telemetry | No implicit Microsoft cloud telemetry dependency in the eventual base profile | Existing Azure Application Insights implementation and cloud events are optional |
| Azure wrapper | None | [libraries/AzureIoT](../libraries/AzureIoT), IoT Hub and DPS APIs |
| Azure C SDK | None | [vendor/azure-iot-sdk-c](../vendor/azure-iot-sdk-c), matching implementations, licenses |
| Examples and provisioning tools | Non-Azure examples | Cloud examples, Azure library examples, DICE enrollment tooling |
| Physical board constants | Keep pin names and LED definitions, including `LED_AZURE` | A hardware label is not a cloud dependency |

Generic cryptography and TLS objects must remain in base even when Azure uses
them. Classify shared JSON, utility, and authentication objects by callers and
symbol ownership, not by broad filename matching. Standalone cloud examples and
provisioning tools are already outside the regular board payload roots.

## Steps And Gates

### 1. Define And Verify The Boundary

Inventory direct includes, runtime calls, configuration ownership, and archive
members. Recheck against the starting revision rather than relying on the older
networking inventory: PR #17 already changed logging and OTA ownership.

Gate: every identified non-Azure consumer of Azure APIs has an explicit
decoupling action; generic networking, TLS, storage, and OTA stay supported.

Status: complete. `IoT_DevKit_HW.cpp/.h` stay in Sensors because they own board
setup, sensors, LEDs, buttons, display, and IrDA. Only
`getIoTHubConnectionString()` moves into AzureIoT; sensor use no longer discovers
the Azure library. The base source groups have no remaining Azure SDK includes,
IoT Hub/DPS configuration commands, or Azure credential aliases.

### 2. Decouple Base Source

Replace the Azure shared-utility timer with a native monotonic 64-bit source.
Do not simply use `millis()`: the existing implementation divides a wrapping
32-bit microsecond counter. Verify initialization, rollover, long uptime, and
concurrent reads with the actual Mbed interfaces available in this snapshot.

Remove cloud credential convenience APIs from Sensors and isolate Azure
configuration/telemetry behind a base-owned neutral boundary. Preserve existing
storage offsets; do not erase or migrate saved credentials. Keep the full
configuration experience usable through explicit full-build integration.

Gate: focused host regressions pass; a base source compilation has no Azure SDK
include dependency; representative non-Azure and full cloud target builds pass.
Hardware behavior must be reported separately from compile/link evidence.

Status: complete, with hardware validation still required. The native timer
accumulates unsigned microsecond deltas into 64 bits under Mbed critical sections;
a one-second `Ticker` samples it even without application reads. It requires the
hardware ticker and interrupts to keep progressing: interrupt masking longer
than the 32-bit ticker period, deep-sleep clock suspension, and physical timing
accuracy are not proven by the host simulation. Repeated initialization does
not reset elapsed time.

[ConfigurationProvider.h](../src/extensions/configuration/ConfigurationProvider.h)
defines a static build-selected provider for commands, fields, parsing, and save
results. The full provider lives under `libraries/AzureIoT/platform`; the base
provider exposes no optional fields or commands. EEPROM methods remain neutral
storage APIs with identical zone numbers and byte formats. The base telemetry
stub has no Azure endpoint or SDK dependency; the existing full telemetry
implementation remains opt-in through `ENABLETRACE`.

Compatibility changes: include `AzureIotHub.h` for the relocated credential
helper, and explicitly include `azure-iot/AzureConfiguration.h` for the legacy
`AZ_IOT_*`, `DPS_UDS_*`, and `WEB_SETTING_IOT_*` constants in full builds. These
are no longer supplied by Sensors, EEPROMInterface, or SystemWeb. The C-facing
Azure header remains independently compilable. During extraction, credential
commands became private, invalid UDS lengths are rejected, assembled DPS strings
are bounded, and missing multipart boundaries return an error. This is not a
general HTTP parser or configuration-security audit.

### 3. Prove Azure Archive Linking

Use the pinned Arduino CLI and GCC to prove that an Azure sketch can discover
its headers and link an Azure-owned precompiled archive. The library is an
internal ownership boundary, not a new distribution product. If this platform's
recipes do not support library-owned precompiled archives, validate a full-only
platform include/link overlay instead. Do not add a new toolchain to force a
preferred layout.

Gate: representative IoT Hub and DPS link probes pass without globally visible
Azure headers in the base build. Confirm the actual link command and map, not
only Arduino library metadata. Record the selected approach and its limitations.

Status: complete; select the full-only platform overlay. CLI 1.5.1 discovers
the projected SDK headers and `precompiled=true` archive but reports:
`The platform does not support 'compiler.libraries.ldflags' for precompiled libraries.`
The existing link recipe consequently omits that archive. Retained negative
evidence proves the failure was not masked by the global SDK paths or original
system archive. Explicit Azure archive search/link flags succeed without
altering the production recipe. Azure precedes base in the tested link order;
no new archive group or ABI flags were needed.

### 4. Split The Prebuilt Archive

Prefer recovering matching source/build recipes. If unavailable, retain the
original immutable archive as provenance and implement a reproducible,
hash-pinned member partition into base and Azure archives. This is repackaging
existing binary objects, not rebuilding or establishing their security status.

Before splitting, verify member uniqueness and object ABI. Preserve every
original member exactly once, byte-for-byte, and retain symbol ownership and
dependency evidence. Reject changed input hashes, missing/unknown members,
duplicates, and Azure dependencies from base objects. Validate link order and
archive-group behavior rather than assuming all dependencies are one-way.

Gate: reproducible partition; complete member/hash accounting; base-only target
links without Azure definitions; full target links with the split archives;
record flash/RAM and linked-symbol changes. Keep the original input available
for rollback, outside future base distribution.

Status: complete as reproducible binary repackaging, not a source rebuild.
[The partition manifest](../tools/build/az3166-azure-archive.json) pins the input
SHA-256 and lists 110 Azure member identities by name and occurrence. It preserves
the duplicate `certs.o`, `sha1.o`, and `version.o` instances separately: each first
instance is Azure, each second instance is Mbed TLS. Broad filename deletion or
ordinary extraction without occurrence selection is unsafe.

[Split-Az3166CoreArchive.ps1](../tools/build/Split-Az3166CoreArchive.ps1) verifies
all 473 output occurrences against the original bytes and rejects unknown,
duplicate, missing, changed, or misclassified inputs. There are no base imports
requiring Azure definitions and no conflicting strong definitions; eight shared
weak Mbed callback/template definitions are recorded. Source object attributes
are uniformly ELF32, little-endian ARM, Cortex-M4/v7E-M, EABI5. No object was
recompiled and no original archive was modified.

Linux GNU ar and the pinned Windows ARM ar produce identical results:

| Archive | Members | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| Base | 363 | 2,026,548 | `590ad5c7734751edb19bb300a8f52681e3e7b284351fb599678a515393f1ca03` |
| Azure | 110 | 948,728 | `f36eb8d5292528eed93330f7442f269221e98f88db6cd3f07d8f247dba56acfe` |

The original `4c286c680d900e6db1d500d95526bb68ea657c2b671c5e25b0b0b7080929d055`
archive remains the rollback/provenance input. Original implementation revision,
complete build flags, security patch status, and matching source/build recipes
are still unknown. Package-size savings are not firmware-size savings; the
linker already discards unreferenced objects and sections.

### 5. Production Package Profiles

[The schema-2 layout](../platform/az3166/package-layout.json) owns profile
membership. Every payload input is still accounted for, including inactive
profile inputs. Base/full provider files can share an installed destination
without both being compiled. Azure Application Insights implementation files
live under `libraries/AzureIoT/platform/telemetry`; the neutral telemetry header
and base stub stay under `src/extensions/telemetry`. Configuration and telemetry
are grouped with their Azure library owner, outside its sketch-selected `src`
tree. Explicit full-only mappings retain their original installed Core paths;
the platform sources are not duplicated into the installed Arduino library.

Shared staging and package entry points accept `-Profile base|azure-iot` and
`-Ar`/`-Nm`. Base uses only `libdevkit-sdk-base.a`. Full adds SDK headers,
AzureIoT, Azure configuration/telemetry, `libdevkit-sdk-azure.a`, and
[platform.local.txt](../platform/az3166/azure-iot/platform.local.txt), which
supplies the Azure include and link flags. Generic TLS, MQTT, Sensors, Audio,
HTTP, and OTA remain available in base.

Both profiles contain `package-profile.json` with profile, source revision,
partition hash, original archive hash, and shipped archive hashes. Packages are
named `AZ3166-<version>-base.zip` or `AZ3166-<version>-azure-iot.zip`. Historical
schema-1/no-manifest revisions retain their full payload and original filename;
they reject a misleading base-profile request.

For revision-backed packaging, the splitter, original archive, and partition
manifest are extracted from that revision, never from working-tree copies.
Generated bytes are added to a temporary Git index and archived with the existing
fixed timestamp/order rules. The user's index is not changed. A negative fixture
corrupts all three working-tree inputs and verifies both committed profile trees
remain identical.

Status: implemented; layout, archive, immutable-input, staging, and representative
production target checks pass locally.

### 6. Profile-Specific Validation And CI

[The shared sketch driver](../tools/test/Test-Az3166Sketches.ps1) now selects the
production profile and its explicit inventory: 13 base sketches and 16 full
sketches. Both include SensorStatus and the existing VoiceRecord example. Audio
coverage must not depend on the Azure-only VoiceToTwitter example. Full adds the
two cloud examples and the explicit IoT Hub/DPS probe.

The shared native runner executes four programs for base and six for full.
Warnings use the active profile's mappings and allowances. Base has no Azure
allowance; full must exercise it. Complete inventories still reject every stale
allowance. Logs retain the profile, partition, platform/overlay, and archive
metadata hashes; offline warning validation rejects missing or mismatched
profile provenance. Base firmware must define zero Azure-only symbols, while
cloud probes must actually link Azure definitions.

[Core package CI](../.github/workflows/core-package-ci.yml) checks both profiles
on every run, not only when an Azure release is requested. Linux runs native
tests; Windows runs ARM target builds. Both hosts verify deterministic archives
per profile, including historical canonical-package checks. Archive tools are
selected before packaging, and all failed/successful build evidence is retained
under separate profile directories. The workflow can also validate an exact
revision when called by the release workflow.

Status: implemented; local validation is recorded below. Hosted CI has not run
for these uncommitted changes. Physical-board tests remain separate.

### 7. Guarded Release And Index Handoff

[Core release](../.github/workflows/core-release.yml) is manual. Its `version`
must name an approved numeric tag on `maintenance`; its `profile` must match
`releaseProfile` in that tag's layout. Normal tags record `base`; a selected
Azure-enabled tag records `azure-iot`. `defaultProfile` remains `base` for normal
checkout builds. One profile is published per version on the existing package
identity, not as an add-on or parallel Board Manager product.

The workflow refuses publication on the old major-version line and requires
explicit, default-off `hardware_validated` confirmation covering board acceptance
and original-versus-split firmware review. It calls the two-profile CI workflow
at the resolved tag commit, rebuilds the selected package, and checks equality
to CI's artifact before publication. It rechecks the remote tag and uses
`gh release create`, never overwrite/clobber operations.

[The release helper](../tools/package/Az3166Release.ps1) emits
`release-profile.json` containing the selected profile/revision and the URL,
archive filename, checksum, size, and version for the existing external Board
Manager entry. These fields are a reviewed handoff, not a complete replacement
index: preserve its package identity, architecture, boards, and tool dependencies.
Merge them into the separately maintained index only after publication approval.
Never retarget an existing version to another profile or hash. Document which
Azure-enabled version users must pin before upgrading to a later base release.

Status: release tooling and rejection contracts implemented; no release or
external index update performed. Hardware confirmation is operator attestation,
not automated hardware evidence.

### Step 5-7 Validation

Evidence is retained under `C:\Users\yuwag\AppData\Local\az3166-p57` and
`/tmp/az3166-p57-packages`. The package comparison used immutable Git tree
`7c4540630852b9bfa93f1ad5b181824c0cf28885`, created through a temporary index
without committing or changing the caller's index. Subsequent test/documentation
edits are not part of that snapshot's identity.

| Gate | Local result |
| --- | --- |
| Production base | 13 sketches pass; 0 Azure-only definitions in each ELF; 35 allowed warnings, 0 first-party, no stale allowances |
| Production full | 16 sketches pass; direct SDK, HTTP cloud, wrapper/DPS, Sensors, and Audio covered; 72 allowed warnings, 0 first-party, no stale allowances |
| Native profiles | Four base and six full programs pass with sanitizers where supported |
| Package/contract checks | 15 layout tests, 9 archive/immutable-packaging groups, 4 release-profile groups, compiler-parameter contracts, build-configuration and warning-evidence tests pass |
| Failure evidence | Real Windows compile/link/preparation failures are retained and subsequent valid builds still run; invalid sketch layout is rejected |
| Workflow validation | Both workflows pass actionlint; all 21 embedded PowerShell blocks parse |
| Historical release | Canonical 2.0.2 remains 5,497,641 bytes with SHA-256 `5914d3e7b988fdc50b00ff241b7ac191fd6fb9bdc234b4a3f86c51ed0d5e9677` |

Windows ARM binutils and Linux GNU binutils produced identical snapshot ZIPs:

| Profile | Bytes | SHA-256 |
| --- | ---: | --- |
| Base | 4,961,532 | `50dbef32d5f0f656b0bd09072bc43cb416b948c283d126b13b66155a2ba33d85` |
| Azure IoT | 5,501,725 | `0d7f75b53658d3fc5b95ddf637c8dcb7cafcf6ae4ea799ffa00061c93d6ec2b9` |

The 540,193-byte ZIP difference is measured download size, not a claimed firmware
saving. The publish/index handoff has not been executed. Hardware
and firmware-equivalence review remain release prerequisites.

### Final Ownership Validation

The five Azure platform source/header files were consolidated under
`libraries/AzureIoT/platform` without changing any implementation bytes or
installed paths. Complete before/after staged inventories match for all 729
base files and 885 full-profile files, including generated archives and profile
metadata. Only source ownership and its diagnostic/test references change.
Neutral configuration and telemetry interfaces/stubs remain outside AzureIoT.

Final local checks after the move:

- 16 layout contracts, archive/immutable-packaging, release, compiler-parameter,
	build-configuration, warning, and build-evidence contracts pass.
- Four base and six full native programs pass with sanitizer coverage.
- Windows installer, layout, build-configuration, and release contracts pass.
- All 13 base and 16 full ARM sketches pass with zero first-party warnings and
	no stale allowances (35 base and 72 full allowed occurrences).
- Full BoardInit also links without selecting the AzureIoT Arduino library;
	the configuration/telemetry services remain full-profile platform code.
- Both workflows pass actionlint; documentation links and whitespace pass.

Evidence: `/tmp/az3166-azure-ownership.9m0oPJ`,
`/tmp/az3166-ready-host-b58102d90f444ec19d6699f4f4f4e987`, and
`C:\Users\yuwag\AppData\Local\az3166-ownership\ready-6949e101`.

### Archive Equivalence Limit

Fixed-output relinking of identical compiled objects against original versus
split archives produced identical BoardInit BIN/ELF. AzureIotHubExample and the
DPS probe linked the same defined symbol names, types, and sizes, but addresses
and firmware bytes differed: flash changed by 12 and 4 bytes respectively, and
RAM by 4 bytes in both cases. Replaying split links reproduced their retained
binaries exactly. This is not a proof of runtime equivalence; original-order
versus split-order layout/weak-symbol effects and hardware behavior still need
release review. Evidence: `az3166-azure-work/archive-verify-aa71de13` beneath the
Windows local application-data directory. Publication remains gated on that
review and physical acceptance.

## Step 1-4 Evidence

Local validation used portable PowerShell 7 on Linux and the existing verified
Windows Arduino CLI 1.5.1/GCC 5.4.1 installation. A disposable Windows-local
checkout avoids modifying the installed board package. Evidence is retained
under `C:\Users\yuwag\AppData\Local\az3166-azure-work`.

| Gate | Result |
| --- | --- |
| Shared host runner with `-Sanitize` | Six programs pass: timer, base/full configuration, version, WiFiUDP, legacy IoT client; includes the existing 19 client regression cases |
| Timer regression | Initialization, sub-ms accumulation, 32-bit rollover, simulated uptime beyond 49 days without application reads, and serialized interrupt reads pass |
| Configuration regression | Fixed storage zones, credential helper failure/cache behavior, maximum-length real multipart parsing, oversize/missing fields, write failures, private CLI metadata, and no-op base behavior pass |
| Archive contracts | Eight tests pass, including reproducibility, duplicate occurrences, changed hash/count, unknown/unsafe identity, incorrect classification, and output protection |
| Package/build contracts | 11 package-layout and 15 build-configuration tests pass; warning-policy and build-evidence contracts pass |
| Current full build/warning gate | Original 13 sketches plus explicit Azure DPS probe pass; 0 first-party warnings, 43 allowed occurrences, no stale allowances |
| Split base matrix | All 11 non-cloud baseline sketches plus SensorStatus pass with zero Azure-only symbols in every ELF and no SDK headers/library/configuration implementation present |
| Split full matrix | All 13 baseline sketches plus SensorStatus and the IoT Hub/DPS probe pass; direct SDK, HTTP cloud example, wrapper, and DPS paths link |
| Final focused validation | IoT Hub/DPS and VoiceToTwitter repeat successfully after public-header and multipart-capacity corrections; standalone C Azure/timer headers and base telemetry compile |

At the step 1-4 checkpoint the shared target inventory was deliberately expanded
to 14, not reduced to non-cloud tests. Previously Sensors caused incidental Azure-wrapper coverage;
[AzureDpsLinkProbe](../tests/host/package/fixtures/AzureDpsLinkProbe/AzureDpsLinkProbe.ino)
now owns that coverage and keeps the Azure warning allowance exercised. The
fixture is compile-only and leaves cloud operations disabled by default.

Representative split-profile GNU-size results (bytes, using existing flash/RAM
accounting) are below. Equal non-cloud RAM and a 2,736-byte flash difference
reflect the optional configuration implementation, not the entire Azure SDK.

| Sketch | Base Flash / RAM | Full Flash / RAM |
| --- | --- | --- |
| BoardInit | 219704 / 45156 | 222440 / 45156 |
| SensorStatus | 382840 / 45868 | 385576 / 45868 |
| UnitTest | 419436 / 47808 | 422172 / 47808 |
| AzureIotHubExample | Not a base sketch | 478720 / 52836 |
| AzureDpsLinkProbe | Not a base sketch | 539536 / 51592 |

Reproduce the native and partition gates with GNU `ar`/`nm` on PATH (or pass
their pinned ARM paths through `-Ar` and `-Nm`):

```powershell
pwsh -File ./tools/test/Test-Az3166HostTests.ps1 -Sanitize
pwsh -File ./tests/host/package/AzureArchiveTest.ps1
pwsh -File ./tools/build/Split-Az3166CoreArchive.ps1 -OutputDirectory ./artifacts/split
```

The earlier experimental profile driver has been retired. Use
[Test-Az3166Sketches.ps1](../tools/test/Test-Az3166Sketches.ps1) with the verified
`-ArduinoCli`, `-ArduinoDataDirectory`, `-ArduinoUnitDirectory`, a fresh
`-OutputDirectory`, and `-Profile base` or `-Profile azure-iot`. It now performs
the real production staging, warning, and symbol checks; no temporary recipe
mutation or pre-generated `-ArchiveDirectory` is needed. Both full inventories
must pass. Use `-Sketch` only for focused iteration, not release acceptance.

No physical-board tests, live cloud operations, external index updates, or
releases were performed. Packaging consumes committed revisions; use staging
to validate uncommitted changes. Historical package generation remains unchanged.
The production default-profile switch is release-gated, not published.