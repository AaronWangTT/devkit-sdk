#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$commonScript = Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1'
$lockPath = Join-Path $repositoryRoot 'tools/build/az3166-build-lock.json'
. $commonScript

function Assert-BuildConfigurationTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-BuildLockRejected {
    param(
        [scriptblock]$Mutate,
        [string]$ExpectedMessage
    )

    $fixturePath = Join-Path ([IO.Path]::GetTempPath()) "az3166-build-lock-$([guid]::NewGuid().ToString('N')).json"
    try {
        $fixture = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
        & $Mutate $fixture
        $fixture | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fixturePath -Encoding utf8
        $rejected = $false
        try {
            $null = Get-Az3166BuildLock -Path $fixturePath
        }
        catch {
            if ($_.Exception.Message -notlike $ExpectedMessage) {
                throw
            }
            $rejected = $true
        }
        Assert-BuildConfigurationTest $rejected "Invalid build lock was accepted: $ExpectedMessage"
    }
    finally {
        Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
    }
}

$lock = Get-Az3166BuildLock
Assert-BuildConfigurationTest ($lock.tools.armNoneEabiGcc.compilerVersion -ceq '5.4.1') 'The Stage 1 baseline must preserve GCC 5.4.1.'
Assert-BuildConfigurationTest ($lock.hostPrerequisites.windows.maximumToolchainRootLength -eq 70) 'The measured Windows toolchain-root limit must remain 70 characters.'
Assert-BuildConfigurationTest ($lock.hostPrerequisites.windows.pathConstraintStatus -like '*71 passed and 72 failed*') 'The Windows path constraint must retain its measured boundary.'
Write-Host 'PASS repository build lock is valid'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.boardManager.revision = 'maintenance'
    $fixture.boardManager.indexUrl = 'https://raw.githubusercontent.com/AaronWangTT/azureiotdevkit_tools/maintenance/package_azureboard_index.json'
} 'Invalid AZ3166 build lock: boardManager.revision must be a full lowercase Git commit ID.'
Write-Host 'PASS mutable Board Manager revision is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.arduino.cli.windowsX64.sha256 = 'ABC123'
} 'Invalid AZ3166 build lock: arduino.cli.windowsX64.sha256 must be a lowercase SHA-256 value.'
Write-Host 'PASS malformed asset checksum is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.core.toolDependencies[0].version = 'latest'
} 'Invalid AZ3166 build lock: core.toolDependencies must contain arm-none-eabi-gcc 5_4-2016q3 exactly once.'
Write-Host 'PASS mismatched tool dependency is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.arduino.cli.PSObject.Properties.Remove('windowsX64')
} 'Invalid AZ3166 build lock: missing arduino.cli.windowsX64.'
Write-Host 'PASS missing asset is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.hostPrerequisites | Add-Member -NotePropertyName 'macos' -NotePropertyValue ([pscustomobject]@{
        runner = 'macos-15'
        architecture = 'arm64'
    })
} 'Invalid AZ3166 build lock: hostPrerequisites contains unsupported entries: macos.'
Write-Host 'PASS unsupported host is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.hostPrerequisites.powershell.minimumVersion = '5.1'
} 'Invalid AZ3166 build lock: hostPrerequisites.powershell.minimumVersion must be 7.0 or later.'
Write-Host 'PASS unsupported PowerShell minimum is rejected'

Assert-BuildLockRejected {
    param($fixture)
    $fixture.hostPrerequisites.windows.maximumToolchainRootLength = 0
} 'Invalid AZ3166 build lock: hostPrerequisites.windows.maximumToolchainRootLength must be a positive integer.'
Write-Host 'PASS invalid Windows toolchain-root limit is rejected'

foreach ($unsafeRootName in @(
    '.', '..', '../outside', '..\outside', 'a/b', 'a\b', '/tools', '\tools',
    'C:\tools', 'C:tools', '\\server\share', 'a.', 'a ', 'a:b', 'a*b', 'a?b',
    'NUL', 'con.txt', 'COM1', 'LPT9.exe', "a'b", "a`nextra=value", "a`rextra=value"
)) {
    Assert-BuildLockRejected {
        param($fixture)
        $fixture.hostPrerequisites.windows.shortToolchainRootName = $unsafeRootName
    } 'Invalid AZ3166 build lock: hostPrerequisites.windows.shortToolchainRootName must be a single relative directory name.'
}
Write-Host 'PASS unsafe Windows toolchain-root name is rejected'

