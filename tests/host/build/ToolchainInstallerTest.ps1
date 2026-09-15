#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$DownloadCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host 'SKIP AZ3166 toolchain installer tests require Windows.'
    return
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installerPath = Join-Path $repositoryRoot 'tools/build/Install-Az3166BuildTools.ps1'
$lockPath = Join-Path $repositoryRoot 'tools/build/az3166-build-lock.json'
$volumeRoot = [IO.Path]::GetPathRoot([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $volumeRoot "ati-$([guid]::NewGuid().ToString('N'))"
$testCount = 24
. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')

function Assert-InstallerTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-InstallerRejected {
    param(
        [hashtable]$Arguments,
        [string[]]$ExpectedMessages,
        [string[]]$UnexpectedMessages = @()
    )

    $rejected = $false
    try {
        $null = & $installerPath @Arguments
    }
    catch {
        foreach ($expectedMessage in $ExpectedMessages) {
            if ($_.Exception.Message -notlike $expectedMessage) {
                throw "Expected error '$expectedMessage', received '$($_.Exception.Message)'."
            }
        }
        foreach ($unexpectedMessage in $UnexpectedMessages) {
            if ($_.Exception.Message -like $unexpectedMessage) {
                throw "Unexpected error '$unexpectedMessage' in '$($_.Exception.Message)'."
            }
        }
        $rejected = $true
    }
    Assert-InstallerTest $rejected "Installer unexpectedly accepted arguments: $($Arguments.Keys -join ', ')"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $root = Join-Path $fixtureRoot 'root'
    $cache = Join-Path $fixtureRoot 'cache'

    foreach ($version in @('1.5.1', '5.4.1', '0.10.0')) {
        foreach ($output in @("Version: $version", "Version: $version (release)", "Version: $version-rc1")) {
            Assert-InstallerTest (Test-Az3166ToolVersion -Output $output -Version $version) "Exact version token was rejected: $output"
        }
        foreach ($output in @("Version: ${version}0", "Version: ${version}1", "Version: ${version}.0", "Version: 1$version", "Version: 9.$version", "Version: ${version}beta", "Version: ${version}_debug", "Version: other$version", 'no version')) {
            Assert-InstallerTest (-not (Test-Az3166ToolVersion -Output $output -Version $version)) "Different version token was accepted: $output"
        }
    }
    Write-Host 'PASS tool identity checks require complete numeric version tokens'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Clean = $true; VerifyOnly = $true } `
        -ExpectedMessages @('*-Clean and -VerifyOnly cannot be used together.*')
    Write-Host 'PASS incompatible modes are rejected'

    foreach ($volumeRootPath in @($volumeRoot, $volumeRoot.Replace('\', '/'))) {
        Assert-InstallerRejected `
            -Arguments @{ Root = $volumeRootPath; DownloadCache = $cache; VerifyOnly = $true } `
            -ExpectedMessages @('*Refusing to manage a volume root:*')
        Assert-InstallerRejected `
            -Arguments @{ Root = $root; DownloadCache = $volumeRootPath; VerifyOnly = $true } `
            -ExpectedMessages @('*Refusing to use a volume root as the download cache:*')
    }
    Write-Host 'PASS installation and cache volume roots are rejected before access'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = (Join-Path $root 'downloads') } `
        -ExpectedMessages @('*-Root and -DownloadCache must be separate directories.*')
    Write-Host 'PASS overlapping managed and cache roots are rejected'

    $aliasTarget = Join-Path $fixtureRoot 'alias-target'
    $aliasPath = Join-Path $fixtureRoot 'alias'
    New-Item -ItemType Directory -Path $aliasTarget | Out-Null
    $aliasSentinel = Join-Path $aliasTarget 'keep.txt'
    Set-Content -LiteralPath $aliasSentinel -Value 'preserved' -Encoding ascii
    New-Item -ItemType Junction -Path $aliasPath -Target $aliasTarget | Out-Null
    foreach ($arguments in @(
        @{ Root = $aliasPath; DownloadCache = $cache; VerifyOnly = $true },
        @{ Root = (Join-Path $aliasPath 'root'); DownloadCache = $cache; VerifyOnly = $true },
        @{ Root = $root; DownloadCache = $aliasPath; Offline = $true },
        @{ Root = $root; DownloadCache = (Join-Path $aliasPath 'cache'); Offline = $true }
    )) {
        Assert-InstallerRejected `
            -Arguments $arguments `
            -ExpectedMessages @('*Refusing to use a reparse point*')
    }
    Assert-InstallerTest ((Get-Content -Raw -LiteralPath $aliasSentinel).Trim() -ceq 'preserved') 'Junction validation modified the target.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'Junction validation created the installation root.'
    Remove-Item -LiteralPath $aliasPath -Force
    Remove-Item -LiteralPath $aliasTarget -Recurse -Force
    Write-Host 'PASS junction roots and cache ancestors are rejected without writes'

    $maximumRoot = Join-Path $volumeRoot ('p' * (70 - $volumeRoot.Length))
    Assert-InstallerTest ($maximumRoot.Length -eq 70) 'The maximum-length fixture root is not 70 characters long.'
    Assert-InstallerRejected `
        -Arguments @{ Root = $maximumRoot; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*AZ3166 build tools are not installed at*')
    Assert-InstallerTest (-not (Test-Path -LiteralPath $maximumRoot)) 'Maximum-length validation created the missing root.'
    Write-Host 'PASS a 70-character toolchain root reaches normal validation'

    $longRoot = Join-Path $volumeRoot ('p' * (71 - $volumeRoot.Length))
    Assert-InstallerTest ($longRoot.Length -eq 71) 'The over-limit fixture root is not 71 characters long.'
    Assert-InstallerRejected `
        -Arguments @{ Root = $longRoot; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*root length 71 exceeds the supported maximum of 70*')
    Assert-InstallerTest (-not (Test-Path -LiteralPath $longRoot)) 'Path-limit validation created the rejected root.'
    Write-Host 'PASS toolchain roots longer than 70 characters are rejected'

    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*AZ3166 build tools are not installed at*')
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'VerifyOnly created the missing installation root.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $cache)) 'VerifyOnly created the download cache.'
    Write-Host 'PASS missing VerifyOnly is read-only'

    New-Item -ItemType Directory -Path $root | Out-Null
    $foreignFile = Join-Path $root 'keep.txt'
    Set-Content -LiteralPath $foreignFile -Value 'foreign' -Encoding ascii
    foreach ($arguments in @(
        @{ Root = $root; DownloadCache = $cache },
        @{ Root = $root; DownloadCache = $cache; Clean = $true }
    )) {
        Assert-InstallerRejected `
            -Arguments $arguments `
            -ExpectedMessages @('*not owned by this installer*')
    }
    Assert-InstallerTest ((Get-Content -Raw -LiteralPath $foreignFile).Trim() -ceq 'foreign') 'Foreign content was modified.'
    Write-Host 'PASS foreign roots are preserved'

    Remove-Item -LiteralPath $root -Recurse -Force
    New-Item -ItemType Directory -Path $root | Out-Null
    @{
        schemaVersion = 1
        installer = 'devkit-sdk.az3166-build-tools'
        root = $null
        lockSha256 = 'unused'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.az3166-build-tools.json') -Encoding utf8
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*not owned by this installer*')
    Write-Host 'PASS malformed manifests are treated as foreign'

    Remove-Item -LiteralPath $root -Recurse -Force
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $expectedCacheFiles = @(
        $lock.arduino.cli.windowsX64.archiveFileName,
        $lock.arduino.ide.windows.archiveFileName,
        $lock.arduino.unit.archive.archiveFileName,
        $lock.boardManager.indexPath,
        $lock.core.canonicalPackage.archiveFileName,
        $lock.tools.armNoneEabiGcc.windows.archiveFileName,
        $lock.tools.openocd.windows.archiveFileName
    )
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Offline = $true } `
        -ExpectedMessages @($expectedCacheFiles | ForEach-Object { "*${_}: missing*" })
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'Offline cache validation created the installation root.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $cache)) 'Offline cache validation created the missing cache.'
    Write-Host 'PASS offline mode reports every missing asset without writes'

    New-Item -ItemType Directory -Path $root | Out-Null
    [ordered]@{
        schemaVersion = 1
        installer = 'devkit-sdk.az3166-build-tools'
        root = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
        lockSha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.az3166-build-tools.json') -Encoding utf8
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @(
            '*AZ3166 build tools are invalid:*',
            '*missing file:*arduino-cli.exe*',
            '*missing file:*SystemVersion.h*',
            '*expected exactly one openocd.exe*'
        )
    Write-Host 'PASS partial managed installations are diagnosed'

    $linkedTarget = Join-Path $fixtureRoot 'linked-target'
    New-Item -ItemType Directory -Path $linkedTarget | Out-Null
    $linkedSentinel = Join-Path $linkedTarget 'keep.txt'
    Set-Content -LiteralPath $linkedSentinel -Value 'preserved' -Encoding ascii
    foreach ($relativeLinkPath in @(
        'arduino-cli.exe',
        "portable/packages/AZ3166/tools/arm-none-eabi-gcc/$($lock.tools.armNoneEabiGcc.version)/bin/arm-none-eabi-g++.exe",
        "portable/$($lock.boardManager.indexPath)",
        'nested/dangling.txt',
        'nested/junction'
    )) {
        $linkedPath = Join-Path $root $relativeLinkPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $linkedPath) -Force | Out-Null
        if ($relativeLinkPath -eq 'nested/junction') {
            New-Item -ItemType Junction -Path $linkedPath -Target $linkedTarget | Out-Null
        }
        else {
            $linkTarget = if ($relativeLinkPath -eq 'nested/dangling.txt') { Join-Path $linkedTarget 'missing.txt' } else { $linkedSentinel }
            New-Item -ItemType SymbolicLink -Path $linkedPath -Target $linkTarget | Out-Null
        }
        foreach ($arguments in @(
            @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true },
            @{ Root = $root; DownloadCache = $cache; Offline = $true },
            @{ Root = $root; DownloadCache = $cache; Clean = $true; Offline = $true }
        )) {
            Assert-InstallerRejected -Arguments $arguments -ExpectedMessages @('*Refusing to use a reparse point*')
        }
        Assert-InstallerTest ((Get-Content -Raw -LiteralPath $linkedSentinel).Trim() -ceq 'preserved') 'Managed-tree validation modified the link target.'
        Remove-Item -LiteralPath $linkedPath -Force
    }
    Write-Host 'PASS managed file links and nested junctions are rejected before use or cleanup'

    New-Item -ItemType Directory -Path $cache | Out-Null
    $linkedCacheEntry = Join-Path $cache $lock.arduino.cli.windowsX64.archiveFileName
    New-Item -ItemType SymbolicLink -Path $linkedCacheEntry -Target $linkedSentinel | Out-Null
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache } `
        -ExpectedMessages @('*Refusing to use a reparse point*')
    Remove-Item -LiteralPath $linkedCacheEntry -Force
    New-Item -ItemType Directory -Path $linkedCacheEntry | Out-Null
    $nestedCacheLink = Join-Path $linkedCacheEntry 'junction'
    New-Item -ItemType Junction -Path $nestedCacheLink -Target $linkedTarget | Out-Null
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache } `
        -ExpectedMessages @('*Refusing to use a reparse point*')
    Assert-InstallerTest ((Get-Content -Raw -LiteralPath $linkedSentinel).Trim() -ceq 'preserved') 'Cache validation modified the link target.'
    Remove-Item -LiteralPath $nestedCacheLink -Force
    Remove-Item -LiteralPath $cache -Recurse -Force
    Remove-Item -LiteralPath $linkedTarget -Recurse -Force
    Write-Host 'PASS linked cache entries are rejected before repair'

    $unitPropertiesPath = Join-Path $root 'test-libraries/ArduinoUnit/library.properties'
    New-Item -ItemType Directory -Path (Split-Path -Parent $unitPropertiesPath) -Force | Out-Null
    foreach ($unitProperties in @(
        "name=ArduinoUnit`nversion=0.0.0",
        "name=ArduinoUnit`nversion=0.0",
        "name=ArduinoUnit`nversion=$($lock.arduino.unit.version)1",
        "name=ArduinoUnit`nversion=$($lock.arduino.unit.version).1",
        'name=ArduinoUnit'
    )) {
        Set-Content -LiteralPath $unitPropertiesPath -Value $unitProperties -Encoding ascii
        Assert-InstallerRejected `
            -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
            -ExpectedMessages @("*ArduinoUnit version is *, expected '$($lock.arduino.unit.version)'*")
    }
    Write-Host 'PASS wrong and missing ArduinoUnit versions are rejected'

    Set-Content -LiteralPath $unitPropertiesPath -Value 'not a properties file' -Encoding ascii
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*ArduinoUnit metadata is invalid:*')
    Write-Host 'PASS malformed ArduinoUnit metadata is diagnosed'

    foreach ($unitVersion in @($lock.arduino.unit.version, ([version]$lock.arduino.unit.version).ToString(2))) {
        Set-Content -LiteralPath $unitPropertiesPath -Value "name=ArduinoUnit`nversion=$unitVersion" -Encoding ascii
        Assert-InstallerRejected `
            -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
            -ExpectedMessages @('*missing file:*arduino-cli.exe*') `
            -UnexpectedMessages @('*ArduinoUnit version is *', '*ArduinoUnit metadata is invalid:*')
    }
    Write-Host 'PASS locked ArduinoUnit version metadata is accepted'

    $coreVersionHeaderPath = Join-Path $root "portable/packages/AZ3166/hardware/stm32f4/$($lock.core.version)/cores/arduino/system/SystemVersion.h"
    New-Item -ItemType Directory -Path (Split-Path -Parent $coreVersionHeaderPath) -Force | Out-Null
    Set-Content -LiteralPath $coreVersionHeaderPath -Value @(
        '#define DEVKIT_MAJOR_VERSION 0',
        '#define DEVKIT_MINOR_VERSION 0',
        '#define DEVKIT_PATCH_VERSION 0'
    ) -Encoding ascii
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @("*Core version is '0.0.0', expected '$($lock.core.version)'*")
    Write-Host 'PASS wrong installed Core versions are rejected'

    foreach ($headerContent in @('#define DEVKIT_MAJOR_VERSION 2', '#define DEVKIT_MAJOR_VERSION unknown')) {
        Set-Content -LiteralPath $coreVersionHeaderPath -Value $headerContent -Encoding ascii
        Assert-InstallerRejected `
            -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
            -ExpectedMessages @('*Core version metadata is invalid:*')
    }
    Write-Host 'PASS missing and malformed Core version definitions are diagnosed'

    $expectedCoreVersion = [version]$lock.core.version
    Set-Content -LiteralPath $coreVersionHeaderPath -Value @(
        "#define DEVKIT_MAJOR_VERSION $($expectedCoreVersion.Major)",
        "#define DEVKIT_MINOR_VERSION $($expectedCoreVersion.Minor)",
        "#define DEVKIT_PATCH_VERSION $($expectedCoreVersion.Build)"
    ) -Encoding ascii
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @('*missing file:*arduino-cli.exe*') `
        -UnexpectedMessages @('*Core version is *', '*Core version metadata is invalid:*')
    Write-Host 'PASS locked Core version metadata is accepted'

    $idePath = Join-Path $root 'arduino_debug.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -Destination $idePath
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @(
            "*Arduino IDE product version is *, expected '$($lock.arduino.ide.version)'*",
            '*missing file:*arduino-cli.exe*'
        )
    Write-Host 'PASS partial installations report a different IDE product version'

    Set-Content -LiteralPath $idePath -Value 'not an executable' -Encoding ascii
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; VerifyOnly = $true } `
        -ExpectedMessages @(
            "*Arduino IDE product version is '', expected '$($lock.arduino.ide.version)'*",
            '*missing file:*arduino-cli.exe*'
        )
    Write-Host 'PASS partial installations report missing IDE version metadata'

    New-Item -ItemType Directory -Path $cache | Out-Null
    Set-Content -LiteralPath (Join-Path $cache $lock.arduino.cli.windowsX64.archiveFileName) -Value 'corrupt' -Encoding ascii
    Remove-Item -LiteralPath $root -Recurse -Force
    Assert-InstallerRejected `
        -Arguments @{ Root = $root; DownloadCache = $cache; Offline = $true } `
        -ExpectedMessages @("*$($lock.arduino.cli.windowsX64.archiveFileName): size is*")
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'Corrupt offline cache input was extracted.'
    Write-Host 'PASS corrupt cached assets fail before extraction'

    $archiveFixture = Join-Path $fixtureRoot 'cli-fixture.zip'
    Set-Content -LiteralPath $archiveFixture -Value 'verified fixture' -Encoding ascii
    $cacheLock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $cacheLock.arduino.cli.windowsX64.size = (Get-Item -LiteralPath $archiveFixture).Length
    $cacheLock.arduino.cli.windowsX64.sha256 = (Get-FileHash -LiteralPath $archiveFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    $fixtureLockPath = Join-Path $fixtureRoot 'cache-lock.json'
    $cacheLock | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    $cacheEntry = Join-Path $cache $cacheLock.arduino.cli.windowsX64.archiveFileName
    Remove-Item -LiteralPath $cacheEntry -Force
    New-Item -ItemType Directory -Path (Join-Path $cacheEntry 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cacheEntry 'nested/stale.txt') -Value 'invalid cache entry' -Encoding ascii
    $siblingPath = Join-Path $cache 'keep.txt'
    Set-Content -LiteralPath $siblingPath -Value 'keep' -Encoding ascii

    & {
        function Invoke-WebRequest {
            param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)

            if ($Uri -ne $cacheLock.arduino.cli.windowsX64.url) {
                throw 'Fixture stopped before IDE download.'
            }
            Copy-Item -LiteralPath $archiveFixture -Destination $OutFile
        }

        Assert-InstallerRejected `
            -Arguments @{ Root = $root; DownloadCache = $cache; LockPath = $fixtureLockPath } `
            -ExpectedMessages @('Fixture stopped before IDE download.')
    }

    Assert-InstallerTest (Test-Path -LiteralPath $cacheEntry -PathType Leaf) 'The invalid cache directory was not replaced by a file.'
    Assert-InstallerTest `
        ((Get-FileHash -LiteralPath $cacheEntry -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $cacheLock.arduino.cli.windowsX64.sha256) `
        'The repaired cache entry does not contain the verified download.'
    Assert-InstallerTest ((Get-Content -Raw -LiteralPath $siblingPath).Trim() -ceq 'keep') 'Repair modified a sibling cache entry.'
    Assert-InstallerTest (-not (Test-Path -LiteralPath $root)) 'The download fixture unexpectedly reached extraction.'
    Write-Host 'PASS online repair replaces only the invalid cache directory with a verified file'

    if ($DownloadCache) {
        $boundaryParent = Join-Path $fixtureRoot ('p' * (70 - $fixtureRoot.Length - 3))
        $boundaryRoot = Join-Path $boundaryParent 'a'
        Assert-InstallerTest ($boundaryRoot.Length -eq 70) 'The boundary installation root must be 70 characters long.'
        $boundaryArguments = @{ Root = $boundaryRoot; DownloadCache = $DownloadCache }
        $boundaryTools = & $installerPath @boundaryArguments -Offline
        Assert-InstallerTest $boundaryTools.Changed 'The fresh boundary installation did not report a change.'
        $secondBoundary = & $installerPath @boundaryArguments -Offline
        Assert-InstallerTest (-not $secondBoundary.Changed) 'The second boundary setup changed the installation.'
        $null = & $installerPath @boundaryArguments -VerifyOnly
        $cleanBoundary = & $installerPath @boundaryArguments -Clean -Offline
        Assert-InstallerTest $cleanBoundary.Changed 'The clean boundary replacement did not report a change.'
        Assert-InstallerTest (@(Get-ChildItem -LiteralPath $boundaryParent -Filter '.az3166-*' -Force).Count -eq 0) 'Boundary replacement left staging or backup directories.'
        $testCount++
        Write-Host 'PASS full offline installation and replacement at a 70-character root with a long parent'

        $externalCli = Join-Path $fixtureRoot 'boundary-cli.exe'
        Move-Item -LiteralPath $boundaryTools.ArduinoCliPath -Destination $externalCli
        try {
            New-Item -ItemType SymbolicLink -Path $boundaryTools.ArduinoCliPath -Target $externalCli | Out-Null
            foreach ($mode in @(@{ VerifyOnly = $true }, @{ Clean = $true; Offline = $true })) {
                Assert-InstallerRejected `
                    -Arguments ($boundaryArguments + $mode) `
                    -ExpectedMessages @('*Refusing to use a reparse point*')
            }
            Assert-InstallerTest (Test-Path -LiteralPath $externalCli -PathType Leaf) 'Verification removed the external CLI target.'
        }
        finally {
            Remove-Item -LiteralPath $boundaryTools.ArduinoCliPath -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $externalCli -Destination $boundaryTools.ArduinoCliPath
        }
        $testCount++
        Write-Host 'PASS linked executables in a complete installation are rejected before verification or clean setup'
    }
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$testCount toolchain-installer tests passed."