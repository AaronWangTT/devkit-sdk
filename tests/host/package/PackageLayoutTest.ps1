#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')

function Assert-LayoutTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Write-LayoutFixtureFile {
    param([string]$Root, [string]$Path, [string]$Content)
    $target = Join-Path $Root $Path
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
    [IO.File]::WriteAllText($target, $Content, [Text.UTF8Encoding]::new($false))
}

function Save-LayoutFixtureManifest {
    param([string]$Root, [hashtable]$Manifest)
    Write-LayoutFixtureFile $Root 'platform/az3166/package-layout.json' ($Manifest | ConvertTo-Json -Depth 6)
}

function Assert-LayoutRejected {
    param([string]$Root, [string]$ExpectedMessage)
    $rejected = $false
    try {
        $null = Get-Az3166PackageLayout -RepositoryRoot $Root
    }
    catch {
        if ($_.Exception.Message -notlike $ExpectedMessage) {
            throw
        }
        $rejected = $true
    }
    Assert-LayoutTest $rejected "Invalid package layout was accepted: $ExpectedMessage"
}

$cases = [ordered]@{
    'checkout and revision map the same complete payload' = {
        param($root, $manifest)
        $null = Invoke-Az3166LayoutGit $root @('-c', 'core.autocrlf=false', 'add', '--', '.')
        $snapshot = (Invoke-Az3166LayoutGit $root @('write-tree')).Trim()
        $revision = Get-Az3166PackageLayout -RepositoryRoot $root -Revision $snapshot
        $working = Get-Az3166PackageLayout -RepositoryRoot $root
        Assert-LayoutTest ($revision.Files.Count -eq 6) 'Fixture payload count changed.'
        Assert-LayoutTest (@(Compare-Object -CaseSensitive $revision.Files.Destination $working.Files.Destination).Count -eq 0) 'Revision and checkout destinations differ.'
        $previousIndex = $env:GIT_INDEX_FILE
        $tree = New-Az3166PlatformTree -Layout $revision -RepositoryRoot $root
        Assert-LayoutTest ($env:GIT_INDEX_FILE -eq $previousIndex) 'Caller index environment was changed.'
        Assert-LayoutTest ((Invoke-Az3166LayoutGit $root @('write-tree')).Trim() -eq $snapshot) 'Caller Git index contents were changed.'
        $archiveFiles = Invoke-Az3166LayoutGit $root @('ls-tree', '-r', '--name-only', $tree)
        Assert-LayoutTest ($archiveFiles.Contains('libraries/Fixture/space name.h')) 'A destination containing spaces was lost.'
        $staging = Join-Path $root 'staged-platform'
        Copy-Az3166Platform -RepositoryRoot $root -Destination $staging
        foreach ($file in $working.Files) {
            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $root $file.Source)).Hash
            $stagedHash = (Get-FileHash -LiteralPath (Join-Path $staging $file.Destination)).Hash
            Assert-LayoutTest ($sourceHash -eq $stagedHash) "Staged contents differ: $($file.Destination)"
        }
        Write-LayoutFixtureFile $root 'payload/boards.txt' 'uncommitted board edit'
        $unchanged = Get-Az3166PackageLayout -RepositoryRoot $root -Revision $snapshot
        Assert-LayoutTest ((New-Az3166PlatformTree -Layout $unchanged -RepositoryRoot $root) -eq $tree) 'Revision packaging read uncommitted source content.'
        $refused = $false
        try { Copy-Az3166Platform -RepositoryRoot $root -Destination $staging }
        catch { $refused = $_.Exception.Message -like '*empty destination*' }
        Assert-LayoutTest $refused 'Staging overwrote a nonempty directory.'
    }
    'multiple Git installations select one executable' = {
        param($root, $manifest)
        $gitCommand = @(Get-Command git -CommandType Application -ErrorAction Stop)[0]
        $fakeName = if ($IsWindows) { 'git.exe' } else { 'git' }
        $fakeRelativePath = "duplicate-git/$fakeName"
        Write-LayoutFixtureFile $root $fakeRelativePath "#!/bin/sh`nexit 99`n"
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode((Join-Path $root $fakeRelativePath),
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        $previousPath = $env:PATH
        try {
            $env:PATH = @((Split-Path -Parent $gitCommand.Source), (Join-Path $root 'duplicate-git'), $previousPath) -join [IO.Path]::PathSeparator
            Assert-LayoutTest (@(Get-Command git -CommandType Application).Count -gt 1) 'The duplicate-Git fixture did not create multiple matches.'
            $null = Invoke-Az3166LayoutGit $root @('-c', 'core.autocrlf=false', 'add', '--', 'payload', 'platform')
            $snapshot = (Invoke-Az3166LayoutGit $root @('write-tree')).Trim()
            $layout = Get-Az3166PackageLayout -RepositoryRoot $root -Revision $snapshot
            $tree = New-Az3166PlatformTree -RepositoryRoot $root -Layout $layout
            Assert-LayoutTest ($tree -match '^[0-9a-f]{40,64}$') 'Git executable resolution failed to create a platform tree.'
        }
        finally {
            $env:PATH = $previousPath
        }
    }
    'missing mapped inputs are rejected' = {
        param($root, $manifest)
        $manifest.mappings += @{ source = 'payload/missing'; destination = 'missing' }
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Missing package input:*'
    }
    'unmapped files are rejected' = {
        param($root, $manifest)
        Write-LayoutFixtureFile $root 'payload/unmapped.h' 'unmapped'
        Assert-LayoutRejected $root 'Unmapped package inputs:*'
    }
    'duplicate source mappings are rejected' = {
        param($root, $manifest)
        $manifest.mappings += @{ source = 'payload/core'; destination = 'other-core' }
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Package input is mapped more than once:*'
    }
    'case-insensitive destination collisions are rejected' = {
        param($root, $manifest)
        $manifest.mappings[1].destination = 'BOARDS.txt'
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Duplicate package destination:*'
    }
    'file versus directory collisions are rejected' = {
        param($root, $manifest)
        $manifest.mappings[1].destination = 'boards.txt/platform.txt'
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Package file/directory collision:*'
    }
    'destination traversal is rejected' = {
        param($root, $manifest)
        $manifest.mappings[1].destination = '../platform.txt'
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Invalid package-layout path:*'
    }
    'overlapping payload roots are rejected' = {
        param($root, $manifest)
        $manifest.payloadRoots += 'payload/core'
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Overlapping package roots*'
    }
    'unsupported schema versions are rejected' = {
        param($root, $manifest)
        $manifest.schemaVersion = 2
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Unsupported package-layout schema version:*'
    }
    'excluded required platform files are rejected' = {
        param($root, $manifest)
        $manifest.exclude = @('payload/programmers.txt')
        $manifest.mappings = @($manifest.mappings | Where-Object { $_.source -ne 'payload/programmers.txt' })
        Save-LayoutFixtureManifest $root $manifest
        Assert-LayoutRejected $root 'Missing required package file: programmers.txt'
    }
}

