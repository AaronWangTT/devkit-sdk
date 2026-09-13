# AZ3166 Core Structure And Hardening Plan

Recorded: 2026-09-13.

Scope: the maintained devkit-sdk Core supporting HomeTemperature. This is a
repository planning document, moved from local notes into `docs` at the user's
request. [PR #8](https://github.com/AaronWangTT/devkit-sdk/pull/8) completed the
first-pass reorganization and was squash-merged as
`743ee0f708f8597c9185e3573eda8c1749f9f06b`. The next checkpoint is implemented on
`refactor/legacy-tooling-reorg`: root `src` and `libraries`, relocated host and
legacy tools, and removal of the empty `AZ3166` wrapper. Internal Core, BSP,
extension, and vendor separation, toolchain upgrades, and repository policy
changes remain future work.
Repository reorganization is the first stage, followed by build normalization.

## Current Checkpoint

- The 938-file platform subtree was moved without content changes, then its
  210 library files were separated into root `libraries`. All ten packages and
  their 15 co-located examples remain intact.
- Packaging reconstructs the original platform tree from the selected revision
  using an isolated temporary Git index. Checkout builds copy `src` and
  `libraries` into the corresponding platform locations. The installed archive
  prefix remains `AZ3166/`; public headers and library-discovery paths do not
  change.
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

## First-Pass Status

- Moved 11 standalone examples, 3 host-test programs, 2 device-test projects,
  and 3 maintained host tools into the approved top-level directories.
- `HttpTest` is a manual hardware stress diagnostic under
  `tests/hardware/manual/HttpTest`, not a standalone networking example.
- Updated CI/release paths, relative test includes, docs, and two legacy
  UnitTest configuration references. Historical release layouts have fallbacks.
- Preserved all shipped library examples, legacy tool locations, sketch filenames/extensions, and the complete `AZ3166/src` payload. Removed the two orphaned VoiceToTwitter metadata files.
- Removed the two root Azure Pipeline templates and the stale root Board Manager index. The maintained catalog in `azureiotdevkit_tools` is unchanged.
  index. The maintained catalog in `azureiotdevkit_tools` is unchanged.
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

## Long-Term Ownership Map

Examples, tests, and host tools have already moved. Root `src` and `libraries`
form the current package source; finer-grained runtime/vendor separation below
is a proposal, not part of this checkpoint.

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

- Package builder: committed `src` and `libraries` composition, with historical
  `AZ3166/src` fallback and an unchanged installed archive layout.
- Package verifier: source location of `SystemVersion.h` and the installed
  archive layout used to validate it.
- Sketch driver: repository-root source/library staging and discovery under
  `examples` and `tests/hardware`.
- PR and release workflows: source/include paths, file guards, and script paths.
- Host tests: relative includes of the implementation and Core headers.
- Arduino platform recipes: include and linker paths into Core and vendor trees.
- Legacy C# configuration/deployment wrappers: hard-coded source, example,
  UnitTest, version, and platform locations if those tools remain supported.
- README and contribution instructions: maintained branch, installation, and
  test paths, including both source trees for manual installation.

## Proposed Repository Layout

```text
devkit-sdk/
  src/
    core/arduino/
    bsp/az3166/
    extensions/
      cli/
      display/
      httpclient/
      httpserver/
      ntp/
      telemetry/
  libraries/
    Audio/ AudioV2/ AzureIoT/ FileSystem/ MQTT/
    Sensors/ SPI/ WebSocket/ WiFi/ Wire/
  vendor/
    mbed-os/
    azure-iot-sdk-c/
    mxchip/
    prebuilt/az3166/
  platform/az3166/
    boards.txt
    platform.txt
    programmers.txt
    package-layout.json
  examples/
    board/
    cloud/
    networking/
    peripherals/
  tests/
    host/
    compile/
    hardware/
    support/
  tools/
    build/
    package/
    test/
    provisioning/
  docs/
  legacy/
    jenkins/
  .github/workflows/
  build/                       (generated, ignored)
```

Names are proposed, not final API names. Do not create empty categories without
content. Preserve existing Arduino library identities; do not collapse
Audio/AudioV2 or rename public headers during this work.

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

The current mapping stages root `src` at the platform root and root `libraries`
at its `libraries/` child. It does not yet separate the Core, BSP, extensions,
and vendor directories within `src`.

Packaging must continue to consume a committed revision, not line-ending-
translated worktree copies. Preserve deterministic ordering, timestamps, file
contents, and paths. Existing release tags using `AZ3166/src` must remain
packageable and the canonical 2.0.2 archive check must continue to pass.

## Stage 0: Reorganize With Compatibility Gates

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

Do not move Core/library/vendor payloads, change tool versions, merge library
generations, or decide optional-feature linkage in this first PR. Those changes
follow once the package-staging boundary is tested.

## Stage 1: Normalize Build Tools And Parameters

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

- Use one host-test entry point shared by PR CI and release validation.
  CMake/CTest is a candidate; reuse the existing regression cases.
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