# First-Party Warning Policy

PR 5 of the [Stage 1 plan](stage-1-build-normalization-plan.md) makes warnings
visible without changing the pinned compiler, ABI, linked firmware, or package
layout. The reviewed PR 4 checkpoint is
`53524f91e9325534a5c8fb27eafc7622a43f5276`. The implementation starts from
maintenance `1c5daa0a75e26998d23378761b818b0e87df04b9`, whose platform, source,
vendor, library, and sketch payloads are identical to that checkpoint.

## Policy And Ownership

[The warning policy](../tools/build/az3166-warning-policy.json) records the
existing 13-sketch inventory and each allowance's ownership, source glob,
diagnostic option or anchored message, component, immutable version, rationale,
and removal condition. No first-party allowance is permitted.

[The parser and evaluator](../tools/test/Az3166Warnings.ps1) retain the original
source path, normalized repository source, line, column where available,
severity, GCC option where emitted, message, original diagnostic, sketch, and
raw-log location. Paths are normalized before classification. Windows drive
paths and UNC roots are case-insensitive; Linux roots are case-sensitive.

Staged paths are mapped through
[the package manifest](../platform/az3166/package-layout.json), choosing the
longest matching destination. Exact content-pinned snapshots also retain vendor
ownership when stored inside a maintained component. In particular, the parser
under the Core HTTP-client directory remains vendor-owned. Classification is:

- maintained Core, BSP, extensions, libraries, sketches, and tests: first-party;
- repository vendor snapshots and prebuilt interfaces: vendor;
- installed or staged ArduinoUnit sources: downloaded test dependency;
- the locked compiler/runtime installation and its linker: toolchain;
- other locations or location-free warnings: unclassified and rejected.

Three ST/MXCHIP-derived C snapshots still live inside the historical Audio
library: `nau88c10.c`, `stm32412g_discovery_audio.c`, and
`stm32412g_discovery.c`. The unchanged
[http-parser 2.7.1 source and header](../src/extensions/http-client/http_parser)
are also stored with their consuming component, alongside the original license.
The policy names each exact repository file and pins its SHA-256 over decoded
text re-encoded as UTF-8 without a BOM, with CRLF normalized to LF. Builds reject
changed snapshot contents before staging. Allowance component/version values
must match the corresponding snapshot pin. Snapshot classification alone grants
no warning allowance. The maintained Audio and HTTP wrappers, other library
files, and other Core/BSP/extension files remain first-party. Moving the parser
does not change its packaged paths or add any warning allowances.

Every first-party warning, unknown warning, ambiguous allowance match, or stale
allowance fails the complete inventory. An option-based rule cannot match a
different GCC option. An anchored message rule is used only when no option was
emitted. Warnings are not filtered from the console or raw logs, and repeated
diagnostics are counted rather than deduplicated.

The sketch driver always selects `all` (`-Wall -Wextra`, plus the existing C++
`-Wvla`). The broad C++ `-Wno-unused-parameter` and
`-Wno-missing-field-initializers` flags are removed. Default platform warnings
are now visible as well. The explicit Arduino `none` profile remains available
for IDE compatibility but is never selected by CI or the shared driver, and
retained builds using it are rejected. The compiler contract compares against
PR 4 and permits only these explicit warning changes; other effective compiler,
assembler, archive, linker, objcopy, and size parameters remain unchanged.

## Running The Gate

Run the network-free contracts with PowerShell 7:

```powershell
./tests/host/build/WarningPolicyTest.ps1
./tests/host/build/CompilerParametersTest.ps1
```

Use the existing locked installer and sketch driver for the full inventory:

```powershell
$tools = ./tools/build/Install-Az3166BuildTools.ps1 `
    -Root C:/a -DownloadCache C:/az3166-downloads
./tools/test/Test-Az3166Sketches.ps1 `
    -ArduinoCli $tools.ArduinoCliPath `
    -ArduinoDataDirectory $tools.ArduinoDataDirectory `
    -ArduinoUnitDirectory $tools.ArduinoUnitDirectory `
    -OutputDirectory C:/az3166-warning-evidence
```

Use a fresh, short output directory and a Windows-local checkout, as required by
the existing target toolchain. All requested sketches are attempted before
aggregate failure is reported. Each sketch gains `warnings.json` and a
`warningPolicy` result in its build context. The output root also retains:

- `az3166-warning-policy.json` and `package-layout.json`, alongside the build lock;
- `warning-summary.json`, including all diagnostics, violations, counts by rule,
  stale-rule IDs, completeness, and evidence errors;
- `warning-summary.md`, the visible count-by-rule and failure summary.

Build contexts record the policy and manifest hashes and the dependency/compiler
roots used for ownership. Parsing uses the unmodified `build.stdout.log` and
`build.stderr.log` sidecars because the combined log can interleave channels.
The original combined `build.log` is still retained. Missing diagnostic streams
fail both the per-sketch and aggregate warning reports.

Re-evaluate retained evidence without a compiler or network connection:

```powershell
./tools/test/Test-Az3166Warnings.ps1 `
    -OutputDirectory C:/az3166-warning-evidence -RequireCompleteInventory
```

