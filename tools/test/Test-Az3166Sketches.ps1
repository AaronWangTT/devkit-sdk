#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ArduinoCli = "arduino-cli",

    [string]$ArduinoDataDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ArduinoUnitDirectory,

    [switch]$VerboseBuild,

    [string[]]$Sketch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
$buildLock = Get-Az3166BuildLock
$fqbn = $buildLock.arduino.fqbn
$sketchRoots = @(
    (Join-Path $repositoryRoot "examples")
    (Join-Path $repositoryRoot "tests/hardware")
)
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "az3166-tests-$([guid]::NewGuid().ToString('N'))"

if (-not $ArduinoDataDirectory) {
    if ($env:LOCALAPPDATA) {
        $ArduinoDataDirectory = Join-Path $env:LOCALAPPDATA "Arduino15"
    }
    else {
        $ArduinoDataDirectory = Join-Path $HOME ".arduino15"
    }
}

$arduinoCliCommand = @(Get-Command $ArduinoCli -CommandType Application -ErrorAction Stop)[0]
$arduinoDataDirectory = [System.IO.Path]::GetFullPath($ArduinoDataDirectory)
if (-not (Test-Path -LiteralPath $arduinoDataDirectory -PathType Container)) {
    throw "Arduino data directory does not exist: $arduinoDataDirectory"
}
$arduinoUnitDirectory = (Resolve-Path -LiteralPath $ArduinoUnitDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath (Join-Path $arduinoUnitDirectory 'library.properties') -PathType Leaf)) {
    throw "ArduinoUnit library is invalid: $arduinoUnitDirectory"
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
    $sketchDirectories = @(Get-ChildItem -LiteralPath $sketchRoots -Recurse -File |
        Where-Object {
            $_.Extension -in ".ino", ".pde" -and
            $_.BaseName -eq $_.Directory.Name
        } |
        ForEach-Object { $_.Directory.FullName } |
        Sort-Object -Unique)
}

if ($sketchDirectories.Count -eq 0) {
    throw "No Arduino test sketches were found under $($sketchRoots -join ', ')."
}

$sketchbook = Join-Path $temporaryRoot "sketchbook"
$librariesDirectory = Join-Path $sketchbook "libraries"
$platformDirectory = Join-Path $sketchbook "hardware\AZ3166Checkout\stm32f4"
$downloadsDirectory = Join-Path $temporaryRoot "downloads"
$configurationPath = Join-Path $temporaryRoot "arduino-cli.yaml"

try {
    New-Item -ItemType Directory -Path $librariesDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $downloadsDirectory -Force | Out-Null
    Copy-Az3166Platform -RepositoryRoot $repositoryRoot -Destination $platformDirectory
    Copy-Item `
        -LiteralPath $arduinoUnitDirectory `
        -Destination (Join-Path $librariesDirectory 'ArduinoUnit') `
        -Recurse

    @{
        directories = @{
            data = $arduinoDataDirectory
            downloads = $downloadsDirectory
            user = $sketchbook
        }
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configurationPath -Encoding ascii

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($sketchDirectory in $sketchDirectories) {
        $relativePath = [System.IO.Path]::GetRelativePath($repositoryRoot, $sketchDirectory)
        $buildName = $relativePath -replace '[^A-Za-z0-9_.-]', '-'
        $buildPath = Join-Path $temporaryRoot "build-$buildName"

        Write-Host "Compiling $relativePath"
        $arguments = @(
            '--config-file', $configurationPath,
            'compile',
            '--fqbn', $fqbn,
            '--build-path', $buildPath,
            '--warnings', 'all'
        )
        if ($VerboseBuild) {
            $arguments += '--verbose'
        }
        $arguments += $sketchDirectory
        $output = (& $arduinoCliCommand.Source @arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host $output
            $failures.Add($relativePath)
            continue
        }

        if ($VerboseBuild) {
            Write-Host $output
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