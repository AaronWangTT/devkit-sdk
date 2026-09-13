[CmdletBinding()]
param(
    [string]$Revision = "HEAD",

    [string]$ExpectedVersion,

    [string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) "az3166-core-package")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'Az3166PackageLayout.ps1')
$packageBuilder = Join-Path $PSScriptRoot "New-Az3166BoardPackage.ps1"

function Invoke-GitText {
    param([string[]]$GitArguments)

    $output = (& git -C $repositoryRoot @GitArguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArguments -join ' ') failed: $output"
    }
    return $output
}

$resolvedCommit = Invoke-GitText -GitArguments @("rev-parse", "$Revision^{commit}")
$layout = Get-Az3166PackageLayout -RepositoryRoot $repositoryRoot -Revision $resolvedCommit
$versionHeaderPath = ($layout.Files | Where-Object {
    $_.Destination -ceq 'cores/arduino/system/SystemVersion.h'
}).Source
$versionHeader = Invoke-GitText -GitArguments @(
    "show",
    "${resolvedCommit}:$versionHeaderPath"
)
$version = Get-Az3166CoreVersion `
    -HeaderContent $versionHeader `
    -Source "$versionHeaderPath at $resolvedCommit"

if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "Core version $version does not match expected version $ExpectedVersion."
}

$outputDirectoryFullPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputDirectoryFullPath -Force | Out-Null
$outputPath = Join-Path $outputDirectoryFullPath "AZ3166-$version.zip"
$comparisonPath = Join-Path $outputDirectoryFullPath "AZ3166-$version.reproducibility-check.zip"
$extractRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) "az3166-package-$([guid]::NewGuid().ToString('N'))"

try {
    $primary = & $packageBuilder -OutputPath $outputPath -Revision $resolvedCommit
    $comparison = & $packageBuilder -OutputPath $comparisonPath -Revision $resolvedCommit
    if (
        $primary.Size -ne $comparison.Size -or
        $primary.SHA256 -ne $comparison.SHA256
    ) {
        throw "Repeated package builds were not byte-for-byte reproducible."
    }

    Expand-Archive -LiteralPath $outputPath -DestinationPath $extractRoot
    $packagedHeaderPath = Join-Path $extractRoot "AZ3166\cores\arduino\system\SystemVersion.h"
    if (-not (Test-Path -LiteralPath $packagedHeaderPath -PathType Leaf)) {
        throw "Package does not contain $versionHeaderPath."
    }

    $packagedVersion = Get-Az3166CoreVersion `
        -HeaderContent (Get-Content -Raw -LiteralPath $packagedHeaderPath) `
        -Source $packagedHeaderPath
    if ($packagedVersion -ne $version) {
        throw "Packaged Core version $packagedVersion does not match source version $version."
    }

    [pscustomobject]@{
        Path = $primary.Path
        Revision = $resolvedCommit
        Version = $version
        Size = $primary.Size
        SHA256 = $primary.SHA256
    }
} finally {
    Remove-Item -LiteralPath $comparisonPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}