# Stage 1 Build Normalization Plan

Recorded: 2026-09-14.

This document expands Stage 1 of the
[Core hardening plan](devkit-sdk-hardening-plan.md). It starts after the source
reorganization merged in PR #10 as `d55d916` and deliberately preserves the
existing compiler, ABI, package layout, and firmware behavior.

## Goals And Boundaries

Stage 1 makes the existing build observable and reproducible before attempting
to modernize it. It must:

- give local and CI builds one reviewed source for versions, checksums, index
  revisions, board identity, and host prerequisites;
- give developers and CI the same setup and build entry points;
- preserve GNU Arm GCC 5.4.1 (`5_4-2016q3`) and the historical short Windows
  tool path until path behavior is measured;
- make compiler parameter ownership clear without changing effective flags;
- retain complete diagnostics and target-build evidence on success and failure;
- expose first-party warnings and narrowly classify unavoidable historical
  third-party warnings.

The following remain outside Stage 1:

- upgrading GCC, binutils, newlib, the C++ runtime, or OpenOCD;
- changing CPU, FPU, float ABI, language standard, optimization, or linkage;
- rebuilding or replacing binary-only vendor libraries;
- expanding the 13-sketch baseline to library examples;
- downstream HomeTemperature or physical-board acceptance;
- replacing the Arduino IDE bootstrap before the Windows path experiment.

Each pull request below starts from the latest reviewed `maintenance` commit.
Do not combine later warning fixes or compiler changes with mechanical flag
normalization. Every PR retains enough evidence to compare its result with the
previous checkpoint and can be reverted independently.

## PR 1: Central Build Lock

### Purpose

Replace duplicated setup constants with one validated, machine-readable build
contract. This changes where values are read, not the values or build process.

### Deliverables

- `tools/build/az3166-build-lock.json` records:
  - Arduino CLI and IDE versions, download URLs, archive sizes, and SHA-256;
  - immutable Board Manager repository, full commit ID, index path, URL, and
    raw index SHA-256;
  - Core version and canonical package metadata;
  - GCC package version, reported compiler version, OpenOCD version, and the
    Windows archive metadata published by the pinned index;
  - ArduinoUnit version and archive metadata;
  - FQBN, supported CI hosts, PowerShell minimum, required Git capability, and
    the unresolved short-path constraint.
- `tools/build/Az3166Build.Common.ps1` loads and validates the schema and exports
  selected values to GitHub Actions without duplicating them in YAML.
- `tests/host/build/BuildConfigurationTest.ps1` rejects malformed hashes,
  mutable index references, mismatched tool dependencies, and duplicated
  consumer literals.
- The sketch driver reads its FQBN and ArduinoUnit values from the lock.
- Core package CI reads canonical-package and Windows-bootstrap values from the
  lock, and keys the toolchain cache with GitHub Actions `hashFiles()` over the
  complete lock file. It verifies the IDE archive size and hash, preflights the
  immutable Board Manager index hash, and verifies the exact index cached by
  Arduino IDE before compilation proceeds.

### Validation

1. Run the build-configuration contract test on Windows and Ubuntu.
2. Run package-layout tests to ensure the new tooling directory is not treated
   as platform payload.
3. Verify the canonical `2.0.2` package remains 5,497,641 bytes with SHA-256
   `5914d3e7b988fdc50b00ff241b7ac191fd6fb9bdc234b4a3f86c51ed0d5e9677`.
4. Compile the existing 13 sketches with the same Arduino IDE bootstrap, GCC,
   FQBN, and flags.
5. Confirm Windows and Ubuntu still produce byte-identical current packages.

Network availability is not required for the contract test. Downloaded content
continues to be verified at the point where it is consumed. The existing Arduino
CLI action still consumes only the locked CLI version, while Board Manager uses
the verified immutable index and its package checksums for Core, GCC, and
OpenOCD. PR 2 will move every download behind the shared installer and verify
the installed tool identities directly.

## PR 2: Shared And Idempotent Toolchain Setup

### Purpose

Replace the workflow-only Windows bootstrap with a supported local/CI entry
point while retaining the known working installation mechanism and short path.

### Deliverables

Add `tools/build/Install-Az3166BuildTools.ps1` with these parameters:

