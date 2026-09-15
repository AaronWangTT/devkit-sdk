#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tools/test/Az3166Warnings.ps1')
$layout = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'platform/az3166/package-layout.json') | ConvertFrom-Json

function Assert-WarningPolicyTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$context = [pscustomobject]@{
    sketch = 'examples/board/BoardInit'
    sketchDirectory = 'C:/repository with spaces/examples/board/BoardInit'
    buildDirectory = 'C:/evidence with spaces/BoardInit/build'
    environment = [pscustomobject]@{
        repository = 'C:/repository with spaces'
        stagedPlatformDirectory = 'C:/stage/hardware/AZ3166Checkout/stm32f4'
        arduinoUnitDirectory = 'C:/tools/ArduinoUnit'
        stagedArduinoUnitDirectory = 'C:/stage/libraries/ArduinoUnit'
        compilerRoot = 'C:/tools/gcc'
    }
}

$diagnostics = @(ConvertFrom-Az3166Diagnostics -Context $context -Layout $layout -Lines @(
    'C:\stage\hardware\AZ3166Checkout\stm32f4\cores\arduino\Print.h:34:22: warning: unused parameter ''value'' [-Wunused-parameter]'
    'C:/stage/hardware/AZ3166Checkout/stm32f4/cores/arduino/httpclient/http_parser/http_parser.h:42: warning: historical message'
    'C:/stage/hardware/AZ3166Checkout/stm32f4/system/mbed-os/platform/FileHandle.h:9:2: note: referenced here'
    'C:/stage/libraries/ArduinoUnit/src/ArduinoUnit.h:3: warning: test dependency [-Wsign-compare]'
    'C:/tools/gcc/arm-none-eabi/include/stdio.h:8: warning: runtime header [-Wpedantic]'
    'C:/repository with spaces/examples/board/BoardInit/BoardInit.ino:12: error: invalid expression'
    'C:/evidence with spaces/BoardInit/build/sketch/BoardInit.ino.cpp:15: warning: generated sketch [-Wunused-variable]'
    'C:/stage/hardware/AZ3166Checkout/stm32f4/unmapped/header.h:6: warning: unknown ownership'
    'arm-none-eabi-ld: warning: unknown linker warning'
    'warning: no source location'
    'C:/repository with spaces-other/vendor/header.h:6: warning: not the repository'
    'Compiling sketch...'
))
Assert-WarningPolicyTest ($diagnostics.Count -eq 11) 'Diagnostics were dropped or non-diagnostic output was parsed.'
Assert-WarningPolicyTest ($diagnostics[0].source -ceq 'src/core/arduino/Print.h' -and $diagnostics[0].ownership -eq 'first-party') 'Staged Core ownership was not mapped.'
Assert-WarningPolicyTest ($diagnostics[0].line -eq 34 -and $diagnostics[0].column -eq 22 -and $diagnostics[0].option -eq '-Wunused-parameter' -and $diagnostics[0].message -ceq "unused parameter 'value'") 'GCC diagnostic fields were not retained.'
Assert-WarningPolicyTest ($diagnostics[1].source -ceq 'vendor/http-parser/http_parser.h' -and $diagnostics[1].ownership -eq 'vendor' -and $null -eq $diagnostics[1].option) 'Longest manifest mapping must win for vendor code staged beneath first-party directories.'
Assert-WarningPolicyTest ($diagnostics[2].source -ceq 'vendor/mbed-os/platform/FileHandle.h' -and $diagnostics[2].severity -eq 'note') 'Vendor notes were not retained.'
Assert-WarningPolicyTest ($diagnostics[3].source -ceq 'ArduinoUnit/src/ArduinoUnit.h' -and $diagnostics[3].ownership -eq 'test-dependency') 'Downloaded dependency ownership was not mapped.'
Assert-WarningPolicyTest ($diagnostics[4].ownership -eq 'toolchain') 'Runtime header ownership was not mapped.'
Assert-WarningPolicyTest ($diagnostics[5].source -ceq 'examples/board/BoardInit/BoardInit.ino' -and $diagnostics[5].severity -eq 'error') 'Repository paths containing spaces were not mapped.'
Assert-WarningPolicyTest ($diagnostics[6].ownership -eq 'first-party') 'Generated sketch sources must remain first-party.'
foreach ($diagnostic in $diagnostics[7..10]) {
    Assert-WarningPolicyTest ($diagnostic.ownership -eq 'unclassified') "Unknown diagnostic was classified: $($diagnostic.raw)"
}
Write-Host 'PASS GCC fields, Windows paths, manifest precedence, all ownership classes, and unknown diagnostics'

