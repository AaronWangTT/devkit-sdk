#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host 'SKIP AZ3166 toolchain installer tests require Windows.'
    return
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installerPath = Join-Path $repositoryRoot 'tools/build/Install-Az3166BuildTools.ps1'
$lockPath = Join-Path $repositoryRoot 'tools/build/az3166-build-lock.json'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166-installer-test-$([guid]::NewGuid().ToString('N'))"

function Assert-InstallerTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-InstallerRejected {
    param(
        [hashtable]$Arguments,
        [string[]]$ExpectedMessages
    )

    $rejected = $false
    try {
        $null = & $installerPath @Arguments
    }
    catch {
        foreach ($expectedMessage in $ExpectedMessages) {
            if ($_.Exception.Message -notlike $expectedMessage) {
                throw
            }
        }
        $rejected = $true
    }
    Assert-InstallerTest $rejected "Installer unexpectedly accepted arguments: $($Arguments.Keys -join ', ')"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $root = Join-Path $fixtureRoot 'root'
    $cache = Join-Path $fixtureRoot 'cache'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Clean = $true; VerifyOnly = $true } `
        -ExpectedMessages @('*-Clean and -VerifyOnly cannot be used together.*')
    Write-Host 'PASS incompatible modes are rejected'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = (Join-Path $root 'downloads') } `
        -ExpectedMessages @('*-Root and -DownloadCache must be separate directories.*')
    Write-Host 'PASS overlapping managed and cache roots are rejected'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*AZ3166 build tools are not installed at*')
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'VerifyOnly created the missing installation root.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $cache)) 'VerifyOnly created the download cache.'
    Write-Host 'PASS missing VerifyOnly is read-only'

    New-Item -ItemType Directory -Path $root | Out-Null
    $foreignFile = Join-Path $root 'keep.txt'
    Set-Content -LiteralPath $foreignFile -Value 'foreign' -Encoding ascii
    foreach ($arguments in @(
        @{ Root = $root; DownloadCache = $cache },
        @{ Root = $root; DownloadCache = $cache; Clean = $true }
    )) {
        Assert-InstallerRejected `
            -Arguments $arguments `
            -ExpectedMessages @('*not owned by this installer*')
    }
    Assert-InstallerTest ((Get-Content -Raw -LiteralPath $foreignFile).Trim() -ceq 'foreign') 'Foreign content was modified.'
    Write-Host 'PASS foreign roots are preserved'

    Remove-Item -LiteralPath $root -Recurse -Force
    New-Item -ItemType Directory -Path $root | Out-Null
    @{
        schemaVersion = 1
        installer = 'devkit-sdk.az3166-build-tools'
        root = $null
        lockSha256 = 'unused'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.az3166-build-tools.json') -Encoding utf8
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*not owned by this installer*')
    Write-Host 'PASS malformed manifests are treated as foreign'

    Remove-Item -LiteralPath $root -Recurse -Force
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $expectedCacheFiles = @(
        $lock.arduino.cli.windowsX64.archiveFileName,
        $lock.arduino.ide.windows.archiveFileName,
        $lock.arduino.unit.archive.archiveFileName,
        $lock.boardManager.indexPath,
        $lock.core.canonicalPackage.archiveFileName,
        $lock.tools.armNoneEabiGcc.windows.archiveFileName,
        $lock.tools.openocd.windows.archiveFileName
    )
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Offline = $true } `
        -ExpectedMessages @($expectedCacheFiles | ForEach-Object { "*${_}: missing*" })
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'Offline cache validation created the installation root.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $cache)) 'Offline cache validation created the missing cache.'
    Write-Host 'PASS offline mode reports every missing asset without writes'

    New-Item -ItemType Directory -Path $root | Out-Null
    [ordered]@{
        schemaVersion = 1
        installer = 'devkit-sdk.az3166-build-tools'
        root = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
        lockSha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.az3166-build-tools.json') -Encoding utf8
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @(
            '*AZ3166 build tools are invalid:*',
            '*missing file:*arduino-cli.exe*',
            '*expected exactly one openocd.exe*'
        )
    Write-Host 'PASS partial managed installations are diagnosed'

    New-Item -ItemType Directory -Path $cache | Out-Null
    Set-Content -LiteralPath (Join-Path $cache $lock.arduino.cli.windowsX64.archiveFileName) -Value 'corrupt' -Encoding ascii
    Remove-Item -LiteralPath $root -Recurse -Force
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Offline = $true } `
        -ExpectedMessages @("*$($lock.arduino.cli.windowsX64.archiveFileName): size is*")
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'Corrupt offline cache input was extracted.'
    Write-Host 'PASS corrupt cached assets fail before extraction'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '8 toolchain-installer tests passed.'