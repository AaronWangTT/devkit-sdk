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
Assert-BuildConfigurationTest ($lock.hostPrerequisites.windows.pathConstraintStatus -like '*not yet validated*') 'The Windows path limit must remain explicitly unvalidated until the path experiment runs.'
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

$workflowPath = Join-Path $repositoryRoot '.github/workflows/core-package-ci.yml'
$workflow = Get-Content -Raw -LiteralPath $workflowPath
Assert-BuildConfigurationTest ($workflow.Contains('Export-Az3166BuildLockGitHubOutput')) 'Core package CI does not export the shared build lock.'
Assert-BuildConfigurationTest ($workflow.Contains('./tests/host/build/BuildConfigurationTest.ps1')) 'Core package CI does not run the build-configuration tests.'
$workflowLiterals = @(
    $lock.core.version
    $lock.core.canonicalPackage.sha256
    $lock.arduino.cli.version
    $lock.arduino.ide.version
    $lock.arduino.ide.windows.sha256
    $lock.boardManager.revision
    $lock.boardManager.indexUrl
    $lock.tools.armNoneEabiGcc.version
    $lock.tools.armNoneEabiGcc.compilerVersion
)
foreach ($literal in $workflowLiterals) {
    Assert-BuildConfigurationTest (-not $workflow.Contains($literal)) "Core package CI duplicates a build-lock value: $literal"
}

$sketchDriver = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tools/test/Test-Az3166Sketches.ps1')
Assert-BuildConfigurationTest ($sketchDriver.Contains('Get-Az3166BuildLock')) 'The sketch driver does not consume the shared build lock.'
foreach ($literal in @(
    $lock.arduino.fqbn
    $lock.arduino.unit.version
    $lock.arduino.unit.archive.url
    $lock.arduino.unit.archive.sha256
)) {
    Assert-BuildConfigurationTest (-not $sketchDriver.Contains($literal)) "The sketch driver duplicates a build-lock value: $literal"
}
Write-Host 'PASS build consumers use the shared lock'

$githubOutputPath = Join-Path ([IO.Path]::GetTempPath()) "az3166-github-output-$([guid]::NewGuid().ToString('N'))"
try {
    Export-Az3166BuildLockGitHubOutput -Lock $lock -Path $githubOutputPath
    $githubOutput = [ordered]@{}
    foreach ($line in @(Get-Content -LiteralPath $githubOutputPath)) {
        $parts = $line.Split('=', 2)
        Assert-BuildConfigurationTest ($parts.Count -eq 2) "Malformed GitHub output line: $line"
        $githubOutput[$parts[0]] = $parts[1]
    }
    $expectedOutputNames = @(
        'lock_sha256'
        'core_version'
        'core_package_size'
        'core_package_sha256'
        'arduino_cli_version'
        'arduino_ide_version'
        'arduino_ide_sha256'
        'index_revision'
        'index_url'
        'gcc_package_version'
        'gcc_compiler_version'
    )
    Assert-BuildConfigurationTest `
        (@(Compare-Object $expectedOutputNames @($githubOutput.Keys)).Count -eq 0) `
        'The GitHub output names do not match the workflow contract.'
    $expectedLockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-BuildConfigurationTest ($githubOutput.lock_sha256 -ceq $expectedLockHash) 'The exported lock hash does not match the lock file.'
    Assert-BuildConfigurationTest ($githubOutput.core_version -ceq $lock.core.version) 'The exported Core version does not match the lock.'
}
finally {
    Remove-Item -LiteralPath $githubOutputPath -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS GitHub output matches the build lock'

Write-Host '8 build-configuration tests passed.'