$uncContext = $context | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$uncContext.environment.stagedPlatformDirectory = '//build-host/share with spaces/platform'
$uncDiagnostics = @(ConvertFrom-Az3166Diagnostics -Context $uncContext -Layout $layout -Lines @(
    '\\BUILD-HOST\SHARE WITH SPACES\platform\cores\arduino\Print.h:34:22: warning: unused parameter [-Wunused-parameter]'
    '\\build-host\share with spaces-other\platform\cores\arduino\Print.h:34:22: warning: outside the staged share'
))
Assert-WarningPolicyTest ($uncDiagnostics[0].source -ceq 'src/core/arduino/Print.h' -and $uncDiagnostics[0].ownership -eq 'first-party') 'UNC share ownership must preserve component boundaries and ignore Windows path casing.'
Assert-WarningPolicyTest ($uncDiagnostics[1].ownership -eq 'unclassified') 'A different UNC share prefix was accepted.'
Write-Host 'PASS UNC ownership handles spaces, case, and exact share boundaries'

$context.environment.repository = '/repo'
$context.environment.stagedPlatformDirectory = '/stage/platform'
$context.environment.arduinoUnitDirectory = '/tools/ArduinoUnit'
$context.environment.stagedArduinoUnitDirectory = '/stage/libraries/ArduinoUnit'
$context.environment.compilerRoot = '/tools/gcc'
$context.sketchDirectory = '/repo/examples/board/BoardInit'
$context.buildDirectory = '/output/BoardInit/build'
$diagnostics = @(ConvertFrom-Az3166Diagnostics -Context $context -Layout $layout -Lines @(
    '/stage/platform/system/mbed-os/platform/../platform/FileHandle.h:4:1: warning: unused parameter [-Wunused-parameter]'
    '/repo/libraries/WiFi/src/WiFi.cpp:8: warning: maintained library'
    '/repo/tests/hardware/UnitTest/Test.ino:7: fatal error: missing header'
    '/Repo/src/core/arduino/Print.h:9: warning: different Linux directory'
))
Assert-WarningPolicyTest ($diagnostics[0].source -ceq 'vendor/mbed-os/platform/FileHandle.h') 'Relative path segments were not normalized before ownership mapping.'
Assert-WarningPolicyTest ($diagnostics[1].ownership -eq 'first-party' -and $diagnostics[2].ownership -eq 'first-party') 'Maintained libraries and hardware tests must remain first-party.'
Assert-WarningPolicyTest ($diagnostics[3].ownership -eq 'unclassified') 'Linux path comparisons must be case-sensitive.'
Write-Host 'PASS Linux paths, relative segments, maintained libraries, and tests'

. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')
$lock = Get-Az3166BuildLock
$policy = Get-Az3166WarningPolicy -BuildLock $lock
Assert-Az3166WarningSnapshots -Policy $policy -RepositoryRoot $repositoryRoot
$snapshotDiagnostic = @(ConvertFrom-Az3166Diagnostics -Context $context -Layout $layout -Policy $policy -Lines @(
    '/stage/platform/libraries/Audio/src/nau88c10.c:212: warning: control reaches end of non-void function [-Wreturn-type]'
    '/stage/platform/libraries/Audio/src/AudioClass.cpp:360: warning: unused variable [-Wunused-variable]'
))
Assert-WarningPolicyTest ($snapshotDiagnostic[0].ownership -eq 'vendor' -and $snapshotDiagnostic[1].ownership -eq 'first-party') 'Snapshot ownership must not exempt the maintained Audio wrapper.'
$changedSnapshotPolicy = $policy | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$changedSnapshotPolicy.vendorSnapshots[0].sha256 = '0' * 64
$rejected = $false
try { Assert-Az3166WarningSnapshots -Policy $changedSnapshotPolicy -RepositoryRoot $repositoryRoot }
catch { $rejected = $_.Exception.Message -like 'Vendor snapshot changed;*' }
Assert-WarningPolicyTest $rejected 'Modified library-local vendor snapshot content was accepted.'
Write-Host 'PASS library-local vendor snapshots are content-pinned without exempting maintained wrappers'
$policy.allowances = @([pscustomobject]@{
    id = 'mbed-unused-parameter'
    ownership = 'vendor'
    sourceGlob = 'vendor/mbed-os/platform/FileHandle.h'
    option = '-Wunused-parameter'
    component = 'mbed-os'
    version = 'snapshot@53524f91e9325534a5c8fb27eafc7622a43f5276'
    rationale = 'Historical interface default implementation.'
    removalCondition = 'Remove when the pinned interface is replaced or warning-free.'
})
Assert-Az3166WarningPolicy -Policy $policy -BuildLock $lock
$result = Get-Az3166WarningResult -Diagnostics @($diagnostics[0]) -Policy $policy -CheckStale
Assert-WarningPolicyTest ($result.passed -and $result.allowedWarningCount -eq 1 -and $result.countsByRule['mbed-unused-parameter'] -eq 1) 'Explicit vendor allowance did not match.'
Assert-WarningPolicyTest ($result.diagnostics[0].raw -ceq $diagnostics[0].raw -and $result.diagnostics[0].allowance -eq 'mbed-unused-parameter') 'Allowed diagnostics must remain intact and identify their rule.'
Write-Host 'PASS explicit vendor diagnostic remains visible and counted by rule'

