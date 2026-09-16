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
repeatable base and Azure-enabled package builds on Windows and Ubuntu, and
requires both hosts to produce byte-for-byte identical archives per profile.
For a committed profile-aware revision, run the package check with PowerShell 7
and GNU `ar`/`nm` on PATH (or pass their paths using `-Ar` and `-Nm`):

```powershell
& .\tools\package\Test-Az3166BoardPackage.ps1 `
	-Revision HEAD -Profile base `
	-OutputDirectory .\artifacts
```

The package builder disables Git's automatic line-ending conversion and uses
UTC ZIP timestamps without modifying the caller's Git configuration or
environment.

The new default is `base`; request `-Profile azure-iot` for a complete board
package with Azure support. Neither profile ships the original monolithic
archive. Historical 2.x tags remain full packages with their original filenames
and hashes, and reject a base-profile request. Working-tree changes are not
included by `-Revision HEAD`; use staging for uncommitted source validation.

A release tag on `maintenance` must match the runtime version and record its
one intended `releaseProfile` in the package layout. Profile-based publication
requires an approved next-major version. The manual `Core release` workflow
requires the matching profile and explicit hardware/firmware-review confirmation,
runs both-profile CI at the resolved tag commit, and compares the selected
artifact with CI before publication. It publishes only that profile for that
version. Existing releases cannot be overwritten.

Release metadata supplies immutable archive fields for the separately reviewed
Board Manager index update; the workflow does not edit that index or consumer
repositories. Azure users must pin an Azure-enabled version: upgrading to a newer
base release removes Azure support. See the
[separation and release plan](docs/azure-iot-separation-plan.md) for acceptance
limits and the release process. No new major release has been published yet.

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
| [src/extensions](src/extensions) | Core-hosted networking, HTTP, time, configuration, telemetry, and display services. |
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
to its installed location under the archive's `AZ3166/` prefix. Both
checkout staging and committed-revision packaging use the same validated map.
Do not copy ownership directories directly into an Arduino installation; use
[Stage-Az3166Platform.ps1](tools/package/Stage-Az3166Platform.ps1) or the build
drivers. Library examples remain with their libraries. Profile membership, not
the directory name alone, determines whether an extension is included. Azure
configuration and Application Insights telemetry live under
[libraries/AzureIoT/platform](libraries/AzureIoT/platform), outside the library's
sketch-selected source tree. Full-profile mappings still compile them in the
Core; they are not copied into the installed Arduino library. The base provider
and telemetry stub have no cloud behavior.

AzureIoT owns [its serial logging helpers](libraries/AzureIoT/src/SerialLog.h),
which now compile only when that library is selected. The header name and C
function names are unchanged; an external sketch including this header now
selects AzureIoT instead of finding it in the Core. The
[OTA library](libraries/OTA/library.properties) similarly provides
[OTAFirmwareUpdate.h](libraries/OTA/src/OTAFirmwareUpdate.h) on demand, using
the Core HTTP client and board flash services. This relocation does not change
or validate OTA runtime behavior.

The HTTP client carries its unchanged third-party
[http-parser snapshot](src/extensions/http-client/http_parser), including the
license. Its installed `cores/arduino/httpclient/http_parser` path is unchanged,
and exact content pins preserve its vendor warning classification. The
Core-hosted HTTP server now delegates optional cloud settings to a build-selected
provider; its separate parsing implementation is unchanged. See the
[Azure IoT separation plan](docs/azure-iot-separation-plan.md) for the validated
base/full boundaries. Base configuration keeps Wi-Fi settings but no Azure
commands, credential fields, or cloud writes. The empty provider is selected
instead of AzureConfiguration, not in addition to it; nonzero cloud option flags
are currently ignored in base builds.

## Tests

Core package CI runs package-map contract tests on Windows and Ubuntu. It uses
[Test-Az3166HostTests.ps1](tools/test/Test-Az3166HostTests.ps1) to execute the
runtime-version, timer, base/full configuration, WiFiUDP, and legacy IoT-client
harnesses on Ubuntu. Base runs four programs and full runs six, with
AddressSanitizer and UndefinedBehaviorSanitizer where supported. Client tests use dependency fakes;
configuration tests also exercise the real multipart helper. They do not execute
the ARM-only vendor libraries or the real JSON parser. The corresponding checks
also run during releases when the tagged revision contains those harnesses.

On Windows, [Test-Az3166Sketches.ps1](tools/test/Test-Az3166Sketches.ps1) compiles
13 base sketches and 16 full sketches using the same production staging code.
Both include SensorStatus and VoiceRecord so Sensors and Audio coverage does not
depend on cloud examples. Full also includes the two cloud examples and the
[Azure DPS link probe](tests/host/package/fixtures/AzureDpsLinkProbe/AzureDpsLinkProbe.ino).
Other library examples are not implicitly added. Base ELF files must have no
Azure-only definitions; cloud probes must actually link Azure definitions.
These are compile-only checks, not hardware execution or validation against
live cloud services.
`tests/hardware/manual/HttpTest` is an unbounded HTTP/NTP concurrency and memory
diagnostic, not an automated pass/fail suite. Native build commands are in the
[CI workflow](.github/workflows/core-package-ci.yml).

The sketch test script requires PowerShell 7 or later (`pwsh`), matching the CI
shell. Windows PowerShell 5.1 (`powershell.exe`) is not supported.

Install the pinned toolchain and run the sketch checks from the repository root:

```powershell
$tools = .\tools\build\Install-Az3166BuildTools.ps1 `
	-Root C:\a -DownloadCache C:\az3166-downloads
foreach ($profile in @('base', 'azure-iot')) {
	.\tools\test\Test-Az3166Sketches.ps1 -Profile $profile `
		-ArduinoCli $tools.ArduinoCliPath `
		-ArduinoDataDirectory $tools.ArduinoDataDirectory `
		-ArduinoUnitDirectory $tools.ArduinoUnitDirectory `
		-OutputDirectory ".\artifacts\sketches-$profile"
}
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

Package source paths, the archive splitter, and its inputs are resolved from the
requested Git revision. Packaging still supports the historical `AZ3166/src`
layout; the current release workflow only publishes approved profile-aware major
versions. A temporary Git index combines mapped and generated artifacts without
changing the caller's index or installed toolchain.

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
