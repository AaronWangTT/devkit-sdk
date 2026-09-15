# Compiler Parameter Normalization

PR 4 of the [Stage 1 plan](stage-1-build-normalization-plan.md) separates named
parameter groups without changing effective commands or firmware. The comparison
baseline is reviewed PR 3 maintenance commit
`6d145395ae3aaeb14cec2a3f739e33d34ec628ac`.

## Parameter Ownership

[platform.txt](../platform/az3166/platform.txt) groups CPU flags, language modes,
optimization/debugging, section and runtime code generation, dependencies,
target/assembly/Arduino definitions, and contiguous include-path categories.
Warning selection and the historical C++ allowances are named separately but
remain active in precisely their original positions. The linker has separate
diagnostic, script, map, section, search-path, wrapping, library, specs, and
forced-symbol properties.

[boards.txt](../platform/az3166/boards.txt) owns Cortex-M4, Thumb, `softfp`, and
`fpv4-sp-d16`. C/C++ and assembly keep the original Thumb/float/FPU order in
`build.extra_flags`. The linker still uses only the original CPU and Thumb
switches: this PR does not add FPU or float-ABI switches to linking. Existing
extension properties, recipe names, include/define order, archive/object order,
library order, warning profiles, duplicate switches, and tool versions remain
unchanged. Property values are not wrapped across lines because Arduino's
property format does not support that as a token-preserving continuation.

## Local Validation

Run the network-free contract test with PowerShell 7 and full repository history:

```powershell
pwsh -File ./tests/host/build/CompilerParametersTest.ps1
```

The test recursively expands every original compile, assembly, archive, link,
objcopy, and size recipe under all four warning profiles and requires exact
string equality with the baseline. Runtime placeholders remain literal, so
their placement is also checked. Tests reject property cycles, missing command
coverage, changed argument order, and injected command/artifact/input changes.

Install or verify the locked Windows toolchain using the shared installer, then
run the same target harness as CI:

```powershell
$tools = ./tools/build/Install-Az3166BuildTools.ps1 `
    -Root C:/a -DownloadCache C:/az3166-downloads
./tools/test/Test-Az3166CompilerParameters.ps1 `
    -ArduinoCli $tools.ArduinoCliPath `
    -ArduinoDataDirectory $tools.ArduinoDataDirectory `
    -ArduinoUnitDirectory $tools.ArduinoUnitDirectory `
    -OutputDirectory C:/az3166-equivalence
```

The output root must not exist and must be short enough for the sketch driver's
140-character absolute build-path bound. Use a Windows-local checkout. The
harness rejects uncommitted payload/toolchain changes outside the two parameter
files. It creates an isolated checkout at the current source revision and
performs two passes with exactly the same source, toolchain, checkout path,
private staging path, and build path. Only the two parameter files differ: the
first pass uses the pinned baseline versions, the second uses the working-tree
versions. The same evidence driver is used in both passes. No working-checkout
files are overwritten.

Each build pass moves its complete evidence tree to `before` or `after` before
the next pass starts. The fixed `build` path is therefore empty for the second
pass, and normal driver cleanup removes private staging between passes. The
isolated `source` checkout is left for inspection. Do not run two comparisons
against the same output root. The harness does not use shared compiler output
caches or normalize firmware contents.

Each sketch retains the PR 3 evidence plus:

- `build.stdout.log` and `build.stderr.log`: original compile output channels;
- `commands.json`: actual verbose tool argument arrays;
- `database-commands.json`: the original compilation database in source order;
- `elf-sections-program-headers.txt`: locked `readelf -W -S -l` output;
- `inspection.log`: the exact ELF-inspection invocation and output.

`comparison.json` records the baseline/source revision, fixed paths,
canonicalization rules, command coverage, and per-artifact equality and hashes.
It checks commands, database arguments, structured sizes, ELF section/program
headers, binary SHA-256, and byte equality of the entire ELF and map. Complete
map equality also covers symbols, memory regions, and linked libraries; complete
ELF equality is stronger than section-size/program-header equality alone.
Raw size reports also match, and each pass independently requires its verbose
compiler/assembler arguments to match the original compilation database before
the two passes are compared. Failed builds and differing firmware artifact sets
are rejected.

## Canonicalization

Argument order inside every invocation is immutable. Whole command records are
sorted only because Arduino compiles independent sources in parallel; duplicate
records are retained. CLI-rendered quoted strings are decoded using a structured
JSON string parser. The only rewritten argument value is a preprocessing `-o`
path matching the observed CLI-only `<OS temp>/<digits>/sketch_merged.cpp` form.
It becomes `<arduino-preprocess>/sketch_merged.cpp`. No source/include/object,
library, compiler option, binary, ELF, or map content is canonicalized.

## Validation Record

Recorded 2026-09-15 on Windows 11 / PowerShell 7.6.6 with the pinned CLI 1.5.1,
GNU Arm GCC 5.4.1 and binutils 2.26.2.20160923. The outer repository path contained
spaces. Before either parameter file was edited, all 13 sketches were captured
and a zero-change two-pass comparison was verified. After normalization, both
passes again compiled all 13 sketches and passed every comparison:

- all expanded recipes match for `none`, `default`, `more`, and `all`;
- actual preprocessor/compiler/archiver/linker/objcopy/size argument arrays match;
- original compilation databases match;
- all 13 binary SHA-256 values match;
- complete ELF bytes and section/program-header reports match;
- complete maps and every structured section size/address match.

The 13 projects remain the existing standalone examples and hardware-test
projects. No library examples, warning fixes, hardware execution, or compiler
upgrades are added. The baseline emits no standalone assembler commands because
it has no selected assembly translation units. Assembly recipe equivalence is
checked statically under all warning profiles; the capture/comparison supports
assembler commands if any appear, but this PR does not claim they were executed.

CI runs the contract test on Windows and Ubuntu and the two-pass target harness
on Windows, in addition to the existing gates. The `compiler-equivalence-windows`
artifact uploads both complete evidence trees, the harness log, and comparison
report with `if: always()` and 30-day retention. The job summary links that
archive and reports each sketch's result. The isolated clone is not uploaded.

## Findings For Later Review

1. The combined PR 3 log can interleave stdout and stderr in the middle of a
   verbose command. The equivalence harness therefore needs unmixed channel
   evidence. The shared runner now optionally tees both raw streams, and the
   sketch driver retains them for the normal compile invocation. Combined logs
   and console streaming are unchanged; the sidecars do not change commands.
2. CLI 1.5.1 escapes quoted Windows paths and creates a random preprocessing
   output directory even with a fixed build root. Only that observed CLI path
   and its display escaping are canonicalized, as allowed by the PR 4 plan.
3. The PR 3 `__FILE__` staging-path finding still applies. Fixed roots restore
   exact binary/ELF/map equality; removing path-sensitive diagnostic strings or
   changing staging policy is not part of normalization.
4. Historical linker details, including `-gcc`, repeated section-GC flags, and
   omitted float-ABI/FPU flags, remain as-is. Any correction requires separate
   vendor ABI and firmware evaluation in the later stages.
5. This is a pinned mechanical-normalization checkpoint, not a permanent claim
   that future compiler or warning changes are forbidden. PR 5 must deliberately
   advance the expected warning-command baseline while retaining PR 4 evidence;
   unexplained differences must not be hidden by broadening canonicalization.