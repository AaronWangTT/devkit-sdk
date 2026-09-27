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
trap {
    $_ | Out-String | Out-File -LiteralPath $LogPath -Append
    exit 1
}

function Invoke-PktMon {
    param([string[]]$Arguments)

    & pktmon @Arguments 2>&1 | Out-File -LiteralPath $LogPath -Append
    if ($LASTEXITCODE -ne 0) {
        throw "pktmon $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Stop-PktMonIfRunning {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & pktmon stop 2>&1 | Out-File -LiteralPath $LogPath -Append
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

foreach ($path in @($EtlPath, $PcapPath)) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

$started = $false
try {
    Stop-PktMonIfRunning
    Invoke-PktMon @('filter', 'remove')
    Invoke-PktMon @(
        'filter', 'add', 'mDNS',
        '--ip-address', $BoardAddress,
        '--transport-protocol', 'UDP',
        '--port', '5353'
    )
    Invoke-PktMon @(
        'start', '--capture', '--pkt-size', '0', '--file-name', $EtlPath
    )
    $started = $true
    Start-Sleep -Seconds 1
    & $PythonExecutable $ProbeScript `
        --local $LocalAddress --board $BoardAddress --send-only
    if ($LASTEXITCODE -ne 0) {
        throw "mDNS probe failed with exit code $LASTEXITCODE."
    }
}
finally {
    if ($started) {
        Stop-PktMonIfRunning
    }
}

Invoke-PktMon @('etl2pcap', $EtlPath, '--out', $PcapPath)
if (-not (Test-Path -LiteralPath $PcapPath -PathType Leaf)) {
    throw "PktMon did not produce $PcapPath."
}
