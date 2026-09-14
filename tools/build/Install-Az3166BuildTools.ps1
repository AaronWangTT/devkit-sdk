#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root,

    [string]$DownloadCache,

    [switch]$Clean,

    [switch]$Offline,

    [switch]$VerifyOnly,

    [string]$LockPath = (Join-Path $PSScriptRoot 'az3166-build-lock.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'The AZ3166 build tool installer currently supports Windows only.'
}
if ($Clean -and $VerifyOnly) {
    throw '-Clean and -VerifyOnly cannot be used together.'
}

. (Join-Path $PSScriptRoot 'Az3166Build.Common.ps1')

$buildLock = Get-Az3166BuildLock -Path $LockPath
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($rootPath -ceq [IO.Path]::GetPathRoot($rootPath)) {
    throw "Refusing to manage a volume root: $rootPath"
}
$maximumRootLength = [int]$buildLock.hostPrerequisites.windows.maximumToolchainRootLength
if ($rootPath.Length -gt $maximumRootLength) {
    throw "AZ3166 toolchain root length $($rootPath.Length) exceeds the supported maximum of $maximumRootLength`: $rootPath"
}
if (-not $DownloadCache) {
    $DownloadCache = "$rootPath-downloads"
}
$downloadCachePath = [IO.Path]::GetFullPath($DownloadCache).TrimEnd([IO.Path]::DirectorySeparatorChar)

function Test-Az3166PathContains {
    param(
        [string]$Parent,
        [string]$Child
    )

    $parentPrefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
}

if (
    $rootPath.Equals($downloadCachePath, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Az3166PathContains -Parent $rootPath -Child $downloadCachePath) -or
    (Test-Az3166PathContains -Parent $downloadCachePath -Child $rootPath)
) {
    throw '-Root and -DownloadCache must be separate directories.'
}

$lockHash = (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestName = '.az3166-build-tools.json'
$installerId = 'devkit-sdk.az3166-build-tools'

function Get-Az3166InstallerPaths {
    param([string]$InstallationRoot)

    $dataDirectory = Join-Path $InstallationRoot 'portable'
    $compilerRoot = Join-Path $dataDirectory "packages/AZ3166/tools/arm-none-eabi-gcc/$($buildLock.tools.armNoneEabiGcc.version)"
    $openOcdRoot = Join-Path $dataDirectory "packages/AZ3166/tools/openocd/$($buildLock.tools.openocd.version)"
    $openOcdMatches = @(if (Test-Path -LiteralPath $openOcdRoot -PathType Container) {
        Get-ChildItem -LiteralPath $openOcdRoot -Filter 'openocd.exe' -File -Recurse
    })

    return [pscustomobject]@{
        Root = $InstallationRoot
        ArduinoCliPath = Join-Path $InstallationRoot 'arduino-cli.exe'
        ArduinoIdePath = Join-Path $InstallationRoot 'arduino_debug.exe'
        ArduinoDataDirectory = $dataDirectory
        BoardIndexPath = Join-Path $dataDirectory $buildLock.boardManager.indexPath
        CoreDirectory = Join-Path $dataDirectory "packages/AZ3166/hardware/stm32f4/$($buildLock.core.version)"
        CompilerPath = Join-Path $compilerRoot 'bin/arm-none-eabi-g++.exe'
        OpenOcdPath = if ($openOcdMatches.Count -eq 1) { $openOcdMatches[0].FullName } else { $null }
        OpenOcdDirectory = $openOcdRoot
        TargetHeaderPath = Join-Path $compilerRoot "arm-none-eabi/include/c++/$($buildLock.tools.armNoneEabiGcc.compilerVersion)/arm-none-eabi/bits/c++config.h"
        ArduinoUnitDirectory = Join-Path $InstallationRoot 'test-libraries/ArduinoUnit'
        ManifestPath = Join-Path $InstallationRoot $manifestName
    }
}

function Get-Az3166ManagedState {
    param([object]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.Root)) {
        return [pscustomobject]@{ Name = 'Missing'; Manifest = $null }
    }
    if (-not (Test-Path -LiteralPath $Paths.Root -PathType Container)) {
        return [pscustomobject]@{ Name = 'Foreign'; Manifest = $null }
    }
    if (-not (Get-ChildItem -LiteralPath $Paths.Root -Force | Select-Object -First 1)) {
        return [pscustomobject]@{ Name = 'Empty'; Manifest = $null }
    }
    if (-not (Test-Path -LiteralPath $Paths.ManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ Name = 'Foreign'; Manifest = $null }
    }

    try {
        $manifest = Get-Content -Raw -LiteralPath $Paths.ManifestPath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ Name = 'Foreign'; Manifest = $null }
    }

    $properties = @($manifest.PSObject.Properties.Name)
    if (
        'schemaVersion' -notin $properties -or
        'installer' -notin $properties -or
        'root' -notin $properties -or
        'lockSha256' -notin $properties -or
        $manifest.schemaVersion -ne 1 -or
        $manifest.installer -cne $installerId -or
        $manifest.root -isnot [string] -or
        -not $manifest.root.Equals($Paths.Root, [StringComparison]::OrdinalIgnoreCase)
    ) {
        return [pscustomobject]@{ Name = 'Foreign'; Manifest = $manifest }
    }

    return [pscustomobject]@{ Name = 'Managed'; Manifest = $manifest }
}