foreach ($unsafeAssetName in @(
    '.', '..', '../outside', '..\outside', 'C:\outside', 'CON', 'NUL.txt', 'asset.', 'asset ',
    'con', 'Con.txt', 'cOm1', 'lpT9.bin', "COM$([char]0x00b9)", "lpt$([char]0x00b2).txt"
)) {
    Assert-BuildLockRejected {
        param($fixture)
        $fixture.arduino.cli.windowsX64.archiveFileName = $unsafeAssetName
    } 'Invalid AZ3166 build lock: arduino.cli.windowsX64.archiveFileName must be a safe Windows basename.'
    Assert-BuildLockRejected {
        param($fixture)
        $fixture.boardManager.indexPath = $unsafeAssetName
    } 'Invalid AZ3166 build lock: boardManager.indexPath must be a safe Windows basename.'
}
Write-Host 'PASS unsafe archive and index basenames are rejected'

foreach ($propertyPath in @(
    'arduino.cli.version', 'arduino.ide.version', 'arduino.unit.version', 'core.version',
    'tools.armNoneEabiGcc.packageName', 'tools.armNoneEabiGcc.version',
    'tools.armNoneEabiGcc.compilerVersion', 'tools.openocd.packageName', 'tools.openocd.version'
)) {
    foreach ($unsafeComponent in @('..', '../outside', '..\outside', 'C:\outside', 'CON', '2.2.', '2.2 ')) {
        Assert-BuildLockRejected {
            param($fixture)
            $propertyNames = $propertyPath.Split('.')
            $parent = $fixture
            foreach ($propertyName in $propertyNames[0..($propertyNames.Length - 2)]) {
                $parent = $parent.$propertyName
            }
            $parent.($propertyNames[-1]) = $unsafeComponent
            if ($propertyPath -match '^tools\.(armNoneEabiGcc|openocd)\.(packageName|version)$') {
                $dependencyIndex = if ($Matches[1] -eq 'armNoneEabiGcc') { 0 } else { 1 }
                $dependencyProperty = if ($Matches[2] -eq 'packageName') { 'name' } else { 'version' }
                $fixture.core.toolDependencies[$dependencyIndex].$dependencyProperty = $unsafeComponent
            }
        } "Invalid AZ3166 build lock: $propertyPath must be a safe Windows basename."
    }
}
Write-Host 'PASS unsafe tool identity path components are rejected'

foreach ($assetPath in @(
    'arduino.ide.windows', 'arduino.unit.archive', 'core.canonicalPackage',
    'tools.armNoneEabiGcc.windows', 'tools.openocd.windows', 'boardManager'
)) {
    foreach ($uppercaseName in @($false, $true)) {
        Assert-BuildLockRejected {
            param($fixture)
            $duplicateName = $fixture.arduino.cli.windowsX64.archiveFileName
            if ($uppercaseName) { $duplicateName = $duplicateName.ToUpperInvariant() }
            $asset = $fixture
            foreach ($propertyName in $assetPath.Split('.')) { $asset = $asset.$propertyName }
            if ($assetPath -eq 'boardManager') {
                $asset.indexPath = $duplicateName
                $asset.indexUrl = "https://raw.githubusercontent.com/$($asset.repository)/$($asset.revision)/$duplicateName"
            }
            else {
                $asset.archiveFileName = $duplicateName
                $asset.url = [Uri]::new([Uri]$asset.url, $duplicateName).AbsoluteUri
            }
        } 'Invalid AZ3166 build lock: cache asset basenames must be unique (case-insensitive).'
    }
}
Write-Host 'PASS colliding cache asset basenames are rejected'

$workflowPath = Join-Path $repositoryRoot '.github/workflows/core-package-ci.yml'
$workflow = Get-Content -Raw -LiteralPath $workflowPath
Assert-BuildConfigurationTest ($workflow.Contains('Export-Az3166BuildLockGitHubOutput')) 'Core package CI does not export the shared build lock.'
Assert-BuildConfigurationTest ($workflow.Contains('./tests/host/build/BuildConfigurationTest.ps1')) 'Core package CI does not run the build-configuration tests.'
Assert-BuildConfigurationTest ($workflow.Contains('./tests/host/build/ToolchainInstallerTest.ps1')) 'Core package CI does not run the toolchain-installer tests.'
Assert-BuildConfigurationTest `
    ([regex]::Matches($workflow, [regex]::Escape('./tests/host/build/ToolchainInstallerTest.ps1')).Count -eq 1) `
    'Core package CI must not repeat the toolchain-installer tests with a full boundary installation.'
