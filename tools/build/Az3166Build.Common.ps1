#requires -Version 7.0

Set-StrictMode -Version Latest

function Test-Az3166ToolVersion {
    param(
        [string]$Output,
        [string]$Version
    )

    return $Output -match ('(?<![0-9A-Za-z_.])' + [regex]::Escape($Version) + '(?![0-9A-Za-z_.])')
}

function Test-Az3166WindowsBasename {
    param([object]$Value)

    return ($Value -is [string] -and
        $Value -cmatch '\A[A-Za-z0-9._-]*[A-Za-z0-9_-]\z' -and
        $Value -notmatch '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\z)')
}

function Assert-Az3166BuildLockCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Invalid AZ3166 build lock: $Message"
    }
}

function Get-Az3166BuildLockProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        [string]$Context
    )

    if ($null -eq $InputObject -or $Name -notin @($InputObject.PSObject.Properties.Name)) {
        throw "Invalid AZ3166 build lock: missing $Context.$Name."
    }

    return $InputObject.$Name
}

function Assert-Az3166BuildLockString {
    param(
        [object]$Value,
        [string]$Context
    )

    Assert-Az3166BuildLockCondition `
        ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) `
        "$Context must be a nonempty string."
}

function Assert-Az3166BuildLockBasename {
    param(
        [object]$Value,
        [string]$Context
    )

    Assert-Az3166BuildLockString $Value $Context
    Assert-Az3166BuildLockCondition `
        (Test-Az3166WindowsBasename -Value $Value) `
        "$Context must be a safe Windows basename."
}

function Assert-Az3166BuildLockAsset {
    param(
        [object]$Asset,
        [string]$Context
    )

    $url = Get-Az3166BuildLockProperty $Asset 'url' $Context
    $archiveFileName = Get-Az3166BuildLockProperty $Asset 'archiveFileName' $Context
    $sha256 = Get-Az3166BuildLockProperty $Asset 'sha256' $Context
    $size = Get-Az3166BuildLockProperty $Asset 'size' $Context
    Assert-Az3166BuildLockString $url "$Context.url"
    Assert-Az3166BuildLockBasename $archiveFileName "$Context.archiveFileName"

    $uri = $null
    Assert-Az3166BuildLockCondition `
        ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') `
        "$Context.url must be an absolute HTTPS URL."
    Assert-Az3166BuildLockCondition `
        ($uri.Segments[-1] -eq $archiveFileName) `
        "$Context.url must end with archiveFileName."
    Assert-Az3166BuildLockCondition `
        ($sha256 -is [string] -and $sha256 -cmatch '^[0-9a-f]{64}$') `
        "$Context.sha256 must be a lowercase SHA-256 value."

    $parsedSize = 0L
    Assert-Az3166BuildLockCondition `
        ([long]::TryParse([string]$size, [ref]$parsedSize) -and $parsedSize -gt 0) `
        "$Context.size must be a positive integer."
}

