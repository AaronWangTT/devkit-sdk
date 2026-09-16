#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tools/package/Az3166Release.ps1')

function Assert-ReleaseTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$request = @{
    Version = '3.0.0'
    Profile = 'base'
    CoreVersion = '3.0.0'
    LegacyVersion = '2.0.2'
    LayoutManifest = [pscustomobject]@{ schemaVersion = 2; releaseProfile = 'base' }
}
Assert-Az3166ReleaseRequest @request
$request.Profile = 'azure-iot'
$request.LayoutManifest.releaseProfile = 'azure-iot'
Assert-Az3166ReleaseRequest @request
Write-Host 'PASS explicit base and full major-release requests'

foreach ($mutation in @(
    { param($value) $value.Version = '03.0.0' }
    { param($value) $value.Version = '3.0.0-preview' }
    { param($value) $value.CoreVersion = '3.0.1' }
    { param($value) $value.Version = '2.1.0'; $value.CoreVersion = '2.1.0' }
    { param($value) $value.Profile = 'unknown' }
    { param($value) $value.LayoutManifest.releaseProfile = 'base' }
    { param($value) $value.LayoutManifest.schemaVersion = 1 }
    { param($value) $value.LayoutManifest.PSObject.Properties.Remove('releaseProfile') }
)) {
    $fixture = @{}
    foreach ($key in $request.Keys) { $fixture[$key] = $request[$key] }
    $fixture.LayoutManifest = $request.LayoutManifest | ConvertTo-Json | ConvertFrom-Json
    & $mutation $fixture
    $rejected = $false
    try { Assert-Az3166ReleaseRequest @fixture } catch { $rejected = $true }
    Assert-ReleaseTest $rejected 'Invalid release request was accepted.'
}
Write-Host 'PASS profile mismatch, unapproved version line, missing tag metadata, and invalid versions rejected'

$root = Join-Path ([IO.Path]::GetTempPath()) "az3166-release-$([guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $root
    $packagePath = Join-Path $root 'AZ3166-3.0.0-base.zip'
    [IO.File]::WriteAllBytes($packagePath, [byte[]]@(1, 2, 3, 4))
    $hash = (Get-FileHash -LiteralPath $packagePath).Hash.ToLowerInvariant()
    $arguments = @{ Version = '3.0.0'; Profile = 'base'; Revision = 'a' * 40; Repository = 'AaronWangTT/devkit-sdk'; PackagePath = $packagePath; ExpectedSHA256 = $hash }
    $metadata = New-Az3166ReleaseMetadata @arguments
    Assert-ReleaseTest ($metadata.boardManagerUpdate.url -ceq 'https://github.com/AaronWangTT/devkit-sdk/releases/download/3.0.0/AZ3166-3.0.0-base.zip') 'Incorrect immutable index URL.'
    Assert-ReleaseTest ($metadata.boardManagerUpdate.checksum -ceq "SHA-256:$hash" -and $metadata.boardManagerUpdate.size -ceq '4') 'Incorrect index hash or size.'
    foreach ($mutation in @(
        { param($value) $value.ExpectedSHA256 = '0' * 64 }
        { param($value) $value.Profile = 'azure-iot' }
        { param($value) $value.Repository = '../other' }
        { param($value) $value.Revision = 'HEAD' }
    )) {
        $fixture = $arguments.Clone()
        & $mutation $fixture
        $rejected = $false
        try { $null = New-Az3166ReleaseMetadata @fixture } catch { $rejected = $true }
        Assert-ReleaseTest $rejected 'Invalid artifact metadata was accepted.'
    }
    Write-Host 'PASS reviewed index fields and changed-artifact rejection'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
$workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-release.yml')
foreach ($required in @('needs: [prepare, validate]', 'uses: ./.github/workflows/core-package-ci.yml',
    'revision: ${{ needs.prepare.outputs.revision }}', 'Assert-Az3166ReleaseRequest', 'New-Az3166ReleaseMetadata',
    'hardware_validated:', 'Release tag moved after validation', 'Release archive differs from the artifact validated by CI.')) {
    Assert-ReleaseTest ($workflow.Contains($required)) "Missing release gate: $required"
}
Assert-ReleaseTest (-not $workflow.Contains('--clobber') -and $workflow.Contains('gh release create')) 'Release workflow may overwrite published artifacts.'
Write-Host 'PASS publication requires exact-revision validation, hardware confirmation, profile match, and immutable artifact identity'
Write-Host '4 release-profile contract groups passed.'