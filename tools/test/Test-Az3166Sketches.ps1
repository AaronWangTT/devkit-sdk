#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ArduinoCli = "arduino-cli",

    [string]$ArduinoDataDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ArduinoUnitDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [switch]$VerboseBuild,

    [string[]]$Sketch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
. (Join-Path $PSScriptRoot 'Az3166BuildEvidence.ps1')
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

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $outputRoot) -and
    (-not (Test-Path -LiteralPath $outputRoot -PathType Container) -or
        @(Get-ChildItem -LiteralPath $outputRoot -Force).Count -gt 0)) {
    throw "Output directory must be empty; choose a fresh -OutputDirectory: $outputRoot"
}
$sketchNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($sketchDirectory in $sketchDirectories) {
    $sketchName = Split-Path -Leaf $sketchDirectory
    if (-not (Test-Az3166WindowsBasename $sketchName) -or -not $sketchNames.Add($sketchName)) {
        throw "Sketch names must be unique safe directory names: $sketchName"
    }
    $destination = Join-Path $outputRoot $sketchName
    if (Test-Path -LiteralPath $destination) {
        throw "Sketch output already exists; choose a fresh -OutputDirectory: $destination"
    }
}

$gitCommand = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
$gitRevision = Invoke-Az3166EvidenceProcess -FilePath $gitCommand `
    -Arguments @('-C', $repositoryRoot, 'rev-parse', 'HEAD') -CaptureOutput
$gitStatus = Invoke-Az3166EvidenceProcess -FilePath $gitCommand `
    -Arguments @('-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=normal') -CaptureOutput
if ($gitRevision.ExitCode -ne 0 -or $gitStatus.ExitCode -ne 0) {
    throw 'Could not record repository revision and dirty-worktree status.'
}

$sketchbook = Join-Path $temporaryRoot "sketchbook"
$librariesDirectory = Join-Path $sketchbook "libraries"
$platformDirectory = Join-Path $sketchbook "hardware\AZ3166Checkout\stm32f4"
$downloadsDirectory = Join-Path $temporaryRoot "downloads"
$configurationPath = Join-Path $temporaryRoot "arduino-cli.yaml"

