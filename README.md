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
& .\tools\Test-Az3166BoardPackage.ps1 `
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

## Tests

Core package CI executes the runtime-version check and the WiFiUDP and legacy
IoT-client host harnesses on Ubuntu. Both client harnesses use AddressSanitizer
and UndefinedBehaviorSanitizer. They compile the client implementation with
dependency fakes; they do not execute the ARM-only vendor libraries or the real
JSON parser. The corresponding checks also run during releases when the tagged
revision contains those harnesses.

On Windows, [Test-Az3166Sketches.ps1](AZ3166/tests/Test-Az3166Sketches.ps1)
compiles every discovered Arduino test sketch against the checkout. These are
compile-only checks, not hardware execution or validation against live cloud
services. Native build commands are maintained in the
[CI workflow](.github/workflows/core-package-ci.yml).

The sketch test script requires PowerShell 7 or later (`pwsh`), matching the CI
shell. Windows PowerShell 5.1 (`powershell.exe`) is not supported.

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
