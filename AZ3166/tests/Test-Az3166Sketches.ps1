#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ArduinoCli = "arduino-cli",

    [string]$ArduinoDataDirectory,

    [string[]]$Sketch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$arduinoUnitVersion = "2.2.0"
$arduinoUnitUrl = "https://downloads.arduino.cc/libraries/github.com/mmurdoch/ArduinoUnit-$arduinoUnitVersion.zip"
$arduinoUnitSha256 = "dc2e4473aedad99d254b4169e6ec32c717004c6537f2008e87db72d8c76b08ff"
$fqbn = "AZ3166Checkout:stm32f4:MXCHIP_AZ3166"
$testRoot = $PSScriptRoot
$coreRoot = Split-Path -Parent $testRoot
$platformSource = Join-Path $coreRoot "src"
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "az3166-tests-$([guid]::NewGuid().ToString('N'))"

if (-not $ArduinoDataDirectory) {
    if ($env:LOCALAPPDATA) {
        $ArduinoDataDirectory = Join-Path $env:LOCALAPPDATA "Arduino15"
    }
    else {
        $ArduinoDataDirectory = Join-Path $HOME ".arduino15"
    }
}

$arduinoCliCommand = Get-Command $ArduinoCli -ErrorAction Stop
$arduinoDataDirectory = [System.IO.Path]::GetFullPath($ArduinoDataDirectory)
if (-not (Test-Path -LiteralPath $arduinoDataDirectory -PathType Container)) {
    throw "Arduino data directory does not exist: $arduinoDataDirectory"
}

if ($Sketch) {
    $sketchDirectories = @($Sketch | ForEach-Object {
        $resolved = Resolve-Path -LiteralPath $_ -ErrorAction Stop
        if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
            $resolved.Path
        }
        else {
            Split-Path -Parent $resolved.Path
        }
    } | Sort-Object -Unique)
}
else {
    $sketchDirectories = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File |
        Where-Object {
            $_.Extension -in ".ino", ".pde" -and
            $_.BaseName -eq $_.Directory.Name
        } |
        ForEach-Object { $_.Directory.FullName } |
        Sort-Object -Unique)
}

if ($sketchDirectories.Count -eq 0) {
    throw "No Arduino test sketches were found under $testRoot."
}

$sketchbook = Join-Path $temporaryRoot "sketchbook"
$librariesDirectory = Join-Path $sketchbook "libraries"
$platformDirectory = Join-Path $sketchbook "hardware\AZ3166Checkout\stm32f4"
$downloadsDirectory = Join-Path $temporaryRoot "downloads"
$archivePath = Join-Path $temporaryRoot "ArduinoUnit-$arduinoUnitVersion.zip"
$configurationPath = Join-Path $temporaryRoot "arduino-cli.yaml"

try {
    New-Item -ItemType Directory -Path $librariesDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $downloadsDirectory -Force | Out-Null
    Copy-Item -LiteralPath $platformSource -Destination $platformDirectory -Recurse

    Invoke-WebRequest -Uri $arduinoUnitUrl -OutFile $archivePath -UseBasicParsing
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $arduinoUnitSha256) {
        throw "ArduinoUnit archive hash mismatch: $archiveHash"
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $librariesDirectory
    $compareHeader = Get-ChildItem -LiteralPath $librariesDirectory -Filter "Compare.h" -File -Recurse |
        Select-Object -First 1
    if (-not $compareHeader) {
        throw "ArduinoUnit Compare.h was not found."
    }

    $compareContent = Get-Content -Raw -LiteralPath $compareHeader.FullName
    $avrInclude = "#include <avr/pgmspace.h>"
    if (-not $compareContent.Contains($avrInclude)) {
        throw "ArduinoUnit $arduinoUnitVersion no longer has the expected pgmspace include."
    }
    $compareContent.Replace($avrInclude, "#include <pgmspace.h>") |
        Set-Content -LiteralPath $compareHeader.FullName -Encoding ascii -NoNewline

    @{
        directories = @{
            data = $arduinoDataDirectory
            downloads = $downloadsDirectory
            user = $sketchbook
        }
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configurationPath -Encoding ascii

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($sketchDirectory in $sketchDirectories) {
        $relativePath = [System.IO.Path]::GetRelativePath($testRoot, $sketchDirectory)
        $buildName = $relativePath -replace '[^A-Za-z0-9_.-]', '-'
        $buildPath = Join-Path $temporaryRoot "build-$buildName"

        Write-Host "Compiling $relativePath"
        $output = (& $arduinoCliCommand.Source `
            --config-file $configurationPath `
            compile `
            --fqbn $fqbn `
            --build-path $buildPath `
            --warnings all `
            $sketchDirectory 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host $output
            $failures.Add($relativePath)
            continue
        }

        $output -split "`r?`n" |
            Where-Object { $_ -match "^(Sketch uses|Global variables use)" } |
            ForEach-Object { Write-Host "  $_" }
    }

    if ($failures.Count -gt 0) {
        throw "$($failures.Count) Arduino test sketch build(s) failed: $($failures -join ', ')"
    }

    Write-Host "$($sketchDirectories.Count) Arduino test sketch build(s) passed."
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}