#requires -Version 7.0

. (Join-Path $PSScriptRoot 'Az3166PackageProfiles.ps1')

function Get-Az3166CoreVersion {
    param([string]$HeaderContent, [string]$Source)

    $components = foreach ($name in @('DEVKIT_MAJOR_VERSION', 'DEVKIT_MINOR_VERSION', 'DEVKIT_PATCH_VERSION')) {
        $match = [regex]::Match($HeaderContent, "(?m)^\s*#define\s+$name\s+([0-9]+)\s*$")
        if (-not $match.Success) {
            throw "$Source does not define a numeric $name."
        }
        [int]$match.Groups[1].Value
    }
    return $components -join '.'
}

function Invoke-Az3166LayoutGit {
    param(
        [string]$RepositoryRoot,
        [string[]]$GitArguments
    )

    $output = & git -C $RepositoryRoot @GitArguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArguments -join ' ') failed."
    }
    return ($output -join "`n")
}

function Assert-Az3166LayoutPath {
    param(
        [string]$Path,
        [switch]$AllowRoot
    )

    if ($AllowRoot -and $Path -eq '.') {
        return
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -match '(^/|[\\:\x00-\x1f]|(^|/)\.\.?(/|$)|//|/$)') {
        throw "Invalid package-layout path: '$Path'. Use repository-relative paths with forward slashes."
    }
}

function Test-Az3166LayoutContains {
    param([string]$Root, [string]$Path)

    return $Path -ceq $Root -or $Path.StartsWith("$Root/", [StringComparison]::Ordinal)
}