Assert-BuildConfigurationTest (-not $workflow.Contains('./tools/test/Test-Az3166CompilerParameters.ps1')) 'Core package CI must not repeat all target builds for compiler equivalence.'
Assert-BuildConfigurationTest ($workflow.Contains('./tools/build/Install-Az3166BuildTools.ps1')) 'Core package CI does not invoke the shared toolchain installer.'
Assert-BuildConfigurationTest ($workflow.Contains('-VerifyOnly')) 'Core package CI does not verify the installed toolchain.'
Assert-BuildConfigurationTest ($workflow.Contains('-Offline')) 'Core package CI does not exercise an offline second setup.'
Assert-BuildConfigurationTest (-not $workflow.Contains('Invoke-WebRequest')) 'Core package CI still owns a toolchain download.'
Assert-BuildConfigurationTest (-not $workflow.Contains('arduino/setup-arduino-cli')) 'Core package CI still uses a separate Arduino CLI installer.'
Assert-BuildConfigurationTest ($workflow.Contains("foreach (`$profile in @('base', 'azure-iot'))") -and
    $workflow.Contains('-Profile $profile') -and $workflow.Contains('AzureArchiveTest.ps1') -and
    $workflow.Contains('workflow_call:') -and $workflow.Contains('inputs.revision || github.sha')) 'CI must validate both profiles and support exact-revision release gates.'
Assert-BuildConfigurationTest ($workflow.Contains('steps.build-lock.outputs.short_toolchain_root_name')) 'Core package CI does not use the locked short toolchain-root name.'
$toolchainCacheStep = [regex]::Match($workflow, '(?ms)^      - name: Cache AZ3166 [^\r\n]+\r?\n.*?(?=^      - name:)').Value
Assert-BuildConfigurationTest ($toolchainCacheStep.Contains('path: ${{ runner.temp }}/az3166-downloads')) 'The toolchain cache must contain portable downloads only.'
Assert-BuildConfigurationTest (-not $toolchainCacheStep.Contains('short_toolchain_root_name')) 'CI must not restore an installation owned by another absolute root.'
$toolchainCacheKey = [regex]::Match($workflow, '(?m)^\s+key: az3166-build-downloads-.*$').Value
foreach ($cacheInput in @(
    'tools/build/az3166-build-lock.json',
    'tools/build/Install-Az3166BuildTools.ps1',
    'tools/build/Az3166Build.Common.ps1',
    'tools/package/Az3166PackageLayout.ps1'
)) {
    Assert-BuildConfigurationTest ($toolchainCacheKey.Contains("'$cacheInput'")) "The toolchain cache key does not hash its installer input: $cacheInput"
}
$workflowLiterals = @(
    $lock.core.version
    $lock.core.canonicalPackage.sha256
    $lock.arduino.cli.version
    $lock.arduino.ide.version
    $lock.arduino.ide.windows.sha256
    $lock.boardManager.revision
    $lock.boardManager.indexPath
    $lock.boardManager.indexUrl
    $lock.tools.armNoneEabiGcc.version
    $lock.tools.armNoneEabiGcc.compilerVersion
)
foreach ($literal in $workflowLiterals) {
    Assert-BuildConfigurationTest (-not $workflow.Contains($literal)) "Core package CI duplicates a build-lock value: $literal"
}
$declaredRunners = @([regex]::Matches($workflow, '(?m)^\s+(?:runner|runs-on):\s+([A-Za-z0-9.-]+)\s*$') | ForEach-Object {
    $_.Groups[1].Value
})
$expectedRunners = @(
    $lock.hostPrerequisites.windows.runner
    $lock.hostPrerequisites.linux.runner
    $lock.hostPrerequisites.linux.runner
)
Assert-BuildConfigurationTest `
    (@(Compare-Object ($expectedRunners | Sort-Object) ($declaredRunners | Sort-Object)).Count -eq 0) `
    'GitHub Actions runner labels do not match the build lock.'

