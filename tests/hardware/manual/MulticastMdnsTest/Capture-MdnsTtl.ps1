#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BoardAddress,
    [Parameter(Mandatory = $true)]
    [string]$LocalAddress,
    [Parameter(Mandatory = $true)]
    [string]$EtlPath,
    [Parameter(Mandatory = $true)]
    [string]$PcapPath,
    [Parameter(Mandatory = $true)]
    [string]$ProbeScript,
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [Parameter(Mandatory = $true)]
    [string]$PythonExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $LogPath -Value ''

function Invoke-PktMon {
    param([string[]]$Arguments)

    & pktmon @Arguments 2>&1 | Out-File -LiteralPath $LogPath -Append
    if ($LASTEXITCODE -ne 0) {
        throw "pktmon $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

foreach ($path in @($EtlPath, $PcapPath)) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

try {
    Invoke-PktMon @('filter', 'remove')
    Invoke-PktMon @(
        'filter', 'add', 'mDNS',
        '-i', $BoardAddress, '-t', 'UDP', '-p', '5353'
    )
    Invoke-PktMon @(
        'start', '--capture', '--pkt-size', '0', '--file-name', $EtlPath
    )
    Start-Sleep -Seconds 1
    & $PythonExecutable $ProbeScript `
        --local $LocalAddress --board $BoardAddress --send-only
    if ($LASTEXITCODE -ne 0) {
        throw "mDNS probe failed with exit code $LASTEXITCODE."
    }
}
finally {
    & pktmon stop 2>&1 | Out-File -LiteralPath $LogPath -Append
}

Invoke-PktMon @('etl2pcap', $EtlPath, '--out', $PcapPath)
if (-not (Test-Path -LiteralPath $PcapPath -PathType Leaf)) {
    throw "PktMon did not produce $PcapPath."
}