$result = Get-Az3166WarningResult -Diagnostics $diagnostics -Policy $policy -CheckStale
Assert-WarningPolicyTest (-not $result.passed -and $result.firstPartyWarningCount -eq 1 -and
    @($result.violations | Where-Object { $_.reason -eq 'first-party-warning' }).Count -eq 1 -and
    @($result.violations | Where-Object { $_.reason -eq 'unclassified-warning' }).Count -eq 1) 'First-party and unknown warnings must fail.'
$unknown = $diagnostics[0] | Select-Object *
$unknown.option = '-Wunknown-vendor-warning'
$result = Get-Az3166WarningResult -Diagnostics @($unknown) -Policy $policy -CheckStale
Assert-WarningPolicyTest (-not $result.passed -and $result.violations[0].reason -eq 'unclassified-warning') 'An unknown vendor option was accepted.'
$result = Get-Az3166WarningResult -Diagnostics @() -Policy $policy -CheckStale
Assert-WarningPolicyTest (-not $result.passed -and $result.staleAllowances[0] -eq 'mbed-unused-parameter') 'A stale allowance was accepted.'
Assert-WarningPolicyTest (Get-Az3166WarningResult -Diagnostics @() -Policy $policy).passed 'A partial inventory should not reject absent components as stale.'
Write-Host 'PASS injected first-party, unknown vendor, and stale warnings fail; partial inventory is explicit'

$duplicate = $policy.allowances[0] | Select-Object *
$duplicate.id = 'overlapping-allowance'
$policy.allowances += $duplicate
$result = Get-Az3166WarningResult -Diagnostics @($diagnostics[0]) -Policy $policy -CheckStale
Assert-WarningPolicyTest (-not $result.passed -and $result.violations[0].reason -eq 'ambiguous-allowance') 'Overlapping allowances must fail.'
Write-Host 'PASS a warning cannot silently match multiple allowances'

$policy.allowances = @($duplicate)
$duplicate.PSObject.Properties.Remove('option')
$duplicate | Add-Member -NotePropertyName messageRegex -NotePropertyValue '^historical interface warning$'
Assert-Az3166WarningPolicy -Policy $policy -BuildLock $lock
$withoutOption = $diagnostics[0] | Select-Object *
$withoutOption.option = $null
$withoutOption.message = 'historical interface warning'
Assert-WarningPolicyTest (Get-Az3166WarningResult -Diagnostics @($withoutOption) -Policy $policy -CheckStale).passed 'Narrow GCC 5 diagnostic without option was rejected.'
$withoutOption.option = '-Wnew-option'
Assert-WarningPolicyTest (-not (Get-Az3166WarningResult -Diagnostics @($withoutOption) -Policy $policy -CheckStale).passed) 'Message fallback must not exempt warnings with an emitted option.'
Write-Host 'PASS message fallback is anchored and applies only when GCC emits no option'