function Get-Az3166PackageLayout {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
        [string]$Revision,
        [string]$Profile
    )

    $manifestPath = 'platform/az3166/package-layout.json'
    $inventory = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($Revision) {
        $records = Invoke-Az3166LayoutGit $RepositoryRoot @('ls-tree', '-r', '-z', '--full-tree', $Revision)
        foreach ($record in $records.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($record -notmatch '^(?<mode>[0-7]{6}) (?<type>\w+) (?<object>[0-9a-f]+)\t(?<path>.+)$') {
                throw 'Unexpected Git tree record while reading the package layout.'
            }
            $inventory.Add($Matches.path, [pscustomobject]@{
                Mode = $Matches.mode
                Type = $Matches.type
                ObjectId = $Matches.object
            })
        }
    }
    else {
        $records = Invoke-Az3166LayoutGit $RepositoryRoot @('ls-files', '-z', '--cached', '--others', '--exclude-standard')
        foreach ($path in $records.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            if (-not $inventory.ContainsKey($path)) {
                $inventory.Add($path, $null)
            }
        }
    }

    if ($Revision -and $inventory.ContainsKey($manifestPath)) {
        $manifestText = Invoke-Az3166LayoutGit $RepositoryRoot @('show', "${Revision}:$manifestPath")
    }
    elseif (-not $Revision -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot $manifestPath) -PathType Leaf)) {
        $manifestText = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $manifestPath)
    }
    else {
        $manifestText = $null
    }

    if ($manifestText) {
        $manifest = $manifestText | ConvertFrom-Json -AsHashtable
        foreach ($key in @('schemaVersion', 'payloadRoots', 'exclude', 'mappings')) {
            if (-not $manifest.ContainsKey($key)) {
                throw "Package layout is missing '$key'."
            }
        }
        if ($manifest.schemaVersion -notin @(1, 2)) {
            throw "Unsupported package-layout schema version: $($manifest.schemaVersion)"
        }
    }
    else {
        $source = if ($inventory.ContainsKey('src/boards.txt')) { 'src' } else { 'AZ3166/src' }
        if (-not $inventory.ContainsKey("$source/cores/arduino/system/SystemVersion.h")) {
            throw 'No package layout or recognized historical platform was found.'
        }
        $manifest = @{
            schemaVersion = 1
            payloadRoots = @($source)
            exclude = @()
            mappings = @(@{ source = $source; destination = '.' })
        }
        if (@($inventory.Keys | Where-Object { $_.StartsWith('libraries/', [StringComparison]::Ordinal) }).Count -gt 0) {
            $manifest.payloadRoots += 'libraries'
            $manifest.mappings += @{ source = 'libraries'; destination = 'libraries' }
        }
    }

    $supportedProfiles = @('base', 'azure-iot')
    if ($manifest.schemaVersion -eq 2) {
        if (-not $manifest.ContainsKey('defaultProfile') -or $manifest.defaultProfile -cnotin $supportedProfiles) {
            throw 'Profile-aware package layouts require a valid defaultProfile.'
        }
        if (-not $Profile) { $Profile = $manifest.defaultProfile }
    }
    else {
        if ($Profile -and $Profile -cne 'azure-iot') { throw 'Historical layouts support only the azure-iot profile.' }
        $Profile = 'azure-iot'
    }
    if ($Profile -cnotin $supportedProfiles) { throw "Unknown package profile: $Profile" }

    $archiveInputs = @()
    $archivePartition = $null
    if ($manifest.schemaVersion -eq 2 -and $manifest.ContainsKey('archivePartition')) {
        $archivePartition = $manifest.archivePartition
        Assert-Az3166LayoutPath $archivePartition
        $partitionText = if ($Revision) {
            Invoke-Az3166LayoutGit $RepositoryRoot @('show', "${Revision}:$archivePartition")
        } else { Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot $archivePartition) }
        $partition = $partitionText | ConvertFrom-Json
        Assert-Az3166LayoutPath $partition.source
        if ($manifest.exclude -cnotcontains $partition.source) { throw 'The original archive must be excluded from profile payloads.' }
        $archiveInputs = @($archivePartition, $partition.source, 'tools/build/Split-Az3166CoreArchive.ps1')
        if ($inventory.ContainsKey('tools/build/Az3166Symbols.ps1')) { $archiveInputs += 'tools/build/Az3166Symbols.ps1' }
        foreach ($inputFile in $archiveInputs) {
            if (-not $inventory.ContainsKey($inputFile)) { throw "Missing archive generation input: $inputFile" }
            if ($Revision) {
                $entry = $inventory[$inputFile]
                if ($entry.Type -ne 'blob' -or $entry.Mode -notin @('100644', '100755')) { throw "Invalid archive generation input: $inputFile" }
            }
            else {
                $item = Get-Item -LiteralPath (Join-Path $RepositoryRoot $inputFile) -Force -ErrorAction Stop
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Invalid archive generation input: $inputFile" }
            }
        }
    }

    if ($manifest.payloadRoots -isnot [array] -or $manifest.payloadRoots.Count -eq 0 -or
        $manifest.exclude -isnot [array] -or $manifest.mappings -isnot [array] -or $manifest.mappings.Count -eq 0) {
        throw 'Package-layout roots, exclusions, and mappings must be arrays; roots and mappings cannot be empty.'
    }
    foreach ($path in @($manifest.payloadRoots) + @($manifest.exclude)) {
        Assert-Az3166LayoutPath $path
    }
    foreach ($mapping in $manifest.mappings) {
        if ($mapping -isnot [System.Collections.IDictionary] -or
            -not $mapping.Contains('source') -or -not $mapping.Contains('destination')) {
            throw 'Each package mapping must declare source and destination paths.'
        }
        Assert-Az3166LayoutPath $mapping.source
        Assert-Az3166LayoutPath $mapping.destination -AllowRoot
        if ($mapping.Contains('profiles')) {
            if ($manifest.schemaVersion -ne 2 -or $mapping.profiles -isnot [array] -or $mapping.profiles.Count -eq 0 -or
                @($mapping.profiles | Where-Object { $_ -cnotin $supportedProfiles }).Count -gt 0 -or
                @($mapping.profiles | Select-Object -Unique).Count -ne $mapping.profiles.Count) {
                throw "Invalid mapping profiles: $($mapping.source)"
            }
        }
    }

    $inputs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($root in $manifest.payloadRoots) {
        foreach ($path in $inventory.Keys) {
            if ((Test-Az3166LayoutContains $root $path) -and $manifest.exclude -cnotcontains $path) {
                if (-not $inputs.Add($path)) {
                    throw "Overlapping package roots include '$path' more than once."
                }
            }
        }
    }
    $mappedInputs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $destinations = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($mapping in $manifest.mappings) {
        $selected = -not $mapping.Contains('profiles') -or $Profile -cin $mapping.profiles
        $matches = @($inputs | Where-Object { Test-Az3166LayoutContains $mapping.source $_ })
        if ($matches.Count -eq 0) {
            throw "Missing package input: $($mapping.source)"
        }
        foreach ($source in $matches) {
            if (-not $mappedInputs.Add($source)) {
                throw "Package input is mapped more than once: $source"
            }
            $entry = $inventory[$source]
            if ($Revision) {
                if ($entry.Type -ne 'blob' -or $entry.Mode -notin @('100644', '100755')) {
                    throw "Unsupported package input type: $source"
                }
            }
            else {
                $item = Get-Item -LiteralPath (Join-Path $RepositoryRoot $source) -Force -ErrorAction Stop
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Package input must be a regular file: $source"
                }
            }
            if (-not $selected) { continue }
            $suffix = $source.Substring($mapping.source.Length).TrimStart('/')
            $destination = if ($mapping.destination -eq '.') { $suffix } elseif ($suffix) {
                "$($mapping.destination)/$suffix"
            } else { $mapping.destination }
            Assert-Az3166LayoutPath $destination
            if ($directories.Contains($destination) -or -not $destinations.Add($destination)) {
                throw "Duplicate package destination: $destination"
            }
            $parent = $destination
            while ($parent.Contains('/')) {
                $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
                if ($destinations.Contains($parent)) {
                    throw "Package file/directory collision: $parent"
                }
                $null = $directories.Add($parent)
            }
            $files.Add([pscustomobject]@{
                Source = $source
                Destination = $destination
                Mode = if ($Revision) { $entry.Mode } else { $null }
                ObjectId = if ($Revision) { $entry.ObjectId } else { $null }
            })
        }
    }
    $unmapped = @($inputs | Where-Object { -not $mappedInputs.Contains($_) })
    if ($unmapped.Count -gt 0) {
        throw "Unmapped package inputs: $($unmapped -join ', ')"
    }
    foreach ($required in @('boards.txt', 'platform.txt', 'programmers.txt', 'cores/arduino/Arduino.h', 'cores/arduino/system/SystemVersion.h')) {
        if (-not @($files | Where-Object { $_.Destination -ceq $required }).Count) {
            throw "Missing required package file: $required"
        }
    }
    if ($archiveInputs.Count -gt 0) {
        foreach ($generated in @('package-profile.json', 'system/libdevkit-sdk-base.a', 'system/libdevkit-sdk-azure.a')) {
            if ($destinations.Contains($generated) -or $directories.Contains($generated)) {
                throw "Reserved generated package destination: $generated"
            }
        }
    }
    return [pscustomobject]@{
        Files = @($files | Sort-Object Destination -CaseSensitive)
        Revision = $Revision
        Profile = $Profile
        SchemaVersion = $manifest.schemaVersion
        ArchiveInputs = $archiveInputs
        ArchivePartition = $archivePartition
    }
}