$sketchDriver = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tools/test/Test-Az3166Sketches.ps1')
Assert-BuildConfigurationTest ($sketchDriver.Contains('Get-Az3166BuildLock')) 'The sketch driver does not consume the shared build lock.'
Assert-BuildConfigurationTest ($sketchDriver.Contains('ArduinoUnitDirectory')) 'The sketch driver does not accept the installed ArduinoUnit path.'
Assert-BuildConfigurationTest (-not $sketchDriver.Contains('Invoke-WebRequest')) 'The sketch driver still downloads a test dependency.'
foreach ($literal in @(
    $lock.arduino.fqbn
    $lock.arduino.unit.version
    $lock.arduino.unit.archive.url
    $lock.arduino.unit.archive.sha256
)) {
    Assert-BuildConfigurationTest (-not $sketchDriver.Contains($literal)) "The sketch driver duplicates a build-lock value: $literal"
}
Write-Host 'PASS build consumers use the shared lock'

$configurationPipeline = [Management.Automation.Language.Parser]::ParseInput($sketchDriver, [ref]$null, [ref]$null).Find({
    param($node)
    $node -is [Management.Automation.Language.PipelineAst] -and
        $node.Extent.Text -match 'Set-Content -LiteralPath \$configurationPath'
}, $true)
Assert-BuildConfigurationTest ($null -ne $configurationPipeline) 'The sketch driver configuration writer was not found.'
$configurationPath = Join-Path ([IO.Path]::GetTempPath()) "az3166-cli-config-$([guid]::NewGuid().ToString('N')).json"
try {
    $unicodeProfile = "C:\Users\Jos$([char]0xe9)"
    $arduinoDataDirectory = "$unicodeProfile\Arduino15"
    $downloadsDirectory = "$unicodeProfile\Downloads"
    $sketchbook = "$unicodeProfile\Sketchbook"
    & ([scriptblock]::Create($configurationPipeline.Extent.Text))
    $configuration = Get-Content -Raw -LiteralPath $configurationPath -Encoding utf8 | ConvertFrom-Json
    Assert-BuildConfigurationTest ($configuration.directories.data -ceq $arduinoDataDirectory) 'CLI data path lost Unicode characters.'
    Assert-BuildConfigurationTest ($configuration.directories.downloads -ceq $downloadsDirectory) 'CLI download path lost Unicode characters.'
    Assert-BuildConfigurationTest ($configuration.directories.user -ceq $sketchbook) 'CLI sketchbook path lost Unicode characters.'
}
finally {
    Remove-Item -LiteralPath $configurationPath -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS sketch driver configuration preserves Unicode paths'

$githubOutputPath = Join-Path ([IO.Path]::GetTempPath()) "az3166-github-output-$([guid]::NewGuid().ToString('N'))"
try {
    Export-Az3166BuildLockGitHubOutput -Lock $lock -Path $githubOutputPath
    $githubOutput = [ordered]@{}
    foreach ($line in @(Get-Content -LiteralPath $githubOutputPath)) {
        $parts = $line.Split('=', 2)
        Assert-BuildConfigurationTest ($parts.Count -eq 2) "Malformed GitHub output line: $line"
        $githubOutput[$parts[0]] = $parts[1]
    }
    $expectedOutput = [ordered]@{
        lock_sha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        short_toolchain_root_name = $lock.hostPrerequisites.windows.shortToolchainRootName
        maximum_toolchain_root_length = [string]$lock.hostPrerequisites.windows.maximumToolchainRootLength
        core_version = $lock.core.version
        core_package_size = [string]$lock.core.canonicalPackage.size
        core_package_sha256 = $lock.core.canonicalPackage.sha256
        arduino_cli_version = $lock.arduino.cli.version
        arduino_ide_version = $lock.arduino.ide.version
        arduino_ide_url = $lock.arduino.ide.windows.url
        arduino_ide_size = [string]$lock.arduino.ide.windows.size
        arduino_ide_sha256 = $lock.arduino.ide.windows.sha256
        index_revision = $lock.boardManager.revision
        index_path = $lock.boardManager.indexPath
        index_url = $lock.boardManager.indexUrl
        index_sha256 = $lock.boardManager.sha256
        gcc_package_version = $lock.tools.armNoneEabiGcc.version
        gcc_compiler_version = $lock.tools.armNoneEabiGcc.compilerVersion
    }
    Assert-BuildConfigurationTest `
        (@(Compare-Object @($expectedOutput.Keys) @($githubOutput.Keys)).Count -eq 0) `
        'The GitHub output names do not match the workflow contract.'
    foreach ($name in $expectedOutput.Keys) {
        Assert-BuildConfigurationTest `
            ($githubOutput[$name] -ceq $expectedOutput[$name]) `
            "The exported $name value does not match the build lock."
    }
}
finally {
    Remove-Item -LiteralPath $githubOutputPath -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS GitHub output matches the build lock'

Write-Host '15 build-configuration tests passed.'