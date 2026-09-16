[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Revision = "HEAD",
    [string]$Profile,
    [string]$Ar = 'ar',
    [string]$Nm = 'nm'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'Az3166PackageLayout.ps1')
$resolvedCommit = git -C $repositoryRoot rev-parse "$Revision^{commit}"
if ($LASTEXITCODE -ne 0 -or -not $resolvedCommit) {
    throw "Could not resolve Git revision: $Revision"
}

$layout = Get-Az3166PackageLayout -RepositoryRoot $repositoryRoot -Revision $resolvedCommit -Profile $Profile
$tree = New-Az3166PlatformTree -RepositoryRoot $repositoryRoot -Layout $layout -Ar $Ar -Nm $Nm

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue

$previousTimezone = $env:TZ
$archiveExitCode = $null
try {
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
}
if ($archiveExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
    throw "Failed to create AZ3166 board package: $outputFullPath"
}

$hash = Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256
[pscustomobject]@{
    Path = $outputFullPath
    Revision = $resolvedCommit
    Profile = $layout.Profile
    Size = (Get-Item -LiteralPath $outputFullPath).Length
    SHA256 = $hash.Hash.ToLowerInvariant()
}