try {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $versionsPath = Join-Path $outputRoot 'compiler-versions.txt'
    $compilerDirectory = Join-Path $arduinoDataDirectory "packages/AZ3166/tools/$($buildLock.tools.armNoneEabiGcc.packageName)/$($buildLock.tools.armNoneEabiGcc.version)/bin"
    $identities = [ordered]@{}
    $probes = @(
        @{ Name = 'git'; Path = $gitCommand; Arguments = @('--version') }
        @{ Name = 'arduinoCli'; Path = $arduinoCliCommand.Source; Arguments = @('version') }
        foreach ($tool in @('gcc', 'g++', 'as', 'ar', 'ld', 'objcopy', 'size')) {
            @{ Name = $tool; Path = Join-Path $compilerDirectory "arm-none-eabi-$tool$(if ($IsWindows) { '.exe' })"; Arguments = @('--version') }
        }
    )
    foreach ($probe in $probes) {
        $result = Invoke-Az3166EvidenceProcess -FilePath $probe.Path -Arguments $probe.Arguments -LogPath $versionsPath -CaptureOutput
        $identities[$probe.Name] = [ordered]@{ path = $probe.Path; version = $result.Output.Trim(); exitCode = $result.ExitCode }
        if ($result.ExitCode -ne 0) { throw "Could not identify $($probe.Name): exit $($result.ExitCode)" }
    }
    $lockPath = Join-Path $repositoryRoot 'tools/build/az3166-build-lock.json'
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $outputRoot 'az3166-build-lock.json')
    $versionHeader = Join-Path $repositoryRoot 'src/core/arduino/SystemVersion.h'
    $environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
        tools = $identities
        gccPackageVersion = $buildLock.tools.armNoneEabiGcc.version
        coreVersion = Get-Az3166CoreVersion -HeaderContent (Get-Content -Raw -LiteralPath $versionHeader) -Source $versionHeader
        lockedCoreVersion = $buildLock.core.version
        fqbn = $fqbn
        lockSha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        repository = $repositoryRoot
        revision = $gitRevision.Output.Trim()
        dirtyWorktree = -not [string]::IsNullOrWhiteSpace($gitStatus.Output)
        gitStatus = $gitStatus.Output
        arduinoDataDirectory = $arduinoDataDirectory
        arduinoUnitDirectory = $arduinoUnitDirectory
        stagedPlatformDirectory = $platformDirectory
    }
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
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configurationPath -Encoding utf8

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($sketchDirectory in $sketchDirectories) {
        $relativePath = [System.IO.Path]::GetRelativePath($repositoryRoot, $sketchDirectory)
        $sketchName = Split-Path -Leaf $sketchDirectory
        $evidencePath = Join-Path $outputRoot $sketchName
        $buildPath = Join-Path $evidencePath 'build'
        $logPath = Join-Path $evidencePath 'build.log'
        $contextPath = Join-Path $evidencePath 'build-context.json'
        $issues = [Collections.Generic.List[string]]::new()

        Write-Host "Compiling $relativePath"
        $arguments = @(
            '--config-file', $configurationPath,
            '--no-color',
            'compile',
            '--fqbn', $fqbn,
            '--build-path', $buildPath,
            '--warnings', 'all',
            '--verbose',
            $sketchDirectory
        )
        $context = [ordered]@{
            schemaVersion = 1
            sketch = $relativePath
            sketchDirectory = $sketchDirectory
            buildDirectory = $buildPath
            environment = $environment
            startedAt = [DateTime]::UtcNow.ToString('o')
            finishedAt = $null
            status = 'running'
            compile = [ordered]@{ executable = $arduinoCliCommand.Source; arguments = $arguments; exitCode = $null }
            compilationDatabase = [ordered]@{ arguments = @($arguments) + '--only-compilation-database'; exitCode = $null; entries = 0 }
            sizeExitCode = $null
            artifacts = @()
            errors = @()
        }
        try {
            New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
            Copy-Item -LiteralPath $versionsPath -Destination (Join-Path $evidencePath 'compiler-versions.txt')
            $context | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contextPath -Encoding utf8
        }
        catch {
            Write-Host "Could not prepare evidence for ${relativePath}: $($_.Exception.Message)"
            $failures.Add($relativePath)
            continue
        }
        try {
            $result = Invoke-Az3166EvidenceProcess -FilePath $arduinoCliCommand.Source -Arguments $arguments -LogPath $logPath
            $context.compile.exitCode = $result.ExitCode
            if ($result.ExitCode -ne 0) { $issues.Add("Arduino CLI compile failed with exit code $($result.ExitCode).") }
        }
        catch {
            $issues.Add("Compilation: $($_.Exception.Message)")
        }

        try {
            $artifacts = @(Get-ChildItem -LiteralPath $buildPath -File | Where-Object { $_.Extension -in '.elf', '.map', '.bin' })
            $context.artifacts = @(
                foreach ($artifact in $artifacts) {
                    Copy-Item -LiteralPath $artifact.FullName -Destination (Join-Path $evidencePath $artifact.Name)
                    [ordered]@{
                        name = $artifact.Name
                        bytes = $artifact.Length
                        sha256 = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            )
            foreach ($extension in @('.elf', '.map', '.bin')) {
                if (@($artifacts | Where-Object { $_.Extension -eq $extension -and $_.Length -gt 0 }).Count -eq 0) {
                    $issues.Add("Missing nonempty $extension artifact.")
                }
            }
            $elf = @($artifacts | Where-Object { $_.Extension -eq '.elf' -and $_.Length -gt 0 })
            if ($elf.Count -eq 1) {
                $result = Invoke-Az3166EvidenceProcess -FilePath $identities['size'].path `
                    -Arguments @('-A', $elf[0].FullName) -LogPath $logPath -CaptureOutput
                $context.sizeExitCode = $result.ExitCode
                $result.Output | Set-Content -LiteralPath (Join-Path $evidencePath 'size.txt') -Encoding utf8 -NoNewline
                if ($result.ExitCode -ne 0) { throw "GNU size failed with exit code $($result.ExitCode)." }
                ConvertFrom-Az3166SizeReport -Output $result.Output -ElfName $elf[0].Name |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidencePath 'size.json') -Encoding utf8
            }
            else {
                $issues.Add('Expected exactly one nonempty ELF for size reporting.')
            }
        }
        catch {
            $issues.Add("Artifacts and sizes: $($_.Exception.Message)")
        }

        try {
            $databasePath = Join-Path $buildPath 'compile_commands.json'
            if (Test-Path -LiteralPath $databasePath -PathType Leaf) {
                Copy-Item -LiteralPath $databasePath -Destination (Join-Path $evidencePath 'compile_commands.build.json')
            }
            $result = Invoke-Az3166EvidenceProcess -FilePath $arduinoCliCommand.Source `
                -Arguments $context.compilationDatabase.arguments -LogPath $logPath
            $context.compilationDatabase.exitCode = $result.ExitCode
            if (Test-Path -LiteralPath $databasePath -PathType Leaf) {
                Copy-Item -LiteralPath $databasePath -Destination (Join-Path $evidencePath 'compile_commands.json')
            }
            if ($result.ExitCode -ne 0) { throw "Arduino CLI database generation failed with exit code $($result.ExitCode)." }
            $sketchFile = @('ino', 'pde' | ForEach-Object { Join-Path $sketchDirectory "$sketchName.$_" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })[0]
            $context.compilationDatabase.entries = Assert-Az3166CompilationDatabase -Path $databasePath `
                -SketchSource (Join-Path $buildPath "sketch/$([IO.Path]::GetFileName($sketchFile)).cpp")
        }
        catch {
            $issues.Add("Compilation database: $($_.Exception.Message)")
        }
        $context.finishedAt = [DateTime]::UtcNow.ToString('o')
        $context.status = if ($issues.Count -eq 0) { 'passed' } else { 'failed' }
        $context.errors = @($issues)
        try {
            $context | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contextPath -Encoding utf8
            foreach ($issue in $issues) {
                Write-Host $issue
                Add-Content -LiteralPath $logPath -Value $issue -Encoding utf8
            }
        }
        catch {
            $issues.Add("Could not finish evidence for ${relativePath}: $($_.Exception.Message)")
            Write-Host $issues[-1]
        }
        if ($issues.Count -gt 0) { $failures.Add($relativePath) }
    }

    Get-Az3166EvidenceSummary -OutputDirectory $outputRoot |
        Set-Content -LiteralPath (Join-Path $outputRoot 'summary.md') -Encoding utf8
    if ($failures.Count -gt 0) {
        throw "$($failures.Count) Arduino test sketch build(s) failed: $($failures -join ', ')"
    }

    Write-Host "$($sketchDirectories.Count) Arduino test sketch build(s) passed."
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}