foreach ($case in $cases.GetEnumerator()) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) "az3166-layout-test-$([guid]::NewGuid().ToString('N'))"
    try {
        $null = New-Item -ItemType Directory -Path $fixture
        $null = Invoke-Az3166LayoutGit $fixture @('init', '--quiet')
        foreach ($path in @('boards.txt', 'platform.txt', 'programmers.txt', 'core/Arduino.h', 'core/system/SystemVersion.h', 'lib/space name.h')) {
            Write-LayoutFixtureFile $fixture "payload/$path" "fixture contents: $path`n"
        }
        $manifest = @{
            schemaVersion = 1
            payloadRoots = @('payload')
            exclude = @()
            mappings = @(
                @{ source = 'payload/boards.txt'; destination = 'boards.txt' }
                @{ source = 'payload/platform.txt'; destination = 'platform.txt' }
                @{ source = 'payload/programmers.txt'; destination = 'programmers.txt' }
                @{ source = 'payload/core'; destination = 'cores/arduino' }
                @{ source = 'payload/lib'; destination = 'libraries/Fixture' }
            )
        }
        Save-LayoutFixtureManifest $fixture $manifest
        & $case.Value $fixture $manifest
        Write-Host "PASS $($case.Key)"
    }
    finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "$($cases.Count) package-layout tests passed."