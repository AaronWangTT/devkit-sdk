[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Revision = "HEAD"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resolvedCommit = git -C $repositoryRoot rev-parse "$Revision^{commit}"
if ($LASTEXITCODE -ne 0 -or -not $resolvedCommit) {
    throw "Could not resolve Git revision: $Revision"
}

$sourceDirectory = (& git -C $repositoryRoot ls-tree -d --name-only $resolvedCommit -- src | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not locate platform source at Git revision: $Revision"
}
if ($sourceDirectory -ne "src") {
    $sourceDirectory = "AZ3166/src"
}

$libraryDirectory = (& git -C $repositoryRoot ls-tree -d --name-only $resolvedCommit -- libraries | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not locate platform libraries at Git revision: $Revision"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue

$tree = "${resolvedCommit}:$sourceDirectory"
$previousTimezone = $env:TZ
$previousIndex = $env:GIT_INDEX_FILE
$temporaryIndex = Join-Path ([System.IO.Path]::GetTempPath()) "az3166-package-$([guid]::NewGuid().ToString('N')).index"
$archiveExitCode = $null
try {
    if ($libraryDirectory -eq "libraries") {
        $env:GIT_INDEX_FILE = $temporaryIndex
        git -C $repositoryRoot read-tree $tree
        if ($LASTEXITCODE -ne 0) {
            throw "Could not stage platform source at Git revision: $Revision"
        }
        git -C $repositoryRoot read-tree --prefix=libraries/ "${resolvedCommit}:libraries"
        if ($LASTEXITCODE -ne 0) {
            throw "Could not stage platform libraries at Git revision: $Revision"
        }
        $tree = git -C $repositoryRoot write-tree
        if ($LASTEXITCODE -ne 0) {
            throw "Could not assemble platform tree at Git revision: $Revision"
        }
    }

    # Keep payload line endings and ZIP timestamps independent of the host.
    $env:TZ = "UTC"
    git -C $repositoryRoot `
        -c core.autocrlf=false `
        archive `
        --format=zip `
        --prefix=AZ3166/ `
        --mtime=2000-01-01T00:00:00Z `
        --output=$outputFullPath `
        $tree
    $archiveExitCode = $LASTEXITCODE
} finally {
    $env:TZ = $previousTimezone
    $env:GIT_INDEX_FILE = $previousIndex
    Remove-Item -LiteralPath $temporaryIndex -Force -ErrorAction SilentlyContinue
}
if ($archiveExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
    throw "Failed to create AZ3166 board package: $outputFullPath"
}

$hash = Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256
[pscustomobject]@{
    Path = $outputFullPath
    Revision = $resolvedCommit
    Size = (Get-Item -LiteralPath $outputFullPath).Length
    SHA256 = $hash.Hash.ToLowerInvariant()
}