function New-Az3166PlatformTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
        [string]$Ar = 'ar',
        [string]$Nm = 'nm'
    )

    if (-not $Layout.Revision) {
        throw 'Git-tree assembly requires a revision-backed package layout.'
    }
    $previousIndex = $env:GIT_INDEX_FILE
    $temporaryIndex = Join-Path ([IO.Path]::GetTempPath()) "az3166-layout-$([guid]::NewGuid().ToString('N')).index"
    $generatedRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166-generated-$([guid]::NewGuid().ToString('N'))"
    try {
        $generatedRecords = @()
        if ($Layout.ArchiveInputs.Count -gt 0) {
            Add-Az3166ProfileArtifacts $Layout $RepositoryRoot $generatedRoot $Ar $Nm
            $generatedRecords = @(Get-ChildItem -LiteralPath $generatedRoot -Recurse -File | ForEach-Object {
                $objectId = (Invoke-Az3166LayoutGit $RepositoryRoot @('hash-object', '-w', '--no-filters', '--', $_.FullName)).Trim()
                $destination = [IO.Path]::GetRelativePath($generatedRoot, $_.FullName).Replace('\', '/')
                "100644 $objectId`t$destination"
            })
        }
        $env:GIT_INDEX_FILE = $temporaryIndex
        $null = Invoke-Az3166LayoutGit $RepositoryRoot @('read-tree', '--empty')
        $records = @($Layout.Files | ForEach-Object { "$($_.Mode) $($_.ObjectId)`t$($_.Destination)" }) + $generatedRecords
        $process = [Diagnostics.Process]::new()
        try {
            $process.StartInfo.FileName = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.RedirectStandardInput = $true
            $process.StartInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
            foreach ($argument in @('-C', $RepositoryRoot, 'update-index', '-z', '--index-info')) {
                $process.StartInfo.ArgumentList.Add($argument)
            }
            $null = $process.Start()
            $process.StandardInput.Write(($records -join "`0") + "`0")
            $process.StandardInput.Close()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw 'Could not assemble the mapped platform index.'
            }
        }
        finally {
            $process.Dispose()
        }
        return (Invoke-Az3166LayoutGit $RepositoryRoot @('write-tree')).Trim()
    }
    finally {
        $env:GIT_INDEX_FILE = $previousIndex
        Remove-Item -LiteralPath $temporaryIndex, "$temporaryIndex.lock" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-Az3166Platform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
        [string]$Revision,
        [string]$Profile,
        [string]$Ar = 'ar',
        [string]$Nm = 'nm'
    )

    $layout = Get-Az3166PackageLayout -RepositoryRoot $RepositoryRoot -Revision $Revision -Profile $Profile
    if ((Test-Path -LiteralPath $Destination) -and
        (-not (Test-Path -LiteralPath $Destination -PathType Container) -or
            @((Get-ChildItem -LiteralPath $Destination -Force)).Count -gt 0)) {
        throw "Platform staging requires an empty destination: $Destination"
    }
    foreach ($file in $layout.Files) {
        $target = Join-Path $Destination $file.Destination
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        if ($Revision) { Export-Az3166RevisionFile $RepositoryRoot $Revision $file.Source $target }
        else { Copy-Item -LiteralPath (Join-Path $RepositoryRoot $file.Source) -Destination $target }
    }
    Add-Az3166ProfileArtifacts $layout $RepositoryRoot $Destination $Ar $Nm
    if ($layout.ArchiveInputs.Count -gt 0) { Assert-Az3166PackagedProfile $Destination $layout.Profile $Revision }
}