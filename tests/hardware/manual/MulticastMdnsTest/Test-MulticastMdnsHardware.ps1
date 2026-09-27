#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [string]$ArduinoCli = 'arduino-cli',
    [string]$ArduinoDataDirectory,
    [ValidateSet('base', 'azure-iot')]
    [string]$Profile = 'base',
    [switch]$SkipTtlCapture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (
    Split-Path -Parent (
        Split-Path -Parent (
            Split-Path -Parent $PSScriptRoot
        )
    )
)
$sketch = $PSScriptRoot
$probe = Join-Path $PSScriptRoot 'mdns_probe.py'
$root = Join-Path ([IO.Path]::GetTempPath()) "az3166-mdns-$([guid]::NewGuid().ToString('N'))"
$stage = Join-Path $root 'sketchbook/hardware/AZ3166Checkout/stm32f4'
$build = Join-Path $root 'build'
$configuration = Join-Path $root 'arduino-cli.yaml'
$captureScript = Join-Path $PSScriptRoot 'Capture-MdnsTtl.ps1'

if (-not $ArduinoDataDirectory) {
    $ArduinoDataDirectory = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'Arduino15'
    }
    else {
        Join-Path $HOME '.arduino15'
    }
}

$arduino = @(Get-Command $ArduinoCli -CommandType Application -ErrorAction Stop)[0].Source
$python = @(Get-Command python -CommandType Application -ErrorAction Stop)[0].Source
if ((& $python --version 2>&1 | Out-String) -notmatch '^Python 3\.') {
    throw 'Python 3 is required for mDNS packet validation.'
}
. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')
$lock = Get-Az3166BuildLock
$toolRoot = Join-Path $ArduinoDataDirectory "packages/AZ3166/tools"
$ar = Join-Path $toolRoot "$($lock.tools.armNoneEabiGcc.packageName)/$($lock.tools.armNoneEabiGcc.version)/bin/arm-none-eabi-ar.exe"
$nm = Join-Path $toolRoot "$($lock.tools.armNoneEabiGcc.packageName)/$($lock.tools.armNoneEabiGcc.version)/bin/arm-none-eabi-nm.exe"

function Wait-ForSerialMarker {
    param([string]$Marker, [int]$Seconds)

    $serial = [IO.Ports.SerialPort]::new($Port, 115200, 'None', 8, 'One')
    $serial.ReadTimeout = 1000
    try {
        $serial.Open()
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $line = $serial.ReadLine().Trim()
                if ($line) {
                    Write-Host $line
                    if ($line -match 'HW_MDNS:.*FAILED') {
                        throw "Hardware reported failure: $line"
                    }
                    if ($line -match $Marker) {
                        return $Matches[1]
                    }
                }
            }
            catch [TimeoutException] {
            }
        }
        throw "Timed out waiting for serial marker: $Marker"
    }
    finally {
        if ($serial.IsOpen) {
            $serial.Close()
        }
        $serial.Dispose()
    }
}

function Get-CandidateLocalAddress {
    param([string]$BoardAddress)

    $boardBytes = [Net.IPAddress]::Parse($BoardAddress).GetAddressBytes()
    return @(
        Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                if ($_.AddressState -ne 'Preferred') {
                    return $false
                }
                $candidateBytes = [Net.IPAddress]::Parse(
                    $_.IPAddress
                ).GetAddressBytes()
                $remaining = [int]$_.PrefixLength
                for ($index = 0; $index -lt 4; $index++) {
                    $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
                    if ($bits -gt 0) {
                        $mask = (0xff -shl (8 - $bits)) -band 0xff
                        if (
                            ($candidateBytes[$index] -band $mask) -ne
                            ($boardBytes[$index] -band $mask)
                        ) {
                            return $false
                        }
                    }
                    $remaining -= $bits
                }
                return $true
            } |
            Select-Object -ExpandProperty IPAddress -Unique
    )
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    & (Join-Path $repositoryRoot 'tools/package/Stage-Az3166Platform.ps1') `
        -Destination $stage -Profile $Profile -Ar $ar -Nm $nm

    @{
        directories = @{
            data = [IO.Path]::GetFullPath($ArduinoDataDirectory)
            downloads = (Join-Path $root 'downloads')
            user = (Join-Path $root 'sketchbook')
        }
    } | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $configuration -Encoding utf8

    $fqbn = $lock.arduino.fqbn
    & $arduino --config-file $configuration --no-color compile `
        --fqbn $fqbn --build-path $build --warnings all $sketch
    if ($LASTEXITCODE -ne 0) {
        throw 'Hardware validation sketch compilation failed.'
    }
    $uploadOutput = (& $arduino --config-file $configuration --no-color upload `
        --fqbn $fqbn --port $Port --input-dir $build $sketch 2>&1 |
        Out-String)
    $uploadExitCode = $LASTEXITCODE
    Write-Host $uploadOutput
    if ($uploadExitCode -ne 0) {
        throw 'Hardware validation sketch upload failed.'
    }
    if ($uploadOutput -notmatch '\*\*\s+Verified OK\s+\*\*') {
        throw 'Upload completed without OpenOCD reporting Verified OK.'
    }

    $boardAddress = Wait-ForSerialMarker `
        -Marker '^HW_MDNS:REJOIN_READY IP=(\d+\.\d+\.\d+\.\d+)$' `
        -Seconds 90
    $localAddress = $null
    foreach ($candidate in Get-CandidateLocalAddress $boardAddress) {
        & $python $probe --local $candidate --board $boardAddress
        if ($LASTEXITCODE -eq 0) {
            $localAddress = $candidate
            break
        }
    }
    if (-not $localAddress) {
        throw "No local interface received mDNS responses from $boardAddress."
    }

    if (-not $SkipTtlCapture) {
        $etl = Join-Path $root 'mdns.etl'
        $pcap = Join-Path $root 'mdns.pcapng'
        $log = Join-Path $root 'pktmon.log'
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$captureScript`"",
            '-BoardAddress', $boardAddress,
            '-LocalAddress', $localAddress,
            '-EtlPath', "`"$etl`"",
            '-PcapPath', "`"$pcap`"",
            '-ProbeScript', "`"$probe`"",
            '-LogPath', "`"$log`"",
            '-PythonExecutable', "`"$python`""
        )
        $capture = Start-Process powershell.exe -Verb RunAs `
            -ArgumentList $arguments -Wait -PassThru
        if ($capture.ExitCode -ne 0) {
            Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
            throw "Elevated PktMon capture failed: $($capture.ExitCode)"
        }
        & $python $probe --board $boardAddress --pcap $pcap
        if ($LASTEXITCODE -ne 0) {
            throw 'Captured mDNS TTL validation failed.'
        }
    }

    Write-Host "AZ3166 multicast mDNS hardware validation passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