function Get-Az3166BuildLock {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'az3166-build-lock.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AZ3166 build lock does not exist: $Path"
    }

    try {
        $lock = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "Invalid AZ3166 build lock JSON at ${Path}: $($_.Exception.Message)"
    }

    $schemaVersion = Get-Az3166BuildLockProperty $lock 'schemaVersion' 'root'
    Assert-Az3166BuildLockCondition ($schemaVersion -eq 1) "unsupported schema version '$schemaVersion'."

    $hostPrerequisites = Get-Az3166BuildLockProperty $lock 'hostPrerequisites' 'root'
    $supportedHostProperties = @('powershell', 'git', 'windows', 'linux')
    $unsupportedHostProperties = @($hostPrerequisites.PSObject.Properties.Name | Where-Object {
        $_ -notin $supportedHostProperties
    })
    Assert-Az3166BuildLockCondition `
        ($unsupportedHostProperties.Count -eq 0) `
        "hostPrerequisites contains unsupported entries: $($unsupportedHostProperties -join ', ')."
    $powershell = Get-Az3166BuildLockProperty $hostPrerequisites 'powershell' 'hostPrerequisites'
    $minimumPowerShell = Get-Az3166BuildLockProperty $powershell 'minimumVersion' 'hostPrerequisites.powershell'
    $parsedPowerShellVersion = $null
    Assert-Az3166BuildLockCondition `
        ([version]::TryParse([string]$minimumPowerShell, [ref]$parsedPowerShellVersion)) `
        'hostPrerequisites.powershell.minimumVersion must be a version.'
    Assert-Az3166BuildLockCondition `
        ($parsedPowerShellVersion -ge [version]'7.0') `
        'hostPrerequisites.powershell.minimumVersion must be 7.0 or later.'

    $git = Get-Az3166BuildLockProperty $hostPrerequisites 'git' 'hostPrerequisites'
    $gitCapabilities = @(Get-Az3166BuildLockProperty $git 'requiredCapabilities' 'hostPrerequisites.git')
    Assert-Az3166BuildLockCondition `
        ($gitCapabilities -contains 'archive --mtime') `
        'hostPrerequisites.git.requiredCapabilities must include archive --mtime.'

    foreach ($hostName in @('windows', 'linux')) {
        $hostConfiguration = Get-Az3166BuildLockProperty $hostPrerequisites $hostName 'hostPrerequisites'
        foreach ($propertyName in @('runner', 'architecture')) {
            $value = Get-Az3166BuildLockProperty $hostConfiguration $propertyName "hostPrerequisites.$hostName"
            Assert-Az3166BuildLockString $value "hostPrerequisites.$hostName.$propertyName"
        }
        Assert-Az3166BuildLockCondition `
            ($hostConfiguration.architecture -ceq 'x86_64') `
            "hostPrerequisites.$hostName.architecture is not supported."
    }

    $windows = $hostPrerequisites.windows
    $shortToolchainRootName = Get-Az3166BuildLockProperty `
        $windows 'shortToolchainRootName' 'hostPrerequisites.windows'
    Assert-Az3166BuildLockString `
        $shortToolchainRootName `
        'hostPrerequisites.windows.shortToolchainRootName'
    Assert-Az3166BuildLockCondition `
        (Test-Az3166WindowsBasename -Value $shortToolchainRootName) `
        'hostPrerequisites.windows.shortToolchainRootName must be a single relative directory name.'
    $maximumToolchainRootLength = Get-Az3166BuildLockProperty `
        $windows 'maximumToolchainRootLength' 'hostPrerequisites.windows'
    $parsedMaximumToolchainRootLength = 0
    Assert-Az3166BuildLockCondition `
        ([int]::TryParse([string]$maximumToolchainRootLength, [ref]$parsedMaximumToolchainRootLength) -and
            $parsedMaximumToolchainRootLength -gt 0) `
        'hostPrerequisites.windows.maximumToolchainRootLength must be a positive integer.'
    Assert-Az3166BuildLockString `
        (Get-Az3166BuildLockProperty $windows 'pathConstraintStatus' 'hostPrerequisites.windows') `
        'hostPrerequisites.windows.pathConstraintStatus'

    $arduino = Get-Az3166BuildLockProperty $lock 'arduino' 'root'
    $fqbn = Get-Az3166BuildLockProperty $arduino 'fqbn' 'arduino'
    Assert-Az3166BuildLockCondition `
        ($fqbn -is [string] -and $fqbn -cmatch '^[^:]+:[^:]+:[^:]+$') `
        'arduino.fqbn must contain vendor, architecture, and board identifiers.'

    $cli = Get-Az3166BuildLockProperty $arduino 'cli' 'arduino'
    Assert-Az3166BuildLockBasename (Get-Az3166BuildLockProperty $cli 'version' 'arduino.cli') 'arduino.cli.version'
    Assert-Az3166BuildLockAsset (Get-Az3166BuildLockProperty $cli 'windowsX64' 'arduino.cli') 'arduino.cli.windowsX64'

    $ide = Get-Az3166BuildLockProperty $arduino 'ide' 'arduino'
    Assert-Az3166BuildLockBasename (Get-Az3166BuildLockProperty $ide 'version' 'arduino.ide') 'arduino.ide.version'
    Assert-Az3166BuildLockAsset (Get-Az3166BuildLockProperty $ide 'windows' 'arduino.ide') 'arduino.ide.windows'

    $unit = Get-Az3166BuildLockProperty $arduino 'unit' 'arduino'
    Assert-Az3166BuildLockBasename (Get-Az3166BuildLockProperty $unit 'version' 'arduino.unit') 'arduino.unit.version'
    Assert-Az3166BuildLockAsset (Get-Az3166BuildLockProperty $unit 'archive' 'arduino.unit') 'arduino.unit.archive'

    $boardManager = Get-Az3166BuildLockProperty $lock 'boardManager' 'root'
    foreach ($propertyName in @('repository', 'revision', 'indexPath', 'indexUrl', 'sha256')) {
        Assert-Az3166BuildLockString `
            (Get-Az3166BuildLockProperty $boardManager $propertyName 'boardManager') `
            "boardManager.$propertyName"
    }
    Assert-Az3166BuildLockBasename $boardManager.indexPath 'boardManager.indexPath'
    Assert-Az3166BuildLockCondition `
        ($boardManager.revision -cmatch '^[0-9a-f]{40}$') `
        'boardManager.revision must be a full lowercase Git commit ID.'
    Assert-Az3166BuildLockCondition `
        ($boardManager.sha256 -cmatch '^[0-9a-f]{64}$') `
        'boardManager.sha256 must be a lowercase SHA-256 value.'
    $expectedIndexUrl = "https://raw.githubusercontent.com/$($boardManager.repository)/$($boardManager.revision)/$($boardManager.indexPath)"
    Assert-Az3166BuildLockCondition `
        ($boardManager.indexUrl -ceq $expectedIndexUrl) `
        'boardManager.indexUrl must use the exact repository, revision, and index path.'

    $core = Get-Az3166BuildLockProperty $lock 'core' 'root'
    Assert-Az3166BuildLockBasename (Get-Az3166BuildLockProperty $core 'version' 'core') 'core.version'
    Assert-Az3166BuildLockAsset (Get-Az3166BuildLockProperty $core 'canonicalPackage' 'core') 'core.canonicalPackage'
    $dependencies = @(Get-Az3166BuildLockProperty $core 'toolDependencies' 'core')

    $tools = Get-Az3166BuildLockProperty $lock 'tools' 'root'
    foreach ($toolProperty in @('armNoneEabiGcc', 'openocd')) {
        $tool = Get-Az3166BuildLockProperty $tools $toolProperty 'tools'
        $packageName = Get-Az3166BuildLockProperty $tool 'packageName' "tools.$toolProperty"
        $version = Get-Az3166BuildLockProperty $tool 'version' "tools.$toolProperty"
        Assert-Az3166BuildLockBasename $packageName "tools.$toolProperty.packageName"
        Assert-Az3166BuildLockBasename $version "tools.$toolProperty.version"
        Assert-Az3166BuildLockAsset `
            (Get-Az3166BuildLockProperty $tool 'windows' "tools.$toolProperty") `
            "tools.$toolProperty.windows"
        $matchingDependencies = @($dependencies | Where-Object {
            $_.name -ceq $packageName -and $_.version -ceq $version
        })
        Assert-Az3166BuildLockCondition `
            ($matchingDependencies.Count -eq 1) `
            "core.toolDependencies must contain $packageName $version exactly once."
    }

    Assert-Az3166BuildLockBasename `
        (Get-Az3166BuildLockProperty $tools.armNoneEabiGcc 'compilerVersion' 'tools.armNoneEabiGcc') `
        'tools.armNoneEabiGcc.compilerVersion'

    return $lock
}

