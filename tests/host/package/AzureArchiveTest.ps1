#requires -Version 7.0

[CmdletBinding()]
param([string]$Ar = 'ar', [string]$Nm = 'nm')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$splitter = Join-Path $repositoryRoot 'tools/build/Split-Az3166CoreArchive.ps1'
$manifestPath = Join-Path $repositoryRoot 'tools/build/az3166-azure-archive.json'
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) "az3166-archive-$([guid]::NewGuid().ToString('N'))"
$initialHash = (Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'vendor/prebuilt/az3166/libdevkit-sdk-core-lib.a')).Hash

function Assert-ArchiveTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-PartitionRejected {
    param([string]$Name, [scriptblock]$Change, [string]$Expected)
    $fixture = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    & $Change $fixture
    $fixturePath = Join-Path $root "$Name.json"
    $fixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixturePath -Encoding utf8
    $rejected = $false
    try {
        $null = & $splitter -ManifestPath $fixturePath -OutputDirectory (Join-Path $root $Name) -Ar $Ar -Nm $Nm
    }
    catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        $rejected = $true
    }
    Assert-ArchiveTest $rejected "Invalid partition was accepted: $Name"
    Write-Host "PASS $Name rejected"
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $first = & $splitter -OutputDirectory (Join-Path $root 'first') -Ar $Ar -Nm $Nm
    $second = & $splitter -OutputDirectory (Join-Path $root 'second') -Ar $Ar -Nm $Nm
    foreach ($profile in @('base', 'azure')) {
        Assert-ArchiveTest ($first.archives[$profile].sha256 -ceq $second.archives[$profile].sha256) "Nondeterministic $profile archive."
        Assert-ArchiveTest ($first.archives[$profile].bytes -eq $second.archives[$profile].bytes) "Changed $profile archive size."
    }
    Assert-ArchiveTest ($first.members.Count -eq 473) 'Original object occurrences were lost.'
    Assert-ArchiveTest ($first.archives.base.members -eq 363 -and $first.archives.azure.members -eq 110) 'Unexpected partition inventory.'
    Assert-ArchiveTest ($first.baseRequiresAzure.Count -eq 0 -and $first.conflictingDefinitions.Count -eq 0) 'Invalid binary dependency boundary.'
    Assert-ArchiveTest ($first.azureRequiresBase.Count -gt 0) 'Azure-to-base dependency evidence is missing.'
    foreach ($name in @('certs.o', 'sha1.o', 'version.o')) {
        $instances = @($first.members | Where-Object { $_.name -ceq $name } | Sort-Object occurrence)
        Assert-ArchiveTest ($instances.Count -eq 2) "Duplicate instance lost: $name"
        Assert-ArchiveTest ($instances[0].partition -eq 'azure' -and $instances[1].partition -eq 'base') "Wrong duplicate owner: $name"
        Assert-ArchiveTest ($instances[0].sha256 -cne $instances[1].sha256) "Duplicate objects overwritten: $name"
    }
    Write-Host 'PASS repeated archives, complete object accounting, duplicate occurrences, and symbol closure'

    Assert-PartitionRejected 'wrong-hash' { param($fixture) $fixture.sha256 = '0' * 64 } '*SHA-256 does not match*'
    Assert-PartitionRejected 'duplicate-id' { param($fixture) $fixture.azureMembers += $fixture.azureMembers[0] } '*duplicate Azure member identity*'
    Assert-PartitionRejected 'unknown-member' { param($fixture) $fixture.azureMembers += 'nonexistent.o#1' } '*Unknown Azure archive member*'
    Assert-PartitionRejected 'unsafe-member' { param($fixture) $fixture.azureMembers += '../unsafe.o#1' } '*Invalid or duplicate Azure member identity*'
    Assert-PartitionRejected 'wrong-count' { param($fixture) $fixture.memberCount = 472 } '*member count differs*'
    Assert-PartitionRejected 'azure-left-in-base' {
        param($fixture)
        $fixture.azureMembers = @($fixture.azureMembers | Where-Object { $_ -cne 'iothub_client_ll.o#1' })
    } '*Base archive requires Azure symbols*'

    $rejected = $false
    try { $null = & $splitter -OutputDirectory (Join-Path $root 'first') -Ar $Ar -Nm $Nm }
    catch {
        if ($_.Exception.Message -notlike '*output directory must be empty*') { throw }
        $rejected = $true
    }
    Assert-ArchiveTest $rejected 'Existing evidence was overwritten.'
    Assert-ArchiveTest ((Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'vendor/prebuilt/az3166/libdevkit-sdk-core-lib.a')).Hash -ceq $initialHash) 'Original archive changed.'
    Write-Host 'PASS existing output and original archive are protected'

    $fixtureRepository = Join-Path $root 'repository'
    $null = New-Item -ItemType Directory -Path "$fixtureRepository/payload", "$fixtureRepository/tools/build", "$fixtureRepository/platform/az3166" -Force
    $null = Invoke-Az3166LayoutGit $fixtureRepository @('init', '--quiet')
    $mappings = @()
    foreach ($destination in @('boards.txt', 'platform.txt', 'programmers.txt', 'cores/arduino/Arduino.h', 'cores/arduino/system/SystemVersion.h')) {
        $source = 'payload/' + [IO.Path]::GetFileName($destination)
        [IO.File]::WriteAllText((Join-Path $fixtureRepository $source), "fixture $destination`n")
        $mappings += @{ source = $source; destination = $destination }
    }
    $partition = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    $partition.source = 'payload/original.a'
    $partition | ConvertTo-Json -Depth 6 | Set-Content "$fixtureRepository/tools/build/az3166-azure-archive.json" -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'vendor/prebuilt/az3166/libdevkit-sdk-core-lib.a') -Destination "$fixtureRepository/payload/original.a"
    Copy-Item -LiteralPath $splitter -Destination "$fixtureRepository/tools/build/Split-Az3166CoreArchive.ps1"
    @{
        schemaVersion = 2
        defaultProfile = 'base'
        archivePartition = 'tools/build/az3166-azure-archive.json'
        payloadRoots = @('payload')
        exclude = @('payload/original.a')
        mappings = $mappings
    } | ConvertTo-Json -Depth 6 | Set-Content "$fixtureRepository/platform/az3166/package-layout.json" -Encoding utf8
    $null = Invoke-Az3166LayoutGit $fixtureRepository @('-c', 'core.autocrlf=false', 'add', '--', '.')
    $snapshot = (Invoke-Az3166LayoutGit $fixtureRepository @('write-tree')).Trim()
    $trees = @{}
    foreach ($profile in @('base', 'azure-iot')) {
        $layout = Get-Az3166PackageLayout -RepositoryRoot $fixtureRepository -Revision $snapshot -Profile $profile
        $trees[$profile] = New-Az3166PlatformTree -Layout $layout -RepositoryRoot $fixtureRepository -Ar $Ar -Nm $Nm
        $files = (Invoke-Az3166LayoutGit $fixtureRepository @('ls-tree', '-r', '--name-only', $trees[$profile])) -split "`n"
        Assert-ArchiveTest ('package-profile.json' -cin $files -and 'system/libdevkit-sdk-base.a' -cin $files) 'Generated base archive or profile metadata was omitted.'
        Assert-ArchiveTest (('system/libdevkit-sdk-azure.a' -cin $files) -eq ($profile -eq 'azure-iot')) 'Generated Azure archive has incorrect profile membership.'
        Assert-ArchiveTest ('payload/original.a' -cnotin $files) 'Original archive leaked into generated tree.'
        $metadata = Invoke-Az3166LayoutGit $fixtureRepository @('show', "$($trees[$profile]):package-profile.json") | ConvertFrom-Json
        Assert-ArchiveTest ($metadata.profile -ceq $profile -and $metadata.sourceRevision -ceq $snapshot) 'Generated profile provenance is wrong.'
    }
    [IO.File]::WriteAllText("$fixtureRepository/tools/build/Split-Az3166CoreArchive.ps1", 'throw "Uncommitted splitter must never run"')
    [IO.File]::WriteAllText("$fixtureRepository/payload/original.a", 'Uncommitted archive must never be read')
    [IO.File]::WriteAllText("$fixtureRepository/tools/build/az3166-azure-archive.json", '{}')
    foreach ($profile in @('base', 'azure-iot')) {
        $layout = Get-Az3166PackageLayout -RepositoryRoot $fixtureRepository -Revision $snapshot -Profile $profile
        $repeated = New-Az3166PlatformTree -Layout $layout -RepositoryRoot $fixtureRepository -Ar $Ar -Nm $Nm
        Assert-ArchiveTest ($repeated -ceq $trees[$profile]) 'Revision packaging consumed uncommitted splitter, input, or partition data.'
    }
    Assert-ArchiveTest ((Invoke-Az3166LayoutGit $fixtureRepository @('write-tree')).Trim() -ceq $snapshot) 'Revision generation changed the caller index.'
    Write-Host 'PASS generated profile trees use immutable inputs and preserve the caller index'
    Write-Host '9 archive partition and packaging contracts passed.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}