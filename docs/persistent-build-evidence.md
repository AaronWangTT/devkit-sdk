# Persistent Build Evidence

PR 3 of the [Stage 1 plan](stage-1-build-normalization-plan.md) adds evidence
retention without changing platform recipes, compiler flags, tool versions,
source selection, or the 13-sketch baseline. All target checks are compile-only;
they do not establish physical-board or cloud-service acceptance.

## Driver Contract

Use the shared installer and sketch-driver command in the
[README](../README.md#tests). `-OutputDirectory` is required. Each selected sketch
has a stable directory named after its sketch folder:

```text
<output>/
  az3166-build-lock.json
  compiler-versions.txt
  summary.md
  <sketch>/
    build.log
    build-context.json
    compiler-versions.txt
    compile_commands.json
    compile_commands.build.json
    <sketch>.ino.elf
    <sketch>.ino.map
    <sketch>.ino.bin
    size.txt
    size.json
    build/
```

Names emitted by Arduino CLI are preserved, including `.pde` for legacy
sketches. The extra `build` directory retains generated source, objects, archives,
and other intermediate output. Private platform/library staging and downloads
are temporary; the retained build tree is not.

The output root must be nonexistent or empty; nonempty roots are rejected before
any writes, so root metadata and unrelated sketch results cannot mix between runs.
Duplicate sketch-folder names are also rejected. Use a fresh output directory for another run.
Root evidence names (`compiler-versions.txt`, `az3166-build-lock.json`, and
`summary.md`) are reserved and cannot be used as sketch-directory names.
On Windows, the absolute `<output>/<sketch>/build` path must not exceed 140
characters. Preflight rejects longer paths without writes; use a shorter output
root. This is a conservative tested build-path bound, separate from the
installer's 70-character toolchain-root limit, and is not a claimed failure
boundary for GCC or every possible user-supplied source layout.
The driver never deletes prior evidence. `-VerboseBuild` is retained for caller
compatibility, but every build now uses `--verbose --warnings all` and streams
both CLI output channels to the console and `build.log` as they arrive.
Commands are recorded as executable/argument JSON, not shell command strings.

The context records OS and architecture, PowerShell, Git, Arduino CLI, GCC,
assembler, archiver, linker, objcopy and size identities, checkout and locked
Core versions, FQBN, lock SHA-256, repository revision and dirty status, input
paths, timestamps, commands, native compile/database/size exit codes, errors,
and firmware names, lengths, and hashes. Git status is sampled before creating
output so this invocation's own evidence cannot make a clean checkout dirty.

Firmware and the ordinary build's compilation database are copied before the
separate `--only-compilation-database` pass. The latter's database is parsed and
must contain the generated source of the built sketch; a successful CLI exit
alone is insufficient. `compile_commands.build.json`, when produced, preserves
the original database even if the subsequent database-only pass fails.
Database paths are retained as emitted: temporary staged Core/library paths are
useful provenance, not a promise that the database is replayable after cleanup.
Generated sketch source remains in the retained build tree.

`size.txt` is the unmodified output from the pinned `arm-none-eabi-size -A`.
`size.json` preserves every section's size and address. Its `flashBytes` and
`ramBytes` use the existing Arduino platform size-regex categories, not a new
definition of device memory consumption. `totalSectionBytes` includes debugging
sections. Missing artifacts, invalid databases, failed size extraction, and
nonzero compilation exits are failures. Available evidence survives, later
sketches are still attempted, and the driver reports aggregate failure.

## CI And Tests

The [Core package workflow](../.github/workflows/core-package-ci.yml) uploads the
complete `build-evidence-windows` artifact with `if: always()` and 30-day
retention. It includes normal builds and a `failure-fixtures` directory. The
job summary lists statuses and the log, size, and firmware paths for each
sketch. GitHub provides an archive URL, not individual file URLs: summary links
download that archive and their labels identify files within it. Downloaded
`summary.md` files use relative links to the individual evidence files.

Run the network-free process, parser, and summary contracts on either host:

```powershell
pwsh -File ./tests/host/build/BuildEvidenceTest.ps1
```

On Windows, also exercise the real locked tools with an early compiler error,
an undefined-symbol link error, and a later successful sketch:

```powershell
.\tests\host\build\BuildEvidenceTest.ps1 `
    -ArduinoCli $tools.ArduinoCliPath `
    -ArduinoDataDirectory $tools.ArduinoDataDirectory `
    -ArduinoUnitDirectory $tools.ArduinoUnitDirectory `
    -OutputDirectory .\artifacts\failure-evidence
```

The expected failures make the driver fail; the harness succeeds only after
checking both diagnostics, native exit codes, retained generated source and
partial map/objects, the later successful build's complete evidence, artifact
hashes, both compilation databases, selection by an `.ino` file path, and
rejection of output reuse without modifying prior evidence. File selections
retain the original driver behavior: they select their parent sketch directory.
The pinned CLI still requires a main `.ino` or `.pde` matching that directory's
name; a differently named file without that main file is not a valid sketch.

## Validation Record

Recorded 2026-09-15 against maintenance `97694593c986904f5a7d30f3f6c13ae27d827949`.
Local target validation used Windows 11, PowerShell 7.6.6, Git
2.55.0.windows.5, CLI 1.5.1, GCC 5.4.1 and binutils 2.26.2.20160923 from the
shared installer. Both repository and evidence paths contained spaces.

- Live-output tests passed, including simultaneous large stdout/stderr streams,
  trailing output without a newline, quoted arguments, and native exit code 23.
- Database structure/sketch-identity, structured section sizes, and empty-failure
  summary tests passed. All 15 existing build-lock tests passed.
- A normal representative build retained every required nonempty artifact.
- A representative AzureIotHubExample build passed with an absolute retained
  build-directory length of 140 characters; the longest generated file path was
  194 characters. The driver enforces this conservative Windows bound, and a
  141-character preflight fixture is rejected without creating output.
- Real compiler/linker failure fixtures passed, including a subsequent successful
  sketch and exact-copy hash checks.
- All 13 pre-PR sketches and all 13 new-driver sketches compiled. Matched-path
  comparisons found identical raw binary SHA-256 values and identical sizes
  and addresses for every GNU size section, including debugging sections.

For that equivalence check, the unmodified pre-PR driver first ran with verbose
output and its final staging deletion intercepted solely to retain the baseline.
The new driver then used a validation-only PowerShell wrapper to reuse those
same private staging and build paths, with their old contents removed first.
The wrapper created the separate evidence parents and suppressed final staging
deletion for inspection. No source, tool, recipe, compiler argument, or binary
was rewritten or normalized. Raw size headers name different copied ELF
locations; every reported section row matched exactly.

| Sketch | Flash Bytes | RAM Bytes | Binary And All Sections |
| --- | ---: | ---: | --- |
| AzureIotHubExample | 480160 | 52780 | Identical |
| BarometricPressureSensor | 222236 | 44304 | Identical |
| BoardInit | 224328 | 45276 | Identical |
| digital_potentiometer | 218528 | 44396 | Identical |
| DigitalPotControl | 221196 | 44304 | Identical |
| HttpTest | 374052 | 45920 | Identical |
| master_reader | 218512 | 44396 | Identical |
| master_writer | 218536 | 44396 | Identical |
| SFRRanger_reader | 218880 | 44396 | Identical |
| slave_receiver | 218656 | 44396 | Identical |
| slave_sender | 218408 | 44396 | Identical |
| UnitTest | 272464 | 47452 | Identical |
| VoiceToTwitter | 405024 | 53172 | Identical |

## Deferred Findings

1. **Existing path-dependent firmware.** Random private staging paths appear
   verbatim in runtime diagnostic strings via `__FILE__`. An ordinary independent
   representative rebuild therefore had a different binary hash despite equal
   flash/RAM sizes. Inspection located the staging UUID inside the differing
   binary bytes; matched-path rebuilds demonstrated exact equality. Debug
   section sizes can also depend on path lengths. PR 3 deliberately does not
   change diagnostic source strings, compiler flags, or staging policy to fix
   this. Review reproducible-path policy separately; PR 4 comparisons must hold
   paths fixed as already required by its plan.
2. **Compilation databases and temporary inputs.** CLI 1.5.1 emits a database
   during normal compilation as well as through its database-only capability.
   Both forms are retained when available. Making all database input paths
   replayable after staging cleanup would require a separate staging-retention
   or remapping decision, outside this PR.
3. **Local Windows Git trust.** Windows Git rejected the WSL UNC checkout as
   foreign-owned. Validation used a disposable Windows-local checkout with
   spaces, created with Linux Git. No global safe-directory exception or account
   change was made; this is a local host prerequisite, not a toolchain change.
4. **Independent output-path constraint.** Retained builds inherit the selected
  output root, unlike the old temporary build tree. A 140-character absolute
  build path is verified and enforced conservatively on Windows; measurement of
  a wider output-path boundary is deferred. The existing 70-character installer
  limit describes a different include-path lookup problem and is not evidence
  that arbitrarily deep build-output paths work.