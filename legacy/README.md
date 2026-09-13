# Historical Tooling

This directory preserves the former `AZ3166/jenkins` bundles for reference and
recovery. They are not part of the maintained GitHub Actions build or release
workflow, and they have not been executed or modernized as part of relocation.

| Bundle | Original purpose | Important dependencies |
| --- | --- | --- |
| [jenkins/DevKitTestTool](jenkins/DevKitTestTool) | Device-test execution, serial capture, example verification, reports, and packaging. | .NET Framework 4.6.1, Arduino tooling, configured board and workspace. |
| [jenkins/InstallationPackageScript](jenkins/InstallationPackageScript) | Build host installers and bundle toolchains. | Historical Node/Gulp/Babel dependencies and external installer projects/artifacts. |
| [jenkins/deployment](jenkins/deployment) | Publish archives and firmware, update indexes, and configure test runs. | Historical Azure PowerShell modules, storage credentials, and Jenkins workspace inputs. |
| [jenkins/JobConfig](jenkins/JobConfig) | Jenkins build, deployment, static-analysis, and spelling jobs. | Jenkins plugins, external network shares, and preconfigured workspace tools. |

## Safety And Compatibility

These files are historical configurations, not supported operational entry
points. Some job definitions contain destructive workspace commands, and the
deployment scripts overwrite remote artifacts. Do not import or run them
against a production workspace or service without a separate review.

The bundles retain their internal hierarchy. Repository-source references have
been adjusted for root `src` and `libraries`, but external workspace paths,
service endpoints, credentials, runtime versions, and tool assumptions have not
been repaired or validated. In particular, the old package-generation modes do
not assemble the current split layout. Use
[the maintained package tools](../tools/package) and
[sketch driver](../tools/test/Test-Az3166Sketches.ps1) instead.

## Provisioning Utility

The historical [DICE enrollment utility](../tools/provisioning/dice_device_enrollment)
is stored with host provisioning tools, not with firmware source. Its source,
Visual Studio solution, Makefile, and bundled DICE/RIoT code were moved together.
Its placement does not imply current support or successful execution.

The Visual Studio project requests toolset `v141` and Windows SDK
`10.0.17763.0`. The relocation audit found 11 unique pre-existing stale header
paths in the project/filter files. Most referenced headers reside under
`RIoT/Core/RIoTCrypt/include`; the listed `RiotAesTables.h` is absent from the
tracked bundle. The solution project paths and the 16 Makefile source paths
resolve after relocation. Those checks do not establish that either build works.

No toolchain installation, device enrollment, certificate generation, firmware
upload, or legacy deployment was performed.

## Recovery Candidates

- Port useful serial-result parsing and report generation from DevKitTestTool
  into maintained test automation before retiring that implementation.
- Review provisioning dependencies, cryptographic assumptions, and secret
  handling before enabling a supported DICE workflow.
- Keep tool restoration separate from structural changes and require explicit
  fixtures, failure criteria, and isolated environments for execution.