- `-Root` selects the installation root;
- `-DownloadCache` permits verified archive reuse;
- `-Clean` removes only directories owned by this installer;
- `-Offline` forbids network access and reports every missing cached archive;
- `-VerifyOnly` validates an existing installation without mutation.

The installer must:

1. Load all versions, URLs, sizes, and hashes from the build lock.
2. Download to temporary files, check size and SHA-256, then extract or move
   atomically into the owned root.
3. Retain Arduino IDE 1.8.19 as the Board Manager bootstrap.
4. Install the Core from the immutable index URL into the IDE portable data
   directory.
5. Verify the installed Core metadata, GCC and OpenOCD executables, reported GCC
   5.4.1 identity, and the historical target `c++config.h` path;
6. return a structured object containing Arduino CLI, IDE, data-directory,
   compiler, and OpenOCD paths;
7. make a second valid invocation perform no downloads or installation writes;
8. clearly reject partial or foreign installations instead of silently merging
   them with managed state.

CI calls this script directly. Documentation uses the same command and consumes
the returned paths when invoking `Test-Az3166Sketches.ps1`.

### Windows Path Experiment

Before changing the IDE bootstrap, run one representative sketch in fresh roots
whose absolute lengths increase in controlled increments. Keep the sketch,
tool versions, data layout, and command identical. For each root, retain:

- absolute root, compiler, include, object, and response-file path lengths;
- setup log and verbose compiler log;
- pass/fail status and the first failing diagnostic;
- whether shortening only the root restores the build.

Record the longest passing and shortest failing roots when repeating this
experiment. Keep the current conservative preflight limit and short root named
`a` under a drive or runner temporary directory unless new measurements justify
a change.

The experiment is recorded in
[`windows-toolchain-path-limit.md`](windows-toolchain-path-limit.md). Root length
71 passed and 72 failed, so the lock and installer enforce a conservative
70-character maximum while CI retains the short root named `a`.

### Validation

- fresh setup succeeds on `windows-2022`;
- an immediate second setup is unchanged and succeeds;
- `-VerifyOnly` succeeds without network access;
- deletion of one managed component is detected and repaired or rejected as
  specified;
- a checksum mismatch fails before extraction;
- all 13 sketches compile using only paths returned by the installer.

## PR 3: Persistent Build Evidence

### Purpose

Make successful and failed target builds equally diagnosable. Build products
must outlive temporary staging without changing what is compiled.

### Sketch Driver Contract

Extend `tools/test/Test-Az3166Sketches.ps1` with an explicit `-OutputDirectory`.
Use temporary space only for private staging and downloads. Place retained
evidence under a stable directory per sketch:

```text
<output>/<sketch>/
  build.log
  build-context.json
  compiler-versions.txt
  compile_commands.json
  firmware.elf
  firmware.map
  firmware.bin
  size.txt
  size.json
```

The driver must:

- stream complete Arduino CLI output to the console and `build.log` rather than
  printing only size lines on success;
- enable verbose compilation so compiler, archiver, linker, objcopy, and size
  commands are retained;
- record OS, PowerShell, Git, Arduino CLI, GCC/binutils, Core, FQBN, lock hash,
  repository revision, and dirty-worktree status in `build-context.json`;
- copy ELF, map, and binary outputs without renaming away their sketch identity;
- retain raw and structured size reports;
- request a compilation database through the pinned Arduino CLI capability and
  validate that it contains entries for the built sketch;
- retain partial logs and any produced artifacts when compilation fails;
- continue attempting all requested sketches and report aggregate failure.

Use structured process invocation and preserve the real exit code while teeing
output. CI uploads the complete output directory with `if: always()` and a
retention period suitable for review. The concise job summary links each sketch
to its log, sizes, and artifact names but does not replace the raw evidence.

### Validation

- a successful representative build contains every required nonempty artifact;
- an intentionally invalid fixture fails and retains its complete diagnostic;
- spaces in repository and output paths do not corrupt command capture;
- the existing 13 sketches still compile;
- retained binaries and size results match the pre-PR baseline.

## PR 4: Compiler Parameter Normalization

### Purpose

