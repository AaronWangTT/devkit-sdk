#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Compiler = 'g++',
    [string]$ExpectedVersion,
    [switch]$Sanitize,
    [switch]$CompileOnly,
    [string[]]$LinkerFlags = @(),
    [string]$Profile,
    [string]$Ar = 'ar',
    [string]$Nm = 'nm'
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
    $layout = Get-Az3166PackageLayout -RepositoryRoot $repositoryRoot -Profile $Profile
    Copy-Az3166Platform -RepositoryRoot $repositoryRoot -Destination $platform -Profile $layout.Profile -Ar $Ar -Nm $Nm
    Write-Host "Host-test profile: $($layout.Profile)"
    if ($layout.Profile -eq 'base') { Write-Host 'Azure configuration and legacy cloud-client tests run only in the azure-iot profile.' }
    $versionHeader = Join-Path $platform 'cores/arduino/system/SystemVersion.h'
    $version = Get-Az3166CoreVersion -HeaderContent (Get-Content -Raw -LiteralPath $versionHeader) -Source $versionHeader
    if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
        throw "Core version $version does not match expected version $ExpectedVersion."
    }
    $tests = @(
        foreach ($provider in @('base', 'azure')) {
            if ($provider -eq 'azure' -and $layout.Profile -eq 'base') { continue }
            @{
                Name = "$provider-configuration-test"
                Arguments = @(
                    '-std=c++11', '-O1', '-g', '-Wall', '-Wextra', '-Werror'
                    if ($provider -eq 'base') { '-DAZ3166_TEST_BASE' }
                    '-I', "$platform/system/mbed-os"
                    '-I', "$platform/system/az3166-driver/mico/include"
                    '-I', "$platform/cores/arduino"
                    '-I', "$platform/cores/arduino/system"
                    '-I', "$platform/cores/arduino/system/azure-iot"
                    "$repositoryRoot/tests/host/cloud/AzureConfigurationTest.cpp"
                )
                RunArguments = @()
                Sanitize = $true
            }
        }
        @{
            Name = 'system-tick-test'
            Arguments = @(
                '-std=c++11', '-O1', '-g', '-Wall', '-Wextra', '-Werror'
                '-I', "$platform/system/mbed-os"
                "$repositoryRoot/tests/host/core/SystemTickCounterTest.cpp"
            )
            RunArguments = @()
            Sanitize = $true
        }
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
        if ($layout.Profile -eq 'azure-iot') { @{
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
        } }
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
        Write-Host "$($tests.Count) host programs compiled and linked; no tests executed."
    }
    else {
        Write-Host "$($tests.Count) host programs compiled and executed successfully."
    }
}
finally {
    $env:ASAN_OPTIONS = $previousAsan
    $env:UBSAN_OPTIONS = $previousUbsan
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}