foreach ($mutation in @(
    { param($fixture) $fixture.warningProfile = 'none' }
    { param($fixture) $fixture.allowances[0].ownership = 'first-party' }
    { param($fixture) $fixture.allowances[0].sourceGlob = 'vendor/**' }
    { param($fixture) $fixture.allowances[0].sourceGlob = 'src/core/arduino/Print.h' }
    { param($fixture) $fixture.allowances[0].version = 'latest' }
    { param($fixture) $fixture.allowances[0].rationale = '' }
    { param($fixture) $fixture.allowances[0].messageRegex = '^.*$' }
    { param($fixture) $fixture.allowances[0].messageRegex = 'historical' }
    { param($fixture) $fixture.allowances += $fixture.allowances[0] }
)) {
    $fixture = $policy | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $mutation $fixture
    $rejected = $false
    try { Assert-Az3166WarningPolicy -Policy $fixture -BuildLock $lock }
    catch { $rejected = $true }
    Assert-WarningPolicyTest $rejected 'An invalid warning policy was accepted.'
}
Write-Host 'PASS suppression profiles, first-party exemptions, broad rules, missing pins, and duplicate IDs are rejected'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166 warning evidence $([guid]::NewGuid().ToString('N'))"
try {
    $directory = Join-Path $fixtureRoot 'BoardInit'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $policy.allowances = @()
    $context | Add-Member -NotePropertyName compile -NotePropertyValue @{ arguments = @('compile', '--warnings', 'all'); exitCode = 0 }
    $context | Add-Member -NotePropertyName status -NotePropertyValue 'passed'
    $context | Add-Member -NotePropertyName errors -NotePropertyValue @()
    $contextPath = Join-Path $directory 'build-context.json'
    $context | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contextPath -Encoding utf8
    $stdoutPath = Join-Path $directory 'build.stdout.log'
    $stderrPath = Join-Path $directory 'build.stderr.log'
    Set-Content -LiteralPath $stdoutPath -Value 'Compiling sketch' -Encoding utf8
    Set-Content -LiteralPath $stderrPath -Value '/repo/src/core/arduino/Print.h:9: warning: injected first-party warning [-Wunused-parameter]' -Encoding utf8
    $before = (Get-FileHash -LiteralPath $stderrPath).Hash
    $report = Export-Az3166WarningEvidence -OutputDirectory $fixtureRoot -Policy $policy -Layout $layout
    Assert-WarningPolicyTest (-not $report.passed -and $report.firstPartyWarningCount -eq 1 -and $report.failedSketches.Count -eq 1) 'Retained first-party warning did not fail the sketch.'
    Assert-WarningPolicyTest ((Get-Content -Raw -LiteralPath $contextPath | ConvertFrom-Json).status -eq 'failed') 'Build context omitted warning-policy failure.'
    Assert-WarningPolicyTest ((Get-FileHash -LiteralPath $stderrPath).Hash -ceq $before) 'Policy evaluation modified raw diagnostics.'
    foreach ($file in @('BoardInit/warnings.json', 'warning-summary.json', 'warning-summary.md')) {
        Assert-WarningPolicyTest ((Get-Item -LiteralPath (Join-Path $fixtureRoot $file)).Length -gt 0) "Missing warning evidence: $file"
    }
    $context | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contextPath -Encoding utf8
    Set-Content -LiteralPath $stderrPath -Value '' -Encoding utf8
    $report = Export-Az3166WarningEvidence -OutputDirectory $fixtureRoot -Policy $policy -Layout $layout -RequireCompleteInventory
    Assert-WarningPolicyTest (-not $report.passed -and $report.evidenceIssues -contains 'Warning inventory does not contain the required 13 sketches.') 'CI accepted an incomplete warning inventory.'
    Remove-Item -LiteralPath $stderrPath
    $report = Export-Az3166WarningEvidence -OutputDirectory $fixtureRoot -Policy $policy -Layout $layout
    Assert-WarningPolicyTest (-not $report.passed -and $report.evidenceIssues[0] -like '*Missing raw diagnostic stream*') 'Missing raw diagnostics were silently accepted.'
    $sketchReport = Get-Content -Raw -LiteralPath (Join-Path $directory 'warnings.json') | ConvertFrom-Json
    Assert-WarningPolicyTest (-not $sketchReport.passed -and $sketchReport.evidenceIssues[0] -like '*Missing raw diagnostic stream*') 'Per-sketch warning evidence incorrectly passed with a missing diagnostic stream.'
    $context.compile.arguments = @('compile', '--warnings', 'none')
    $context | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contextPath -Encoding utf8
    Set-Content -LiteralPath $stderrPath -Value '' -Encoding utf8
    $report = Export-Az3166WarningEvidence -OutputDirectory $fixtureRoot -Policy $policy -Layout $layout
    Assert-WarningPolicyTest (-not $report.passed -and $report.evidenceIssues[0] -like '*did not select the all warning profile*') 'Retained evidence with suppressed warnings was accepted.'
    Write-Host 'PASS retained streams, per-sketch and aggregate failures, missing evidence, and complete-inventory gate'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-package-ci.yml')
Assert-WarningPolicyTest ($workflow.Contains('./tests/host/build/WarningPolicyTest.ps1') -and $workflow.Contains('warning-summary.md')) 'CI must run warning contracts and publish the rule summary.'
$driver = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tools/test/Test-Az3166Sketches.ps1')
Assert-WarningPolicyTest ($driver.Contains('Export-Az3166WarningEvidence') -and $driver.Contains('Assert-Az3166WarningSnapshots') -and $driver.Contains('-RequireCompleteInventory:(-not $Sketch)')) 'The sketch driver must enforce warnings, snapshot ownership, and complete default inventory.'
Write-Host 'PASS CI and the shared sketch driver enforce and retain warning policy evidence'