function Get-Az3166InstallationProblems {
    param(
        [object]$Paths,
        [object]$Manifest
    )

    $problems = [Collections.Generic.List[string]]::new()
    if ($Manifest.lockSha256 -cne $lockHash) {
        $problems.Add('the installation was created from a different build lock')
    }

    foreach ($requiredFile in @(
        $Paths.ArduinoCliPath,
        $Paths.ArduinoIdePath,
        (Join-Path $Paths.CoreDirectory 'platform.txt'),
        (Join-Path $Paths.CoreDirectory 'boards.txt'),
        $Paths.CompilerPath,
        $Paths.TargetHeaderPath,
        $Paths.BoardIndexPath,
        (Join-Path $Paths.ArduinoUnitDirectory 'library.properties'),
        (Join-Path $Paths.ArduinoUnitDirectory 'src/ArduinoUnit.h')
    )) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            $problems.Add("missing file: $requiredFile")
        }
    }

    if (-not $Paths.OpenOcdPath) {
        $problems.Add("expected exactly one openocd.exe under $($Paths.OpenOcdDirectory)")
    }
    if (Test-Path -LiteralPath $Paths.BoardIndexPath -PathType Leaf) {
        $indexHash = (Get-FileHash -LiteralPath $Paths.BoardIndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($indexHash -cne $buildLock.boardManager.sha256) {
            $problems.Add("Board Manager index SHA-256 is $indexHash")
        }
    }
    if (Test-Path -LiteralPath $Paths.ArduinoIdePath -PathType Leaf) {
        $ideVersion = (Get-Item -LiteralPath $Paths.ArduinoIdePath).VersionInfo.ProductVersion
        if ($ideVersion -cne $buildLock.arduino.ide.version) {
            $problems.Add("Arduino IDE product version is '$ideVersion', expected '$($buildLock.arduino.ide.version)'")
        }
    }
    $compareHeader = Get-ChildItem `
        -LiteralPath $Paths.ArduinoUnitDirectory `
        -Filter 'Compare.h' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $compareHeader) {
        $problems.Add("ArduinoUnit Compare.h is missing under $($Paths.ArduinoUnitDirectory)")
    }
    else {
        $compareContent = Get-Content -Raw -LiteralPath $compareHeader.FullName
        if (
            $compareContent.Contains('#include <avr/pgmspace.h>') -or
            -not $compareContent.Contains('#include <pgmspace.h>')
        ) {
            $problems.Add('ArduinoUnit Compare.h does not contain the expected AZ3166 pgmspace include')
        }
    }

    if ($problems.Count -eq 0) {
        $cliOutput = (& $Paths.ArduinoCliPath version 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Az3166ToolVersion -Output $cliOutput -Version $buildLock.arduino.cli.version)) {
            $problems.Add("Arduino CLI did not report version $($buildLock.arduino.cli.version)")
        }

        $compilerOutput = (& $Paths.CompilerPath --version 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Az3166ToolVersion -Output $compilerOutput -Version $buildLock.tools.armNoneEabiGcc.compilerVersion)) {
            $problems.Add("GCC did not report version $($buildLock.tools.armNoneEabiGcc.compilerVersion)")
        }

        $openOcdOutput = (& $Paths.OpenOcdPath --version 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Az3166ToolVersion -Output $openOcdOutput -Version $buildLock.tools.openocd.version)) {
            $problems.Add("OpenOCD did not report version $($buildLock.tools.openocd.version)")
        }
    }

    return @($problems)
}