function Export-Az3166BuildLockGitHubOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Lock,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$LockPath = (Join-Path $PSScriptRoot 'az3166-build-lock.json')
    )

    $values = [ordered]@{
        lock_sha256 = (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        short_toolchain_root_name = $Lock.hostPrerequisites.windows.shortToolchainRootName
        maximum_toolchain_root_length = $Lock.hostPrerequisites.windows.maximumToolchainRootLength
        core_version = $Lock.core.version
        core_package_size = $Lock.core.canonicalPackage.size
        core_package_sha256 = $Lock.core.canonicalPackage.sha256
        arduino_cli_version = $Lock.arduino.cli.version
        arduino_ide_version = $Lock.arduino.ide.version
        arduino_ide_url = $Lock.arduino.ide.windows.url
        arduino_ide_size = $Lock.arduino.ide.windows.size
        arduino_ide_sha256 = $Lock.arduino.ide.windows.sha256
        index_revision = $Lock.boardManager.revision
        index_path = $Lock.boardManager.indexPath
        index_url = $Lock.boardManager.indexUrl
        index_sha256 = $Lock.boardManager.sha256
        gcc_package_version = $Lock.tools.armNoneEabiGcc.version
        gcc_compiler_version = $Lock.tools.armNoneEabiGcc.compilerVersion
    }

    foreach ($entry in $values.GetEnumerator()) {
        Add-Content -LiteralPath $Path -Value "$($entry.Key)=$($entry.Value)" -Encoding utf8
    }
}