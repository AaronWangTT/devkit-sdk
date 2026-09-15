# Windows Toolchain Path Limit

The AZ3166 GCC 5.4.1 toolchain has a reproducible installation-root path
limit. The shared installer therefore rejects roots longer than 70 characters.

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

The candidate's staging prefix is longer than the final root. Extraction and
Board Manager installation run there, but the compiler is only queried for its
version before promotion. Sketch compilation and its GCC include-path search
run from the final installation root. The full boundary test covers installation
with the longer staging prefix separately from the compilation measurements.