Separate parameter categories in `platform/az3166/platform.txt` and
`platform/az3166/boards.txt` while preserving the exact effective command line.

### Parameter Groups

Introduce named properties for:

- CPU and instruction set: Cortex-M4 and Thumb;
- FPU and ABI: `fpv4-sp-d16` and `softfp`;
- C and C++ language modes: GNU99 and GNU++11;
- optimization and debug information: `-O2` and `-g`;
- code generation and section behavior;
- target and feature definitions;
- platform/system include paths;
- first-party warning selection and temporary historical allowances;
- linker diagnostics, script, search paths, wrapping, libraries, and specs.

Keep include order, define order where meaningful, object/archive order, linker
library order, and all effective values unchanged. Do not add apparently missing
linker ABI flags in this PR; Stage 3 must evaluate that against vendor archives.

### Equivalence Harness

Capture verbose commands and outputs for all 13 sketches before editing. Build
the same revision, sketches, toolchain, and fixed root after normalization.
Canonicalize only paths and formatting introduced by Arduino CLI, then compare:

- compiler, assembler, archiver, linker, objcopy, and size token sequences;
- binary SHA-256 values;
- ELF section sizes and program headers;
- map-file symbols, memory regions, and linked libraries.

Any unexplained token or binary difference blocks this PR. Expected warning-text
differences belong in PR 5, not this mechanical normalization.

## PR 5: First-Party Warning Policy

### Purpose

Replace blanket suppression with visible first-party diagnostics and explicit,
reviewable historical third-party allowances.

### Warning Inventory

Build all 13 sketches with retained verbose logs. Parse each GCC diagnostic into
source path, line, severity, diagnostic option where emitted, and message. Map
staged paths back to repository ownership through
`platform/az3166/package-layout.json` before classifying them.

Ownership classes are:

- first-party maintained Core, BSP, extensions, sketches, and tests;
- repository-held vendor snapshots and prebuilt interfaces;
- downloaded test dependency sources such as ArduinoUnit;
- compiler and C/C++ runtime headers.

### Policy File And Enforcement

Add `tools/build/az3166-warning-policy.json`. Each allowance must identify:

- an ownership-scoped source glob;
- the GCC diagnostic option, or a narrowly matched message when GCC 5.4.1 does
  not emit an option;
- component and pinned version;
- rationale and intended removal condition.

CI fails on every first-party warning, every unclassified third-party warning,
and every stale allowance that no longer matches. Allowed diagnostics remain in
the raw log and appear in a count-by-rule summary.

Remove broad `-Wno-unused-parameter` and `-Wno-missing-field-initializers` only
after the inventory has assigned or fixed every resulting diagnostic. CI must
never select the `none` warning profile. Changing warning visibility is isolated
in this PR so PR 4 can demonstrate command equivalence first.

### Validation

- all first-party sources compile with zero warnings under the selected policy;
- known third-party diagnostics match only their explicit rules;
- an injected first-party warning, unknown vendor warning, and stale allowance
  each fail the policy test;
- all diagnostics remain visible in retained logs;
- firmware binaries and size reports remain equal to the PR 4 baseline.

## Stage 1 Exit Gate

Stage 1 is complete only when all of the following are true:

- clean setup and `-VerifyOnly` work on every documented host;
- a second setup is demonstrably idempotent;
- GCC remains 5.4.1 and the Windows path constraint is measured, documented,
  and enforced without changing the bootstrap prematurely;
- local documentation and CI invoke the same setup and build scripts;
- all 13 target sketches compile;
- all 19 native regression cases and the runtime-version test execute on the
  supported native host;
- package-layout contracts and repeated package builds pass;
- canonical `2.0.2` package verification and cross-host current-package equality
  pass;
- successful and failed target builds retain logs, identities, commands, ELF,
  map, binary, size reports, and compilation databases;
- parameter normalization is backed by command, binary, ELF, map, and size
  equivalence evidence;
- first-party warning count is zero and every accepted third-party warning is
  explicit, visible, narrow, and tested;
- physical-device execution and compile-only evidence remain clearly labeled.

The final Stage 1 CI run is the baseline for compiler modernization in Stage 3.
Retain its lock file, complete build artifacts, warning summary, package hashes,
and exact commit ID with the project records.