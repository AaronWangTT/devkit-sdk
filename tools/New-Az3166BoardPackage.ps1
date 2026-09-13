[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Revision = "HEAD"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolvedCommit = git -C $repositoryRoot rev-parse "$Revision^{commit}"
if ($LASTEXITCODE -ne 0 -or -not $resolvedCommit) {
    throw "Could not resolve Git revision: $Revision"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue

$tree = "${resolvedCommit}:AZ3166/src"
git -C $repositoryRoot archive `
    --format=zip `
    --prefix=AZ3166/ `
    --mtime=2000-01-01T00:00:00Z `
    --output=$outputFullPath `
    $tree
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
    throw "Failed to create AZ3166 board package: $outputFullPath"
}

$hash = Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256
[pscustomobject]@{
    Path = $outputFullPath
    Revision = $resolvedCommit
    Size = (Get-Item -LiteralPath $outputFullPath).Length
    SHA256 = $hash.Hash.ToLowerInvariant()
}