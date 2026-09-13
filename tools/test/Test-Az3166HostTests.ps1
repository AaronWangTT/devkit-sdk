#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Compiler = 'g++',
    [string]$ExpectedVersion,
    [switch]$Sanitize,
    [switch]$CompileOnly,
    [string[]]$LinkerFlags = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
$compilerCommand = @(Get-Command $Compiler -CommandType Application -ErrorAction Stop)[0]
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166-host-$([guid]::NewGuid().ToString('N'))"
$platform = Join-Path $temporaryRoot 'platform'
$previousAsan = $env:ASAN_OPTIONS
$previousUbsan = $env:UBSAN_OPTIONS

try {
    Copy-Az3166Platform -RepositoryRoot $repositoryRoot -Destination $platform
    $versionHeader = Join-Path $platform 'cores/arduino/system/SystemVersion.h'
    $version = Get-Az3166CoreVersion -HeaderContent (Get-Content -Raw -LiteralPath $versionHeader) -Source $versionHeader
    if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
        throw "Core version $version does not match expected version $ExpectedVersion."
    }
    $tests = @(
        @{
            Name = 'system-version-test'
            Arguments = @(
                '-std=c++11', '-include', 'cstdint'
                '-I', "$platform/cores/arduino/system"
                "$platform/cores/arduino/system/SystemVersion.cpp"
                "$repositoryRoot/tests/host/core/SystemVersionTest.cpp"
            )
            RunArguments = @($version)
            Sanitize = $false
        }
        @{
            Name = 'wifiudp-test'
            Arguments = @(
                '-std=c++11', '-O1', '-g', '-Wall', '-Wextra', '-Werror'
                '-I', "$platform/system/mbed-os/features/netsocket"
                '-I', "$platform/cores/arduino/system"
                '-I', "$platform/libraries/WiFi/src"
                "$repositoryRoot/tests/host/wifi/WiFiUdpTest.cpp"
            )
            RunArguments = @()
            Sanitize = $true
        }
        @{
            Name = 'iot-client-test'
            Arguments = @(
                '-std=gnu++11', '-O1', '-g', '-Wall', '-Wextra', '-Werror'
                '-ffunction-sections', '-fdata-sections'
                '-I', "$platform/cores/arduino"
                '-I', "$platform/cores/arduino/httpclient"
                '-I', "$platform/system/azure-iot-sdk-c/deps/parson"
                '-I', "$platform/system/azure-iot-sdk-c/c-utility/inc"
                "$repositoryRoot/tests/host/cloud/IotClientTest.cpp"
                '-Wl,--gc-sections'
            )
            RunArguments = @()
            Sanitize = $true
        }
    )
    if ($Sanitize) {
        $env:ASAN_OPTIONS = 'detect_leaks=1:halt_on_error=1'
        $env:UBSAN_OPTIONS = 'halt_on_error=1:print_stacktrace=1'
    }
    foreach ($test in $tests) {
        $executable = Join-Path $temporaryRoot ($test.Name + $(if ($IsWindows) { '.exe' } else { '' }))
        $arguments = @($test.Arguments) + @($LinkerFlags)
        if ($Sanitize -and $test.Sanitize) {
            $arguments += @('-fsanitize=address,undefined', '-fno-omit-frame-pointer')
        }
        Write-Host "Compiling $($test.Name)"
        & $compilerCommand.Source @arguments -o $executable
        if ($LASTEXITCODE -ne 0) {
            throw "Host program failed to compile: $($test.Name)"
        }
        if (-not $CompileOnly) {
            $runArguments = $test.RunArguments
            & $executable @runArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Host program failed: $($test.Name)"
            }
        }
    }
    if ($CompileOnly) {
        Write-Host '3 host programs compiled and linked; no tests executed.'
    }
    else {
        Write-Host '3 host programs compiled and executed successfully.'
    }
}
finally {
    $env:ASAN_OPTIONS = $previousAsan
    $env:UBSAN_OPTIONS = $previousUbsan
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}