# IoT DevKit SDK

## HomeTemperature maintained release

The `maintenance` branch is maintained for
[AaronWangTT/HomeTemperature](https://github.com/AaronWangTT/HomeTemperature)
from Microsoft's final 2.0.0 release. Core 2.0.2 carries forward the corrected
`dtostrf()` formatting and opt-in SDK telemetry behavior from 2.0.1, and fixes
the version returned by `getDevkitVersion()`.

The fork's `master` branch preserves Microsoft's archived upstream history and
does not receive HomeTemperature maintenance changes. Submit maintained Core
fixes, packaging changes, and release preparation through pull requests to
`maintenance`. Core package CI validates the runtime version API, verifies
repeatable package builds on Windows and Ubuntu, and requires both platforms to
produce byte-for-byte identical archives. To perform the same package check
locally from a committed revision:

```powershell
& .\tools\package\Test-Az3166BoardPackage.ps1 `
	-ExpectedVersion 2.0.2 `
	-OutputDirectory .\artifacts
```

The package builder disables Git's automatic line-ending conversion and uses
UTC ZIP timestamps without modifying the caller's Git configuration or
environment.

A numeric semantic-version tag created from a verified `maintenance` commit must
exactly match `SystemVersion.h`. Creating or pushing the tag does not publish a
release. To publish it, manually run the `Core release` workflow from the
`maintenance` branch and supply the existing tag as its version input. The
workflow verifies that the tag belongs to `maintenance`, repeats the package and
runtime checks from that tagged commit, and creates the versioned GitHub release.
It does not update the package-index or consumer repositories. Re-running it for
an existing release fails rather than replacing the release or moving its tag.

Core package CI continues to run automatically for pull requests and pushes to
`maintenance`. Its uploaded files are short-lived workflow artifacts for
comparison, not published Core releases.

This SDK is used to develop and prototype Internet of Things (IoT) solutions leveraging Microsoft Azure services and the **MXChip IoT DevKit** (a.k.a **DevKit**) which is an Arduino compatible board with rich peripherals and sensors.

With this SDK, you can use [Visual Studio Code](https://code.visualstudio.com/) with [Arduino Extension](https://marketplace.visualstudio.com) to rapidly build a full-fledged IoT application that integrates multiple services like Azure IoT Hub, Logic Apps and Cognitive Services.

## Repository layout

| Directory | Purpose |
| --- | --- |
| [src/core/arduino](src/core/arduino) | Arduino compatibility APIs and the Core version API. |
| [src/bsp/az3166](src/bsp/az3166) | Board adapters, startup integration, configuration, variants, and boot support. |
| [src/extensions](src/extensions) | Core-hosted networking, HTTP, time, configuration, telemetry, display, OTA, and diagnostics services. |
| [vendor](vendor) | Imported dependency bundles, headers, licenses, and prebuilt archives. |
| [platform/az3166](platform/az3166) | Arduino metadata and the source-to-package map. |
| [libraries](libraries) | Arduino library packages with their original metadata and examples. |
| [examples](examples) | Standalone cloud, board, SPI, and I2C demonstration projects. |
| [tests/host](tests/host) | Runtime-version, WiFiUDP, and legacy IoT-client host tests. |
| [tests/hardware](tests/hardware) | ArduinoUnit device suite and the manual HTTP/NTP stress test. |
| [tools/test](tools/test) | Shared host-test and sketch compilation drivers. |
| [tools/package](tools/package) | Validated staging, deterministic package builder, and verifier. |
| [tools/provisioning](tools/provisioning) | Historical DICE enrollment utility; its build and runtime are not validated by maintained CI. |
| [legacy](legacy/README.md) | Archived Jenkins, installer, deployment, and device-test tooling. |
| [docs](docs/devkit-sdk-hardening-plan.md) | Structure and hardening plan. |

The [package map](platform/az3166/package-layout.json) assigns every payload file
to its original installed location under the archive's `AZ3166/` prefix. Both
checkout staging and committed-revision packaging use the same validated map.
Do not copy ownership directories directly into an Arduino installation; use
[Stage-Az3166Platform.ps1](tools/package/Stage-Az3166Platform.ps1) or the build
drivers. Library names, public headers, default service inclusion, and the 15
library examples are preserved. The extension category does not make those
services optional at build time.

## Tests

Core package CI runs package-map contract tests on Windows and Ubuntu. It uses
[Test-Az3166HostTests.ps1](tools/test/Test-Az3166HostTests.ps1) to execute the
runtime-version check and the WiFiUDP and legacy IoT-client harnesses on Ubuntu.
Both client harnesses use AddressSanitizer
and UndefinedBehaviorSanitizer. They compile the client implementation with
dependency fakes; they do not execute the ARM-only vendor libraries or the real
JSON parser. The corresponding checks also run during releases when the tagged
revision contains those harnesses.

On Windows, [Test-Az3166Sketches.ps1](tools/test/Test-Az3166Sketches.ps1)
discovers sketches under `examples` and `tests/hardware` and compiles them against
the checkout. This preserves the existing 13-project coverage: 11 standalone
examples and 2 device-test projects. The 15 examples inside the shipped Arduino
libraries are unchanged and are not included in this scan. These are compile-only
checks, not hardware execution or validation against live cloud services.
`tests/hardware/manual/HttpTest` is an unbounded HTTP/NTP concurrency and memory
diagnostic, not an automated pass/fail suite. Native build commands are in the
[CI workflow](.github/workflows/core-package-ci.yml).

The sketch test script requires PowerShell 7 or later (`pwsh`), matching the CI
shell. Windows PowerShell 5.1 (`powershell.exe`) is not supported.

Install the pinned toolchain and run the sketch checks from the repository root:

```powershell
$tools = .\tools\build\Install-Az3166BuildTools.ps1 `
	-Root C:\a -DownloadCache C:\az3166-downloads
.\tools\test\Test-Az3166Sketches.ps1 `
	-ArduinoCli $tools.ArduinoCliPath `
	-ArduinoDataDirectory $tools.ArduinoDataDirectory `
	-ArduinoUnitDirectory $tools.ArduinoUnitDirectory `
	-OutputDirectory .\artifacts\sketches
```

Add `-Sketch .\tests\hardware\UnitTest` to the sketch-test command to compile a
single project. The toolchain root must not exceed 70 characters.

`-OutputDirectory` is required. Each sketch gets its own retained verbose log,
build context, tool identities, compilation database, sketch-named firmware,
raw and structured sizes, and intermediate build files. Nonempty output roots
are rejected; choose a fresh output directory for another run.
All requested sketches are attempted, and any build or evidence failure makes
the command fail. `-VerboseBuild` remains accepted but output is always verbose.
See [build evidence and validation findings](docs/persistent-build-evidence.md)
for the layout, CI artifact links, and the existing path-dependent binary caveat.

The release workflow selects the relocated tools and host tests when present,
and falls back to their original paths for historical tags. Package source paths
are resolved from the requested Git revision, including the historical
`AZ3166/src` layout. Packaging uses a temporary Git index when combining split
directories, preserving the caller's index and the published Arduino layout.

To run the host checks with native GCC and PowerShell 7:

```powershell
pwsh -File ./tests/host/package/PackageLayoutTest.ps1
pwsh -File ./tools/test/Test-Az3166HostTests.ps1 -Sanitize
```

The host driver stages the mapped platform before compiling. Its `-CompileOnly`
option is explicitly compile/link-only and does not run tests. Current release
tags use the same host-test driver; older tags retain compatibility commands.

## Contribution

There are a couple of ways you can contribute to this repo:

- Ideas, feature requests and bugs: We are open to all ideas and we want to get rid of bugs! Use the Issues section to either report a new issue, provide your ideas or contribute to existing threads.
- Documentation: Found a typo or strangely worded sentences? Submit a PR!
- Code: Contribute bug fixes, features or design changes.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Documentation

* [Github Page](http://microsoft.github.io/azure-iot-developer-kit/) - All DevKit documentations
* [Getting Started Guide](https://microsoft.github.io/azure-iot-developer-kit/docs/get-started/) - Setup guide
* [Projects Catalog](https://microsoft.github.io/azure-iot-developer-kit/docs/projects/) - Learn and build IoT apps powered by Microsoft Azure within minutes
* [Specs & Schematics](http://www.mxchip.com/az3166) - Datasheet, schematic, all about the kit hardware

## MXChip IoT DevKit
The DevKit board features ARM Cortex-M processors. At its core, it comes with a SoC module that combines the power of the ST Microelectronics [STM32F412](http://www.st.com/content/ccc/resource/technical/document/reference_manual/group0/4f/7b/2b/bd/04/b3/49/25/DM00180369/files/DM00180369.pdf/jcr:content/translations/en.DM00180369.pdf) processor and Cypress [BCM43362](http://www.cypress.com/file/297991/download) for WiFi. For on-board peripherals, it has an OLED screen, headphone and speaker output, stereo microphone and abundant sensors such as humidity & temperature, pressure, motion (accelerometer & gyroscope) and magnetometer.

### Get a kit

You can purchase the DevKit from: **[https://aka.ms/iot-devkit-purchase](https://aka.ms/iot-devkit-purchase)**. We have opened purchase channel on [DFRobot](https://www.dfrobot.com/), [SeeedStudio](https://www.seeedstudio.com/) and [Plugable](http://plugable.com/)

### Data / Telemetry
The maintained 2.0.1 release disables SDK system telemetry by default. Define
`ENABLETRACE=1` in the platform build flags to opt in. Microsoft's original
privacy statement is available at <https://privacy.microsoft.com/en-us/privacystatement>.