This uses the retained lock, policy, and package manifest.
Each retained input's SHA-256 must match every sketch's recorded context;
modified inputs or missing provenance fail both per-sketch and aggregate reports.
A deliberately selected
single sketch still rejects all first-party/unknown/ambiguous warnings, but
cannot establish that rules for absent components are stale. Stale checks run
only for the exact complete inventory, and the default driver/CI run requires
that inventory. Reports explicitly record whether stale checks ran.

CI runs the contracts on Windows and Ubuntu, enforces the policy during its
existing single 13-sketch compilation, publishes the rule summary, and uploads
the complete evidence on success or failure for 30 days. No extra full-build CI
pass or library-example expansion is introduced.

## Validation Record

Recorded 2026-09-15 with the locked CLI 1.5.1, GCC 5.4.1, and historical Windows
toolchain. Local evidence is retained under the Windows `az3166-pr5` validation
directory in `baseline`, `inventory`, `candidate`, and `failure-fixtures`.

1. Captured all 13 baseline sketches before changing repository warning flags.
2. Removed only the two suppressions in a disposable inventory checkout and
   captured all 13 sketches at the same checkout, staging, and build roots.
   All binaries and structured sizes matched before source fixes.
3. Classified 425 warning occurrences: 371 maintained first-party diagnostics,
   46 historical diagnostics, and eight CLI architecture notices. The 26 Audio
   snapshot diagnostics are included in the historical count, not first-party.
4. Fixed only inventory-confirmed first-party sites. Narrow GNU unused
   annotations preserve existing names and source line counts; C++ aggregates
   use complete value initialization; the positive-position comparison makes its
   existing unsigned conversion explicit; the omitted MQTT enum case explicitly
   retains its previous no-op behavior. SPI/Wire metadata now advertises the
   board's actual `stm32f4` architecture.
5. Recompiled all 13 touched non-sketch translation units using captured GCC
   commands. Machine code and relocations matched the original objects.
6. Built all 13 policy-enabled sketches: zero first-party warnings, 46 allowed
   diagnostics, 14 used rules, zero unknown/ambiguous warnings, zero stale rules.
   Count totals are 34 vendor, six ArduinoUnit, and six pinned-linker diagnostics.
7. Compared all 13 binary SHA-256 values and byte equality of every complete
   `size.txt` and `size.json`, including debug sections and addresses. All 39
   comparisons passed; `firmware-comparison.json` retains the hashes. No firmware
   contents or size sections were normalized. Fixed-root routing uses the
   existing PR 4 harness's `Invoke-Az3166FixedRootBuild` function.
8. Passed policy contracts on Windows and Linux, including injected first-party,
   unknown vendor, ambiguous, stale, suppressed-profile, incomplete-inventory,
   missing-stream, and modified-snapshot failures. Raw-log preservation and
   Windows/UNC/Linux ownership behavior are checked without target downloads.
9. Passed build-configuration, package-layout, and compiler-parameter contracts,
   plus the real compile/link/preparation-failure evidence fixtures. The valid
   sketch after those failures still compiles successfully.
10. Executed all 19 native regression cases and the runtime-version test on Linux
    with the existing sanitizer-enabled host runner. No failures occurred.

Review regressions additionally reject present-but-empty/non-string diagnostic
matchers and verify the retained lock/policy/manifest hashes against every build
context. Tests reproduce a null-option message-rule bypass, each independently
modified retained input, and missing provenance; none can produce a passing report.

These are compile and host-test results, not physical-board acceptance. PR 5
requires firmware and full size-report equality; it does not claim complete
ELF/map byte equality after source annotations.

Hosted validation of implementation commit `f9ad477` passed in
[Core package CI run 34982191804](https://github.com/AaronWangTT/devkit-sdk/actions/runs/34982191804).
Both host jobs and cross-host package comparison passed. The fresh Windows
inventory again reported zero first-party and 46 allowed warnings; the canonical
package remained 5,497,641 bytes with its locked SHA-256. Both current packages
were 5,498,366 bytes with SHA-256
`07bce10485ed83c5da9c4c032b3ce6d15b6d74fd81ebb88679acca117a68b22d`.

## Findings For Later Review

1. Directory location alone is not sufficient ownership evidence for the three
   library-local ST/MXCHIP C snapshots. Their existing placement is preserved;
   exact content pins prevent their allowances from silently covering modified
   code. Any future ownership transfer must remove or review those pins/rules.
2. The frozen codec initializer omits a return value. A focused attempt to return
   its final helper status added a `movs r0, #0` instruction to a linked function
   and changed its size. That exploratory edit was reverted. Audio return/status
   propagation, including the stop wrapper and ignored transfer status, requires
   separate behavior review and a deliberately accepted firmware baseline.
3. Pinned binutils emits the exact message `changing start of section .data by 4
   bytes` for six sketches. Its existing linker flag, script, addresses, and
   binary outputs are unchanged. Only that exact option-less message from the
   pinned linker is allowed; other alignments or messages fail.
4. The CLI's SPI/Wire architecture notices were metadata defects, not GCC
   diagnostics. They were corrected within this warning inventory without
   changing code or adding new board architectures.
5. Removing unused names or moving source lines can change debug sizes or
   embedded diagnostic strings. The targeted annotations deliberately preserve
   them for Stage 1; broader dead-code/interface cleanup is deferred.
6. Hosted CI reports Node.js 20 deprecation notices for the existing v4 Actions
   and runs them on Node.js 24. All jobs pass. Reviewing/updating Action versions
   is separate workflow maintenance, not part of this compiler-warning policy.