function New-Az3166InstallerResult {
    param(
        [object]$Paths,
        [bool]$Changed
    )

    return [pscustomobject]@{
        PSTypeName = 'Az3166.BuildTools'
        Status = if ($Changed) { 'Installed' } else { 'Valid' }
        Changed = $Changed
        Root = $Paths.Root
        ArduinoCliPath = $Paths.ArduinoCliPath
        ArduinoIdePath = $Paths.ArduinoIdePath
        ArduinoDataDirectory = $Paths.ArduinoDataDirectory
        CoreDirectory = $Paths.CoreDirectory
        CompilerPath = $Paths.CompilerPath
        OpenOcdPath = $Paths.OpenOcdPath
        TargetHeaderPath = $Paths.TargetHeaderPath
        ArduinoUnitDirectory = $Paths.ArduinoUnitDirectory
        LockSha256 = $lockHash
    }
}

$paths = Get-Az3166InstallerPaths -InstallationRoot $rootPath
$state = Get-Az3166ManagedState -Paths $paths
if ($state.Name -eq 'Foreign') {
    throw "Refusing to modify an installation root not owned by this installer: $rootPath"
}

if ($state.Name -eq 'Managed') {
    $problems = @(Get-Az3166InstallationProblems -Paths $paths -Manifest $state.Manifest)
    if ($problems.Count -eq 0 -and -not $Clean) {
        return (New-Az3166InstallerResult -Paths $paths -Changed $false)
    }
    if ($VerifyOnly) {
        throw "AZ3166 build tools are invalid:`n - $($problems -join "`n - ")"
    }
}
elseif ($VerifyOnly) {
    throw "AZ3166 build tools are not installed at $rootPath"
}

$assets = @(
    [pscustomobject]@{ Name = 'Arduino CLI'; Url = $buildLock.arduino.cli.windowsX64.url; FileName = $buildLock.arduino.cli.windowsX64.archiveFileName; Size = [long]$buildLock.arduino.cli.windowsX64.size; Sha256 = $buildLock.arduino.cli.windowsX64.sha256 }
    [pscustomobject]@{ Name = 'Arduino IDE'; Url = $buildLock.arduino.ide.windows.url; FileName = $buildLock.arduino.ide.windows.archiveFileName; Size = [long]$buildLock.arduino.ide.windows.size; Sha256 = $buildLock.arduino.ide.windows.sha256 }
    [pscustomobject]@{ Name = 'ArduinoUnit'; Url = $buildLock.arduino.unit.archive.url; FileName = $buildLock.arduino.unit.archive.archiveFileName; Size = [long]$buildLock.arduino.unit.archive.size; Sha256 = $buildLock.arduino.unit.archive.sha256 }
    [pscustomobject]@{ Name = 'Board Manager index'; Url = $buildLock.boardManager.indexUrl; FileName = $buildLock.boardManager.indexPath; Size = $null; Sha256 = $buildLock.boardManager.sha256 }
    [pscustomobject]@{ Name = 'AZ3166 Core'; Url = $buildLock.core.canonicalPackage.url; FileName = $buildLock.core.canonicalPackage.archiveFileName; Size = [long]$buildLock.core.canonicalPackage.size; Sha256 = $buildLock.core.canonicalPackage.sha256 }
    [pscustomobject]@{ Name = 'GCC'; Url = $buildLock.tools.armNoneEabiGcc.windows.url; FileName = $buildLock.tools.armNoneEabiGcc.windows.archiveFileName; Size = [long]$buildLock.tools.armNoneEabiGcc.windows.size; Sha256 = $buildLock.tools.armNoneEabiGcc.windows.sha256 }
    [pscustomobject]@{ Name = 'OpenOCD'; Url = $buildLock.tools.openocd.windows.url; FileName = $buildLock.tools.openocd.windows.archiveFileName; Size = [long]$buildLock.tools.openocd.windows.size; Sha256 = $buildLock.tools.openocd.windows.sha256 }
)

function Get-Az3166AssetProblem {
    param(
        [object]$Asset,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    if ($null -ne $Asset.Size -and (Get-Item -LiteralPath $Path).Length -ne $Asset.Size) {
        return "size is $((Get-Item -LiteralPath $Path).Length), expected $($Asset.Size)"
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $Asset.Sha256) {
        return "SHA-256 is $hash"
    }
    return $null
}

foreach ($asset in $assets) {
    if ([IO.Path]::GetFileName($asset.FileName) -cne $asset.FileName) {
        throw "Invalid cached asset filename: $($asset.FileName)"
    }
}

if ($Offline) {
    $cacheProblems = @($assets | ForEach-Object {
        $problem = Get-Az3166AssetProblem -Asset $_ -Path (Join-Path $downloadCachePath $_.FileName)
        if ($problem) {
            "$($_.FileName): $problem"
        }
    })
    if ($cacheProblems.Count -gt 0) {
        throw "Offline cache is incomplete:`n - $($cacheProblems -join "`n - ")"
    }
}
else {
    New-Item -ItemType Directory -Path $downloadCachePath -Force | Out-Null
    foreach ($asset in $assets) {
        $cachePath = Join-Path $downloadCachePath $asset.FileName
        if (-not (Get-Az3166AssetProblem -Asset $asset -Path $cachePath)) {
            continue
        }

        $temporaryPath = Join-Path $downloadCachePath ".$($asset.FileName).$([guid]::NewGuid().ToString('N')).download"
        try {
            Write-Host "Downloading $($asset.Name)..."
            Invoke-WebRequest -Uri $asset.Url -OutFile $temporaryPath -UseBasicParsing
            $problem = Get-Az3166AssetProblem -Asset $asset -Path $temporaryPath
            if ($problem) {
                throw "Downloaded $($asset.Name) is invalid: $problem"
            }
            if (Test-Path -LiteralPath $cachePath) {
                Remove-Item -LiteralPath $cachePath -Recurse -Force
            }
            Move-Item -LiteralPath $temporaryPath -Destination $cachePath
        }
        finally {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$rootParent = Split-Path -Parent $rootPath
New-Item -ItemType Directory -Path $rootParent -Force | Out-Null
$operationId = [guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path $rootParent ".az3166-installing-$operationId"
$backupRoot = Join-Path $rootParent ".az3166-replaced-$operationId"

try {
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null

    $ideExtractionRoot = Join-Path $stagingRoot 'ide'
    Expand-Archive `
        -LiteralPath (Join-Path $downloadCachePath $buildLock.arduino.ide.windows.archiveFileName) `
        -DestinationPath $ideExtractionRoot
    $candidateRoot = Join-Path $ideExtractionRoot "arduino-$($buildLock.arduino.ide.version)"
    if (-not (Test-Path -LiteralPath (Join-Path $candidateRoot 'arduino_debug.exe') -PathType Leaf)) {
        throw 'Arduino IDE archive does not contain the expected root directory.'
    }

    $cliExtractionRoot = Join-Path $stagingRoot 'cli'
    Expand-Archive `
        -LiteralPath (Join-Path $downloadCachePath $buildLock.arduino.cli.windowsX64.archiveFileName) `
        -DestinationPath $cliExtractionRoot
    $cliExecutables = @(Get-ChildItem -LiteralPath $cliExtractionRoot -Filter 'arduino-cli.exe' -File -Recurse)
    if ($cliExecutables.Count -ne 1) {
        throw 'Arduino CLI archive does not contain exactly one arduino-cli.exe.'
    }
    Copy-Item -LiteralPath $cliExecutables[0].FullName -Destination (Join-Path $candidateRoot 'arduino-cli.exe')

    $unitExtractionRoot = Join-Path $stagingRoot 'unit'
    Expand-Archive `
        -LiteralPath (Join-Path $downloadCachePath $buildLock.arduino.unit.archive.archiveFileName) `
        -DestinationPath $unitExtractionRoot
    $unitProperties = @(Get-ChildItem -LiteralPath $unitExtractionRoot -Filter 'library.properties' -File -Recurse)
    if ($unitProperties.Count -ne 1) {
        throw 'ArduinoUnit archive does not contain exactly one library.properties file.'
    }
    $unitDestination = Join-Path $candidateRoot 'test-libraries/ArduinoUnit'
    New-Item -ItemType Directory -Path (Split-Path -Parent $unitDestination) -Force | Out-Null
    Copy-Item -LiteralPath $unitProperties[0].Directory.FullName -Destination $unitDestination -Recurse
    $compareHeader = Get-ChildItem -LiteralPath $unitDestination -Filter 'Compare.h' -File -Recurse | Select-Object -First 1
    if (-not $compareHeader) {
        throw 'ArduinoUnit Compare.h was not found.'
    }
    $compareContent = Get-Content -Raw -LiteralPath $compareHeader.FullName
    $avrInclude = '#include <avr/pgmspace.h>'
    if (-not $compareContent.Contains($avrInclude)) {
        throw "ArduinoUnit $($buildLock.arduino.unit.version) no longer has the expected pgmspace include."
    }
    $compareContent.Replace($avrInclude, '#include <pgmspace.h>') |
        Set-Content -LiteralPath $compareHeader.FullName -Encoding ascii -NoNewline

    $candidatePaths = Get-Az3166InstallerPaths -InstallationRoot $candidateRoot
    $packageStaging = Join-Path $candidatePaths.ArduinoDataDirectory 'staging/packages'
    New-Item -ItemType Directory -Path $packageStaging -Force | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $downloadCachePath $buildLock.boardManager.indexPath) `
        -Destination $candidatePaths.BoardIndexPath
    foreach ($asset in @(
        $buildLock.core.canonicalPackage,
        $buildLock.tools.armNoneEabiGcc.windows,
        $buildLock.tools.openocd.windows
    )) {
        Copy-Item `
            -LiteralPath (Join-Path $downloadCachePath $asset.archiveFileName) `
            -Destination (Join-Path $packageStaging $asset.archiveFileName)
    }

    $hadJavaOptions = Test-Path Env:JAVA_TOOL_OPTIONS
    $previousJavaOptions = $env:JAVA_TOOL_OPTIONS
    try {
        if ($Offline) {
            $javaOptions = @(
                '-Djava.net.useSystemProxies=false'
                '-Dhttp.proxyHost=127.0.0.1'
                '-Dhttp.proxyPort=9'
                '-Dhttps.proxyHost=127.0.0.1'
                '-Dhttps.proxyPort=9'
                '-Dhttp.nonProxyHosts='
            )
            if ($previousJavaOptions) {
                $javaOptions = @($previousJavaOptions) + $javaOptions
            }
            $env:JAVA_TOOL_OPTIONS = $javaOptions -join ' '
        }
        $boardManagerOutput = @(& $candidatePaths.ArduinoIdePath `
            --install-boards "AZ3166:stm32f4:$($buildLock.core.version)" `
            --pref "boardsmanager.additional.urls=$($buildLock.boardManager.indexUrl)" `
            --save-prefs 2>&1)
        $boardManagerExitCode = $LASTEXITCODE
    }
    finally {
        if ($hadJavaOptions) {
            $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
        }
        else {
            Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
        }
    }
    $boardManagerOutput | ForEach-Object { Write-Host $_ }
    if ($boardManagerExitCode -ne 0) {
        throw "Arduino IDE failed to install the pinned AZ3166 toolchain (exit code $boardManagerExitCode)."
    }

    $candidatePaths = Get-Az3166InstallerPaths -InstallationRoot $candidateRoot
    $manifest = [ordered]@{
        schemaVersion = 1
        installer = $installerId
        root = $rootPath
        lockSha256 = $lockHash
    }
    $manifest | ConvertTo-Json |
        Set-Content -LiteralPath $candidatePaths.ManifestPath -Encoding utf8
    $candidateProblems = @(Get-Az3166InstallationProblems -Paths $candidatePaths -Manifest ([pscustomobject]$manifest))
    if ($candidateProblems.Count -gt 0) {
        throw "Installed AZ3166 build tools are invalid:`n - $($candidateProblems -join "`n - ")"
    }

    $hadPreviousRoot = Test-Path -LiteralPath $rootPath -PathType Container
    if ($hadPreviousRoot) {
        if (-not (Get-ChildItem -LiteralPath $rootPath -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $rootPath -Force
            $hadPreviousRoot = $false
        }
        else {
            Move-Item -LiteralPath $rootPath -Destination $backupRoot
        }
    }
    try {
        Move-Item -LiteralPath $candidateRoot -Destination $rootPath
    }
    catch {
        if ($hadPreviousRoot -and -not (Test-Path -LiteralPath $rootPath)) {
            Move-Item -LiteralPath $backupRoot -Destination $rootPath
        }
        throw
    }

    try {
        $installedPaths = Get-Az3166InstallerPaths -InstallationRoot $rootPath
        $installedState = Get-Az3166ManagedState -Paths $installedPaths
        $installedProblems = @(if ($installedState.Name -eq 'Managed') {
            Get-Az3166InstallationProblems -Paths $installedPaths -Manifest $installedState.Manifest
        }
        else {
            "unexpected installation state: $($installedState.Name)"
        })
        if ($installedProblems.Count -gt 0) {
            throw "AZ3166 build tools failed final verification:`n - $($installedProblems -join "`n - ")"
        }
    }
    catch {
        Remove-Item -LiteralPath $rootPath -Recurse -Force -ErrorAction SilentlyContinue
        if ($hadPreviousRoot -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Move-Item -LiteralPath $backupRoot -Destination $rootPath
        }
        throw
    }

    if ($hadPreviousRoot -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
    }
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (
        (Test-Path -LiteralPath $backupRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $rootPath)
    ) {
        Move-Item -LiteralPath $backupRoot -Destination $rootPath
    }
}

New-Az3166InstallerResult -Paths $installedPaths -Changed $true