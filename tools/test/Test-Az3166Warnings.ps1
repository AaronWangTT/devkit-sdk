#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$RequireCompleteInventory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Az3166Warnings.ps1')
. (Join-Path $PSScriptRoot '../build/Az3166Build.Common.ps1')
$lock = Get-Az3166BuildLock -Path (Join-Path $OutputDirectory 'az3166-build-lock.json')
$layout = Get-Content -Raw -LiteralPath (Join-Path $OutputDirectory 'package-layout.json') | ConvertFrom-Json
$profile = $null
if ($layout.schemaVersion -ge 2) {
    $profile = (Get-Content -Raw -LiteralPath (Join-Path $OutputDirectory 'package-profile.json') | ConvertFrom-Json).profile
    if ($profile -cnotin @('base', 'azure-iot')) { throw 'Retained evidence has no valid package profile.' }
}
$policy = Get-Az3166WarningPolicy -Path (Join-Path $OutputDirectory 'az3166-warning-policy.json') -BuildLock $lock -Profile $profile
$result = Export-Az3166WarningEvidence -OutputDirectory $OutputDirectory -Policy $policy -Layout $layout -RequireCompleteInventory:$RequireCompleteInventory
if (-not $result.passed) { throw "Warning policy failed; inspect $OutputDirectory/warning-summary.json" }