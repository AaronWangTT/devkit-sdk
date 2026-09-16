#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [string]$Profile,
    [string]$Revision,
    [string]$Ar = 'ar',
    [string]$Nm = 'nm'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'Az3166PackageLayout.ps1')
Copy-Az3166Platform -RepositoryRoot $repositoryRoot -Destination $Destination -Profile $Profile -Revision $Revision -Ar $Ar -Nm $Nm
Write-Host "Staged Arduino platform: $([IO.Path]::GetFullPath($Destination))"