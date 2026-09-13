# AZ3166 Core Structure And Hardening Plan

Recorded: 2026-09-13.

Scope: the maintained devkit-sdk Core supporting HomeTemperature. This is a
repository planning document, moved from local notes into `docs` at the user's
request. [PR #8](https://github.com/AaronWangTT/devkit-sdk/pull/8) separated examples,
tests, and maintained tools. [PR #9](https://github.com/AaronWangTT/devkit-sdk/pull/9)
separated root source/libraries and archived tooling and was squash-merged as
`8e4d1b76d1dd3ec33bbe77dc2b9d4f39171d5cfc`.
[PR #10](https://github.com/AaronWangTT/devkit-sdk/pull/10) implemented the final
ownership layout with a shared package map and build/test entry points and was
squash-merged as `d55d91677cfde6bbbc9c2478df15412344617bb8`. Compiler upgrades,
binary-library rebuildability, hardware automation, and repository policy
changes remain future work.

## Current Checkpoint

- The remaining 728 platform files were classified as 24 Core files, 30 BSP and
  integration files, 54 extension files, 616 vendor files, and 4 metadata files.
  Every move preserves the original Git blob. The 210 library files, ten library
  packages, and 15 co-located examples remain intact.
- [package-layout.json](../platform/az3166/package-layout.json) maps ownership
  paths to the original installed locations. The same resolver drives committed
  packaging and checkout staging. It rejects missing/unmapped inputs, duplicate
  source mappings, destination collisions, and invalid relative paths.
- Packaging reads the map and payload from the selected Git revision, not from
  uncommitted files. It uses an isolated temporary index and the installed
  `AZ3166/` prefix; public includes and default service inclusion do not change.
- The 39-file DICE bundle is under `tools/provisioning/dice_device_enrollment`;
  the 25-file Jenkins hierarchy is under `legacy/jenkins`. The two orphaned
  VoiceToTwitter metadata files were removed, along with empty wrapper folders.
- The plan is now in this repository. See [the root layout](../README.md) and
  [legacy tooling limitations](../legacy/README.md). No legacy tools were run.
- The reconstructed Git platform tree matches the original
  `6078298ccace227b969394a5d16c87464cc8dee3`. The archive checkpoint is 5,497,759
  bytes with SHA-256
  `6ba048484edc4b118f3eb5dfd80280649380bf08d5f11613a895f8064b759d6d`.
- Checkpoint gates are the unchanged archive, historical-tag packaging,
  preserved 13-sketch inventory, host compile/link checks, workflow source-path
  selection, and documentation/configuration path validation. Native and
  physical-device execution must be reported separately.

## Build Sources And Tests

Run commands below from the repository root. The maintained entry points require
PowerShell 7 or later and Git with support for `git archive --mtime`.

For target builds, use the existing pinned Windows toolchain: Arduino CLI 1.5.1,
Arduino IDE 1.8.19 bootstrap, AZ3166 GCC `5_4-2016q3`, and the immutable package
index specified by [Core package CI](../.github/workflows/core-package-ci.yml).
The workflow installs and verifies the toolchain on a clean Windows runner. Keep
the historical GCC installation path short; changing its version or ABI flags is
not part of this layout migration.

### Compile All Target Projects

```powershell
pwsh -File ./tools/test/Test-Az3166Sketches.ps1
```

This discovers the same 13 projects under `examples` and `tests/hardware`, stages
the complete mapped Arduino platform in a temporary sketchbook, and invokes
Arduino CLI with FQBN `AZ3166Checkout:stm32f4:MXCHIP_AZ3166` and warnings enabled.
It compiles the Core, board integration, extensions, and sketch-selected Arduino
libraries and links the existing vendor archives. It does not rebuild Mbed,
MXCHIP, STSAFE, or other components whose implementation is available only in
prebuilt archives. The 15 library examples are not part of this default scan.

Compile one project or supply explicit installed tool locations:

```powershell
pwsh -File ./tools/test/Test-Az3166Sketches.ps1 -Sketch ./tests/hardware/UnitTest
pwsh -File ./tools/test/Test-Az3166Sketches.ps1 `
  -ArduinoCli C:/tools/arduino-cli.exe -ArduinoDataDirectory C:/a/portable
```

The second command illustrates custom paths; use the locations actually installed
on the machine. The default data directory on Windows is `%LOCALAPPDATA%/Arduino15`.
Builds fail on compiler errors and report flash/RAM usage. Temporary build files
are currently removed when the driver exits; retaining diagnostics/artifacts is
still a hardening task.

### Inspect Or Integrate The Platform

```powershell
pwsh -File ./tools/package/Stage-Az3166Platform.ps1 -Destination ./artifacts/platform
```

Use an empty destination. Staging copies current checkout contents, including
non-ignored new files in declared payload roots, according to the map. It never
overwrites an existing nonempty platform. The generated tree has the original
Arduino layout and is suitable for inspection, editor include paths, or manual
integration. It is not an editing location or an immutable release artifact;
regenerate it after source changes. The build/test drivers perform their own
temporary staging and do not require this manual step.

There is no supported direct build of the ownership directories as if `src`
were still an Arduino platform. Do not copy `src`, `vendor`, or individual
extensions directly into an installation or invent a second include-path map.

### Compile Host Programs Without Running

With a native GCC compiler on `PATH`:

```powershell
pwsh -File ./tools/test/Test-Az3166HostTests.ps1 -CompileOnly
```

For compile/link verification with the installed ARM compiler on Windows:

```powershell
$compiler = Join-Path $env:LOCALAPPDATA 'Arduino15/packages/AZ3166/tools/arm-none-eabi-gcc/5_4-2016q3/bin/arm-none-eabi-g++.exe'
& ./tools/test/Test-Az3166HostTests.ps1 -Compiler $compiler `
  -CompileOnly -LinkerFlags '-specs=nosys.specs'
```

The cross-compiled harness executables are not hardware test firmware. They must
not be flashed or counted as executed tests. The runner removes its temporary
outputs when it exits.

## Run Tests

### Package-Layout Contracts

```powershell
pwsh -File ./tests/host/package/PackageLayoutTest.ps1
```

These tests need PowerShell and Git, but no C++ compiler, board, or cloud service.
They use isolated temporary repositories to exercise working/revision parity,
staging content, revision isolation, missing/unmapped inputs, collisions,
traversal, required files, and multiple Git executables on `PATH`. They do not
alter the caller repository or create application commits.

### Native C++ Regression Tests

On a host with native GCC and AddressSanitizer/UndefinedBehaviorSanitizer support:

```powershell
pwsh -File ./tools/test/Test-Az3166HostTests.ps1 -Sanitize -ExpectedVersion 2.0.2
```

The version is the current Core version, not a permanent pin for future releases;
omit `-ExpectedVersion` to derive it from the staged header. CI supplies the
verified package version to check consistency. The runner stages the platform,
compiles the programs, executes each one, and fails on any nonzero exit status.

| Program | Coverage | Execution |
| --- | --- | --- |
| `SystemVersionTest.cpp` | Core runtime-version API versus expected version. | Native executable. |
| `WiFiUdpTest.cpp` | 11 WiFiUDP lifecycle, data, and failure cases. | Native executable with ASan/UBSan when `-Sanitize` is set. |
| `IotClientTest.cpp` | 8 legacy-client response/state regression cases. | Native executable with ASan/UBSan when `-Sanitize` is set. |

Client harnesses compile implementation code with explicit transport, parser, and
other dependency fakes. Passing them does not validate the ARM-only vendor code,
real network timing, or the actual Parson parser. Successful `-CompileOnly` output
is not runtime test evidence. Native C++ execution is performed on Ubuntu CI;
availability on a local machine depends on its compiler installation.

### Physical-Board Tests

`tests/hardware/UnitTest` is the ArduinoUnit device suite;
`tests/hardware/manual/HttpTest` is an unbounded HTTP/NTP/heap stress diagnostic.
The sketch driver only compiles them. Neither maintained test entry point flashes
a board or collects hardware pass/fail results. A physical run requires separate
authorization, a suitable flashing setup, serial capture, and any necessary
wiring/network fixtures. Automated trusted-board execution remains planned work;
do not use the archived Jenkins tooling as an implicitly supported replacement.

## Build And Publish The Core Package

### Verify An Immutable Revision

```powershell
pwsh -File ./tools/package/Test-Az3166BoardPackage.ps1 `
  -Revision HEAD -ExpectedVersion 2.0.2 -OutputDirectory ./artifacts/packages
```

This builds the selected committed revision twice, requires matching size/hash,
and verifies the packaged version header. It returns the archive path, resolved
commit, version, size, and SHA-256. Uncommitted source, map, or header changes are
not included. To create a single archive without the repeated-build check:

```powershell
pwsh -File ./tools/package/New-Az3166BoardPackage.ps1 `
  -Revision HEAD -OutputPath ./artifacts/AZ3166-2.0.2.zip
```

Prefer the verifier for release evidence. Both commands accept an existing tag or
commit as `-Revision`. Old layouts without a manifest retain historical fallbacks.
The canonical historical check remains:

```powershell
pwsh -File ./tools/package/Test-Az3166BoardPackage.ps1 `
  -Revision 2.0.2 -ExpectedVersion 2.0.2 -OutputDirectory ./artifacts/canonical
```

The canonical tag intentionally differs from later maintained 2.0.2 source
commits. Its established byte size and hash are checked separately by CI; do not
replace that baseline with the current archive hash.

### Publish Through The Release Workflow

1. Merge a reviewed change into `maintenance` and require its exact-commit Core
   package CI results, including Windows sketch compilation, to pass.
2. For a new release, update the numeric version in
   [SystemVersion.h](../src/core/arduino/SystemVersion.h) through the approved
   release process. Create and push a matching numeric tag only when authorized.
   The existing `2.0.2` tag is a verification example, not a release to republish.
3. Dispatch [Core release](../.github/workflows/core-release.yml) from
   `maintenance`, with the existing tag as its `version` input.
4. The workflow checks tag ancestry and version, checks out that tag, rebuilds
   and verifies its package, runs available layout and host tests, then publishes
   the immutable GitHub release archive and SHA-256 in the release notes.
5. Publish the Board Manager index entry in `azureiotdevkit_tools` separately,
   then update consumers to its reviewed immutable index commit. This repository
   does not automatically publish an index or upgrade HomeTemperature.

The release workflow refuses to overwrite an existing release. It currently
repeats package and host checks, but does not rerun the Windows sketch job or
automatically enforce the prior CI result described in step 1. Reusing/enforcing
the full exact-tag CI gate is remaining hardening work, not a guarantee provided
by this structural migration.

## CI Orchestration

Maintained operations belong in the shared scripts above. Workflows select the
runner, install pinned dependencies, call those entry points, and control release
publication. Do not add workflow-only copies of the current map, compiler flags,
or test list. The old inline release commands exist only for tags that predate
the shared host-test runner.

| Workflow/job | Steps and shared entry points |
| --- | --- |
| Core package CI: Windows and Ubuntu | Run `PackageLayoutTest.ps1`; run `Test-Az3166BoardPackage.ps1` for the current revision and canonical 2.0.2; verify caller state; upload the resulting package. |
| Core package CI: Ubuntu | Run `Test-Az3166HostTests.ps1 -Sanitize` with the verified package version, executing both regression suites and the version test. |
| Core package CI: Windows | Set up the pinned Arduino CLI and checksum-verified IDE/Core toolchain; run `Test-Az3166Sketches.ps1` for all 13 projects. |
| Core package CI: comparison | Download both packages and require equal sizes and SHA-256 hashes. |
| Core release | Validate/check out the requested tag; call its package verifier, layout tests, and shared host-test runner when available; use historical compatibility commands for older tags; publish only after its steps succeed. |

[Core package CI](../.github/workflows/core-package-ci.yml) runs on PRs and pushes
to `maintenance`, and supports manual dispatch. A platform-inapplicable matrix
step is intentionally skipped: Ubuntu executes native C++ tests, while Windows
compiles ARM sketches. A skipped hardware execution is not a hardware pass.

Further orchestration work: share the pinned bootstrap with local setup, retain
full compiler/test artifacts, add machine-readable test/coverage reports, and
make a reusable full CI validation gate a prerequisite for tagged publication.

## First-Pass Status

- Moved 11 standalone examples, 3 host-test programs, 2 device-test projects,
  and 3 maintained host tools into the approved top-level directories.
- `HttpTest` is a manual hardware stress diagnostic under
  `tests/hardware/manual/HttpTest`, not a standalone networking example.
- Updated CI/release paths, relative test includes, docs, and two legacy
  UnitTest configuration references. Historical release layouts have fallbacks.
- Preserved all shipped library examples, legacy tool locations, sketch filenames/extensions, and the complete `AZ3166/src` payload. Removed the two orphaned VoiceToTwitter metadata files.
- Removed the two root Azure Pipeline templates and the stale root Board Manager index. The maintained catalog in `azureiotdevkit_tools` is unchanged.
- Validation: all 13 relocated sketches compile; all 3 host programs compile and
  link with ARM GCC; current and canonical 2.0.2 package verification passes;
  workflow syntax, old/new release path selection, and local links pass.
- Native host execution was not repeated locally: both installed WSL distributions lack
  `g++`. No hardware tests ran, and no compiler was installed or upgraded.
- The published PR head is `79fb05016a6c2c009043187daf216c3c86a9a253`; its Core
  archive still matches the pre-reorganization size and SHA-256. Ubuntu CI has
  passed; this first pass is now merged. Consult the PR for its full check history.

## Verified Baseline

- The maintained base is `maintenance`; `master` preserves archived upstream
  history. [PR #7](https://github.com/AaronWangTT/devkit-sdk/pull/7) was squash-merged
  as `ae014865def94318a2fa7bf0fa87acdf4ecd4e1a`.
- Tested head: `9fa57aeedc38f4ad3fd818b7ceab9765159bbe4f`.
- The merge and tested head have identical committed file trees. Local
  `maintenance` is up to date and the local `test/core-tests-ci` branch was
  deleted after verifying that equality. The remote feature branch was retained.
- [CI run 34757318906](https://github.com/AaronWangTT/devkit-sdk/actions/runs/34757318906)
  passed 11 WiFiUDP and 8 legacy-client host tests under ASan/UBSan, compiled
  13 Arduino sketches on Windows, and verified cross-platform Core packages.
- Host tests use dependency fakes. The legacy-client harness does not execute
  the actual ARM-only Parson implementation. No hardware tests were executed.
- Baseline sketch compiler: GNU Arm GCC 5.4.1 (`5_4-2016q3`), GNU C++11,
  Cortex-M4, Thumb, `softfp`, and `fpv4-sp-d16`.
- Core and STSAFE archive metadata identifies GCC 6.3.1; WLAN identifies 4.9.3.
  No matching library rebuild recipes were found in this checkout. Mixed
  versions are not automatically incompatible, but require an ABI audit.

## Pre-Reorganization Inventory

| Original area | Role and problem before reorganization |
| --- | --- |
| `AZ3166/src` | Complete installable Arduino platform, not simply owned source. The package builder archives this committed tree verbatim. |
| `AZ3166/src/cores/arduino` | Mixes Arduino APIs, board runtime/adapters, display, HTTP client/server, NTP, CLI, and telemetry. |
| `AZ3166/src/cores/arduino/system` | Mixes startup/version/timing with WiFi, DNS, web services, logging, and OTA. Classify files individually rather than moving this directory wholesale. |
| `AZ3166/src/libraries` | Arduino library families: Audio, AudioV2, AzureIoT, FileSystem, MQTT, Sensors, SPI, WebSocket, WiFi, and Wire. |
| `AZ3166/src/system` | Vendor/platform dependencies: Mbed, Azure IoT SDK, MXCHIP drivers, configuration, utilities, and prebuilt code. Do not confuse it with `cores/arduino/system`. |
| `AZ3166/src/variants` and `bootloader` | Board-specific metadata, linker/memory layout, and boot support. |
| `AZ3166/tests` | Host regression programs, device tests, and legacy example projects share one tree. Moving examples would currently change sketch discovery. |
| `AZ3166/jenkins`, `AZ3166/tools`, root `tools`, `.github` | Historical deployment, provisioning, maintained packaging, and current CI need distinct ownership. |

The public Arduino umbrella header includes several board/service headers and
exposes the `Screen` object. Moving a service into an independently discovered
library would change more than its path. Preserve public include names and
compilation behavior during the structural migration.

## Category Definitions

- **Core:** required Arduino language/runtime APIs and entry-point integration.
  Utilities such as Print, Stream, WString, and WCharacter remain Core APIs.
- **Board support:** AZ3166 startup hooks, pin/serial/peripheral adapters,
  variant files, linker scripts, and boot support.
- **Libraries:** reusable Arduino library packages with explicit metadata and
  dependencies. Preserve public library names and discovery rules.
- **Extensions:** Core-hosted board or application services above the minimal
  runtime, such as HTTP, NTP, CLI, telemetry, and display services. This term
  does not mean VS Code extensions. Physical separation does not immediately
  make these services optional at build time.
- **Vendor:** upstream snapshots, headers, drivers, and binary-only dependencies,
  with versions, licenses, hashes, and source-availability information.
- **Examples:** demonstrations and complete sample applications.
- **Tests:** executable checks with a defined pass/fail contract; separate host,
  target compile/link, and physical-device execution.
- **Tools:** host-side build, package, test, flash, and provisioning automation.

## Concrete Inventory Findings

- There are 10 library packages with `library.properties` and 15 library example
  sketches. These examples were outside the original `AZ3166/tests` scan and
  remain outside the new `examples` and `tests/hardware` scan; they are not
  covered by the 13-sketch result.
- Keep library examples under `libraries/<LibraryName>/examples` so ownership,
  Arduino discovery, and the installed Examples menu remain intact. Top-level
  `examples` is for standalone applications and cross-library demonstrations.
- `SPITest` and `WireTest` contain example directories, not library source.
  `BoardInit` loops through LEDs and displays motion readings without assertions;
  classify it as a board demonstration/manual smoke sample.
- `UnitTest` uses ArduinoUnit and `Test::run()` and belongs with device-executed
  tests. Pure subtests can be extracted for host execution later.
- `SystemVersionTest.cpp` was a host test under root `tools`; it is now under
  `tests/host/core`.
- The C# `DevKitTestTool` targets .NET Framework 4.6.1 and contains unit-test
  execution, serial capture, example verification, reporting, and packaging
  modes. It is recovery/reference material, not just Jenkins configuration.
  Its current executability was not verified; do not assume it can replace the
  maintained CI runner without porting and validation.

## Ownership Map

The final classification is implemented by the package map. These ownership
directories are not installed paths; filenames and package destinations remain
the same as before the move.

| Current content | Proposed home | Initial treatment |
| --- | --- | --- |
| Generic Arduino API implementations | `src/core/arduino` | Preserve API names and packaged Core paths. |
| AZ3166 startup, pin/serial adapters, variants, linker scripts, boot support | `src/bsp/az3166` | Classify board dependencies per file; preserve addresses and ABI. |
| Core-hosted CLI, HTTP, NTP, telemetry, display services | `src/extensions/<service>` | Keep existing header exposure and compilation through staging. |
| Ten Arduino library packages | `libraries/<existing-name>` | Keep metadata, public includes, and library examples together. |
| Mbed/Azure/MXCHIP snapshots and vendor binaries | `vendor/<component>` and `vendor/prebuilt/az3166` | Preserve licenses and provenance; do not imply all binaries have source. |
| AzureIotHubExample and VoiceToTwitter example project | `examples/cloud` | Move complete sketch projects; preserve sketch/folder naming. |
| HttpTest manual stress diagnostic | `tests/hardware/manual/HttpTest` | Retain its compile-only coverage; device execution is manual. |
| BoardInit demonstration | `examples/board` | Label its manual/device-observation role. |
| SPI/Wire demonstration sketches | `examples/peripherals` | Preserve each complete Arduino sketch folder. |
| WiFiUdpTest, IotClientTest, SystemVersionTest | `tests/host/<area>` | Update implementation includes, commands, and both workflows together. |
| ArduinoUnit sketch and companion files | `tests/hardware/UnitTest` | Preserve the entire sketch and explicit hardware execution boundary. |
| Sketch build driver and maintained package scripts | `tools/test`, `tools/package` | Fix root/path assumptions before relocation. |
| DICE enrollment host tooling | `tools/provisioning` | Keep provisioning separate from firmware runtime and tests. |
| Historical CI/deployment configuration | `legacy/jenkins` | Preserve the original hierarchy and document unsupported external dependencies. |
| Original .NET device test tool | `legacy/jenkins/DevKitTestTool` | Preserve reusable logic; port supported portions into `tools/test` separately. |

Do not copy the same example or source file into multiple ownership directories.
If an old library-style sample bundle contains packaging metadata without a
runtime library, classify that metadata explicitly instead of promoting it into
the public library set.

## Path Dependencies To Update Together

- Package builder: the selected revision's manifest and mapped Git blobs, with
  historical layout fallback and an unchanged installed archive tree.
- Package verifier: source location of `SystemVersion.h` and the installed
  archive layout used to validate it.
- Sketch driver: shared mapped staging and discovery under `examples` and
  `tests/hardware`.
- PR and release workflows: source/include paths, file guards, and script paths.
- Host tests: staged include directories selected by the shared test runner.
- Arduino platform recipes: include and linker paths into Core and vendor trees.
- Legacy C# configuration/deployment wrappers remain historical and are not
  consumers of the new map or supported build entry points.
- README and contribution instructions: maintained branch, installation, and
  test paths, using the staging command rather than manual ownership-tree copies.

## Current Repository Layout

```text
devkit-sdk/
  src/
    core/arduino/
    bsp/az3166/
    extensions/
      configuration/
      diagnostics/
      display/
      http-client/
      http-server/
      network/
      ota/
      telemetry/
      time/
  libraries/
    Audio/ AudioV2/ AzureIoT/ FileSystem/ MQTT/
    Sensors/ SPI/ WebSocket/ WiFi/ Wire/
  vendor/
    mbed-os/
    azure-iot-sdk-c/
    mxchip/
    prebuilt/az3166/
    http-parser/
    mbed-memory-status/
  platform/az3166/
    boards.txt
    platform.txt
    programmers.txt
    README.md
    package-layout.json
  examples/
    board/
    cloud/
    peripherals/
  tests/
    host/
    hardware/
  tools/
    package/
    test/
    provisioning/
  docs/
  legacy/
    jenkins/
  .github/workflows/
  artifacts/                   (generated, ignored)
```

Do not create empty categories without content. Preserve existing Arduino library
identities; Audio/AudioV2 remain separate and public headers are not renamed.

## Keep Repository Layout Separate From Package Layout

The generated Board Manager payload must retain Arduino-compatible paths:

```text
AZ3166/
  boards.txt
  platform.txt
  programmers.txt
  cores/arduino/
  libraries/
  variants/MXChip_AZ3166/
  system/
  bootloader/
```

Use one explicit mapping between ownership directories and package destinations.
Initially, extensions can still be staged into their original Core locations.
Do not change header visibility, library discovery, include flags, or what gets
compiled at the same time as directory relocation.

The manifest accounts for all payload files under `src`, `libraries`, `vendor`,
and `platform/az3166`, excluding the map itself. Core, BSP, and extension files
still land under their original `cores/arduino` paths; dependencies return to
their original `system` paths. This keeps compile/include order and service
linkage separate from the ownership reorganization.

Packaging must continue to consume a committed revision, not line-ending-
translated worktree copies. Preserve deterministic ordering, timestamps, file
contents, and paths. Existing release tags using `AZ3166/src` must remain
packageable and the canonical 2.0.2 archive check must continue to pass.

## Stage 0: Reorganize With Compatibility Gates

Implemented through PRs #8, #9, and #10. The staged order and acceptance gates were:

1. Inventory ownership, public headers, includes, library metadata, CI path
   references, host tools, and example versus test entry points.
2. First separate unpackaged standalone examples, host tests, device tests, and
  maintained host tools in a focused PR. Update discovery, workflow paths, test
  includes, and documentation together. Leave `AZ3166/src` untouched in this PR
  so the package payload stays unchanged. Keep library examples with libraries.
3. Introduce a shared platform-staging boundary with an identity mapping for the
  existing tree. Have packaging and checkout sketch builds consume it before
  moving runtime source.
4. Move owned Core, BSP, and extension groups incrementally, updating the mapping
   while preserving the installed package layout and public interfaces.
5. Separate vendor snapshots and prebuilt artifacts with provenance records.
   Archive obsolete tooling only after checking references and support needs.
6. Update contribution/setup guidance to the maintained branch and new workflow.

Acceptance: no behavior or compiler changes; package payload paths and bytes
match the pre-move baseline; canonical historical packaging still passes;
Windows/Ubuntu packages remain deterministic; the 19 host cases, runtime-version
check, and all 13 sketch builds still run. Record the additional 15 library
examples as a separate coverage backlog; do not silently count them as already
tested or expand the baseline during a mechanical move.

## First Reorganization PR

Completed in PR #8 from the then-current `origin/maintenance`, with source and
compiler behavior frozen. Its scope was:

1. Move standalone sample projects to top-level `examples` by subject.
2. Move the three host test programs to `tests/host`, and the complete UnitTest
  sketch to `tests/hardware`.
3. Place the maintained sketch driver and package utilities in clearly named
  `tools/test` and `tools/package` locations, updating root discovery.
4. Update both workflows, implementation includes, expected sketch inventory,
  and local setup/test documentation in the same PR.
5. Preserve package contents exactly and rerun the existing native tests,
  runtime-version check, all 13 target builds, and package verification.

The first PR deliberately did not move Core/library/vendor payloads or change
tool versions, library generations, or optional-feature linkage. The remaining
payload moves followed only after package mapping was validated.

## Stage 1: Normalize Build Tools And Parameters

The concrete pull-request sequence, implementation boundaries, evidence, and
acceptance gates are defined in the
[Stage 1 build normalization plan](stage-1-build-normalization-plan.md).

- Centralize versions, checksums, immutable index pins, and host prerequisites.
- Share local/CI setup and build entry points; verify clean and idempotent setup.
- Preserve GCC 5.4.1 initially. Validate historical Windows path constraints
  before replacing the IDE bootstrap with a different installation method.
- Separate CPU/FPU/ABI, language, optimization/debug, includes, and warning policy.
  Keep effective default settings unchanged during normalization.
- Retain complete logs, tool identities, compiler commands, ELF/map/binary
  artifacts, and size reports; export a compilation database where supported.
- Stop hiding successful-build diagnostics. Use a first-party warning policy and
  explicit historical third-party allowances instead of blanket suppression.

Acceptance: clean supported hosts reproduce the documented setup/build;
diagnostics survive both successful and failed runs; baseline tests remain green.

## Stage 2: Grow The Test System

- Preserve the shared host-test entry point now used by PR CI and current
  release validation. Extend it rather than duplicating commands in workflows;
  CMake/CTest remains a possible future migration.
- Emit machine-readable results and targeted coverage reports.
- Recover pure character, formatting, string, Print/Stream, and IP-address tests.
- Add standalone-header and multi-translation-unit compile/link tests, including
  representative optimization levels to catch WCharacter-style linkage defects.
- Cover networking lifecycle, errors, partial writes, timeouts, DNS, recovery,
  and allocation failures with explicit fakes and controlled dependencies.
- Exercise real parser/dependency implementations when matching source becomes
  available; add malformed-input and boundary-value tests.
- Compile downstream HomeTemperature against the candidate Core.

Acceptance: no silent test omissions; clear execution versus compilation labels;
shared PR/release definitions; regression cases fail against the corresponding
broken behavior rather than merely compiling.

## Stage 3: Upgrade The Compiler Deliberately

- Inventory GCC/binutils/newlib/C++ runtime/OpenOCD and vendor-library provenance.
- Recover matching binary-library source/build recipes where possible.
- Select and pin a modern compiler candidate alongside the baseline.
- Validate ARM/FPU ABI, C++ runtime, allocator, exception, and linker assumptions.
- Compare warnings, flash/RAM/stack use, and behavior; preserve rollback.
- Require downstream compilation and physical-board acceptance before promotion.

Acceptance: compatibility is demonstrated, not inferred from a successful link.
Binary-only limitations have an explicit maintenance decision.

## Stage 4: Hardware, Security, And Release Gates

- Reuse suitable HomeTemperature board-test tooling on an isolated trusted runner.
- Automate GPIO, sensor, bus/loopback, WiFi reconnect, UDP, TLS/time failure,
  memory-pressure, and sustained-operation checks with retained serial logs.
- Define heap/stack watermarks, watchdog/reset diagnostics, and linker-aware
  budgets. Firmware has 976 KiB of flash and 261,692 bytes of RAM after reservations.
- Do not expose trusted hardware runners or private networks to arbitrary fork PRs.
- Obtain approval for required CI/review checks and protected branch/tag rules.
  No effective `maintenance` branch rules were present at audit time.
- Pin downloaded dependencies/actions, retain provenance/SBOM information, and
  validate the exact release tag with the same host and sketch gates.
- Audit shipped Mbed TLS/lwIP/RTOS/vendor code against actual binary provenance.
  Headers identify Mbed TLS 2.15.0 and lwIP 1.4.0; these are not a security audit.
- [Arm sunset Mbed OS in July 2026](https://github.com/ARMmbed). Decide ownership
  of backports or migration. Mbed TLS is a separately maintained project.
- Preserve immutable releases, version consistency, and a tested rollback path.

Acceptance: releases have traceable inputs and enforceable checks; hardware
results and support limits are explicit. Copilot recommendations supplement,
but do not replace, human ownership and hardware/security evidence.

## Open Decisions

1. Confirm the ownership categories and the meaning of extensions.
2. Confirm supported hosts and which historical examples/tools remain supported.
3. Determine which Core services are mandatory versus candidates for optional
   libraries; do not change that policy during the first structural move.
4. Select a modern compiler only after the baseline and binary ABI inventory.
5. Assign hardware-runner ownership, isolation, fixtures, and acceptance limits.
6. Define when unpatchable dependencies justify migration away from this SDK.