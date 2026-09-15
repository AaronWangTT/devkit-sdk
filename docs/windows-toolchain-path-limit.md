# Windows Toolchain Path Limit

The AZ3166 GCC 5.4.1 toolchain has a reproducible installation-root path
limit. The shared installer therefore rejects roots longer than 70 characters.

Use direct local-volume paths for the installation and download cache. UNC,
network-mapped, and `subst` paths are not supported. Overlap checks compare native
volume identities, not just drive letters. An existing installation root must
have a valid ownership manifest; even empty unowned directories are refused.
Components
ending in dots or spaces, DOS short names containing `~`, wildcard brackets,
alternate data streams,
device namespaces, drive-relative paths, and reserved device names are rejected
before normalization. Directory junctions and symbolic links are also rejected,
including ancestors and entries inside either tree.

## Environment

- Windows 11 Enterprise 10.0.26200;
- PowerShell 7.6.6;
- Arduino CLI 1.5.1;
- Arduino IDE 1.8.19 Board Manager bootstrap;
- AZ3166 Core 2.0.2;
- `arm-none-eabi-gcc` package `5_4-2016q3`, compiler 5.4.1;
- representative sketch `examples/cloud/AzureIotHubExample`.

## Method

Each case used a fresh directory directly under `C:\` whose absolute length
matched the requested value. The verified download cache, sketch, local Core
checkout, FQBN, and compile command remained unchanged. Setup ran offline
through `Install-Az3166BuildTools.ps1`; compilation ran through
`Test-Az3166Sketches.ps1 -VerboseBuild`.

The verbose output contained no response-file arguments. Include and object
paths were measured directly from the emitted compiler commands. Shortening
only the toolchain root restored the build.

## Results

| Root | Compiler | Target header | Max include | Max object | Response files | Result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 4 | 90 | 127 | 224 | 174 | 0 | Pass |
| 20 | 106 | 143 | 224 | 174 | 0 | Pass |
| 40 | 126 | 163 | 224 | 174 | 0 | Pass |
| 60 | 146 | 183 | 224 | 174 | 0 | Pass |
| 70 | 156 | 193 | 224 | 174 | 0 | Pass |
| 71 | 157 | 194 | 224 | 174 | 0 | Pass |
| 72 | 158 | 195 | 213 | Not emitted | 0 | Fail |
| 75 | 161 | 198 | 213 | Not emitted | 0 | Fail |
| 80 | 166 | 203 | 213 | Not emitted | 0 | Fail |

All numeric path columns are character counts. Failed builds stopped before an
object-file command was emitted.

The longest observed passing root was 71 characters. The shortest failing root
was 72 characters, where GCC reported:

```text
fatal error: bits/cpu_defines.h: No such file or directory
```

The supported maximum is 70 characters, leaving one character of margin below
the observed boundary. This is an installation-root constraint, not a general
Windows path-length limit.

## Installer Boundary Coverage

The Windows CI job also runs `ToolchainInstallerTest.ps1 -DownloadCache` against
the verified downloads. It performs a full offline installation at a 70-character
root with a long parent directory and a one-character leaf, then checks an
unchanged second setup, `-VerifyOnly`, and clean offline replacement without
staging or backup leftovers. It also replaces the installed CLI with a symbolic
link and verifies that verification and clean setup reject the linked tree
without removing the external executable.

The integration test also corrupts CLI, GCC, and OpenOCD executables in the
managed installation, checks that launch failures become verification
diagnostics, and requires normal offline setup to repair all three.

If the old installation cannot be deleted after a verified replacement, setup
reports a warning and returns its exact path in `PendingCleanupPath`. The active
manifest records the backup ID before promotion, so a later normal setup can
retry cleanup without reinstalling. `-VerifyOnly` reports the pending path
without writing, and another `-Clean` requires cleanup to finish first. Cleanup
never selects directories by a wildcard; malformed or overlapping records and
linked backup trees are rejected. Existing backups must have a valid ownership
manifest, which cleanup preserves until every payload entry is removed. A missing
backup path only clears the stale journal. The integration test holds a backup
file open to exercise deferred cleanup and the next-run retry.

Temporary-download and staging cleanup failures stop setup with an error naming
the retained path. Release any file lock and remove that exact temporary artifact
before retrying; these failures are not reported as a successful clean setup.
If promotion already completed, `-VerifyOnly` can check the installed root without
removing the retained staging directory.
If installation or rollback already failed, the staging cleanup error is appended
to that primary error so its recovery paths remain visible.

If promotion or final verification fails, rollback renames the failed candidate
to an operation-specific `.az3166-failed-*` sibling without traversing its
contents, then restores the previous installation. Failed candidates are retained
for inspection, not recursively deleted. If a lock or another filesystem error
prevents rollback, the error names the installation, backup, and candidate paths;
an operation-specific `.az3166-recovery-*.json` record preserves those paths and
both errors. The known-good backup is left intact for manual recovery. Integration
tests cover a linked candidate and a locked candidate that blocks the rename.

The candidate's staging prefix is longer than the final root. Extraction and
Board Manager installation run there, but the compiler is only queried for its
version before promotion. Sketch compilation and its GCC include-path search
run from the final installation root. The full boundary test covers installation
with the longer staging prefix separately from the compilation measurements.