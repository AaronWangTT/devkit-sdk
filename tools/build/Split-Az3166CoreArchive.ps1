#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Ar = 'ar',
    [string]$Nm = 'nm',
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'az3166-azure-archive.json'),
    [string]$InputArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json -AsHashtable
if ($manifest.schemaVersion -ne 1 -or $manifest.memberCount -le 0 -or
    $manifest.sha256 -notmatch '^[0-9a-f]{64}$' -or
    $manifest.azureMembers -isnot [array] -or $manifest.azureMembers.Count -eq 0) {
    throw 'Invalid archive partition manifest.'
}
if (-not $InputArchive) { $InputArchive = Join-Path $repositoryRoot $manifest.source }
$inputPath = (Resolve-Path -LiteralPath $InputArchive).Path
$sourceHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -cne $manifest.sha256) { throw 'Archive SHA-256 does not match the pinned input.' }
$azureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($identity in $manifest.azureMembers) {
    if ($identity -isnot [string] -or $identity -notmatch '^[A-Za-z0-9_.+-]+\.o#[1-9][0-9]*$' -or
        -not $azureIds.Add($identity)) { throw "Invalid or duplicate Azure member identity: $identity" }
}
$archiver = @(Get-Command $Ar -CommandType Application -ErrorAction Stop)[0].Source
$symbolTool = @(Get-Command $Nm -CommandType Application -ErrorAction Stop)[0].Source
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $outputRoot) -and
    (-not (Test-Path -LiteralPath $outputRoot -PathType Container) -or
        @(Get-ChildItem -LiteralPath $outputRoot -Force).Count -gt 0)) {
    throw 'Archive output directory must be empty.'
}

function Invoke-ArchiveTool {
    param([string]$Tool, [string[]]$Arguments)
    $output = @(& $Tool @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Archive tool failed: $Tool $($Arguments -join ' ')" }
    return $output
}

function Read-ArchiveMembers {
    param([string]$Archive, [string]$Directory)
    $names = @(Invoke-ArchiveTool $archiver @('t', $Archive))
    $totals = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($name in $names) {
        if ($name -notmatch '^[A-Za-z0-9_.+-]+\.o$') { throw "Unsupported archive member name: $name" }
        if (-not $totals.ContainsKey($name)) { $totals.Add($name, 0) }
        $totals[$name]++
    }
    $unpacked = Join-Path $Directory 'unpacked'
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    $occurrences = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    Push-Location -LiteralPath $unpacked
    try {
        $null = Invoke-ArchiveTool $archiver @('x', $Archive)
        $index = 0
        foreach ($name in $names) {
            ++$index
            if (-not $occurrences.ContainsKey($name)) { $occurrences.Add($name, 0) }
            $occurrence = ++$occurrences[$name]
            if ($totals[$name] -gt 1) {
                $null = Invoke-ArchiveTool $archiver @('xN', [string]$occurrence, $Archive, $name)
            }
            $memberDirectory = Join-Path $Directory ([string]$index)
            New-Item -ItemType Directory -Path $memberDirectory -Force | Out-Null
            $memberPath = Join-Path $memberDirectory $name
            Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination $memberPath
            [pscustomobject]@{
                Index = $index
                Name = $name
                Occurrence = $occurrence
                Identity = "$name#$occurrence"
                Path = $memberPath
                Bytes = (Get-Item -LiteralPath $memberPath).Length
                SHA256 = (Get-FileHash -LiteralPath $memberPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    finally { Pop-Location }
}

function Get-ArchiveSymbols {
    param([string]$Archive)
    $defined = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $strong = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $undefined = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in @(Invoke-ArchiveTool $symbolTool @('-g', '-P', $Archive))) {
        if ($line -match '^(\S+)\s+([A-Za-z?])(?:\s|$)') {
            $symbol = $Matches[1]
            $kind = $Matches[2]
            if ($kind -ceq 'U') { $null = $undefined.Add($symbol) }
            elseif ($kind -cnotin @('w', 'v')) {
                $null = $defined.Add($symbol)
                if ($kind -cnotin @('W', 'V')) { $null = $strong.Add($symbol) }
            }
        }
    }
    if ($defined.Count -eq 0) { throw "No defined symbols were read from $Archive." }
    return @{ Defined = $defined; Strong = $strong; Undefined = $undefined }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$work = Join-Path $outputRoot '.work'
try {
    $members = @(Read-ArchiveMembers $inputPath (Join-Path $work 'source'))
    if ($members.Count -ne $manifest.memberCount) { throw 'Archive member count differs from the manifest.' }
    $allIds = [Collections.Generic.HashSet[string]]::new([string[]]$members.Identity, [StringComparer]::Ordinal)
    foreach ($identity in $azureIds) {
        if (-not $allIds.Contains($identity)) { throw "Unknown Azure archive member: $identity" }
    }
    $archives = [ordered]@{}
    $symbols = @{}
    $records = @()
    foreach ($profile in @('base', 'azure')) {
        $selected = @($members | Where-Object { $azureIds.Contains($_.Identity) -eq ($profile -eq 'azure') })
        if ($selected.Count -eq 0) { throw "Empty $profile archive partition." }
        $archivePath = Join-Path $outputRoot "libdevkit-sdk-$profile.a"
        for ($offset = 0; $offset -lt $selected.Count; $offset += 32) {
            $last = [Math]::Min($offset + 31, $selected.Count - 1)
            $null = Invoke-ArchiveTool $archiver (@('qcD', $archivePath) + @($selected[$offset..$last].Path))
        }
        $null = Invoke-ArchiveTool $archiver @('sD', $archivePath)
        $repacked = @(Read-ArchiveMembers $archivePath (Join-Path $work $profile))
        if ($repacked.Count -ne $selected.Count) { throw "Lost or duplicated members in $profile." }
        for ($index = 0; $index -lt $selected.Count; ++$index) {
            if ($repacked[$index].Name -cne $selected[$index].Name -or
                $repacked[$index].SHA256 -cne $selected[$index].SHA256) {
                throw "Repacked object differs from its original occurrence: $($selected[$index].Identity)"
            }
            $records += [ordered]@{
                index = $selected[$index].Index
                name = $selected[$index].Name
                occurrence = $selected[$index].Occurrence
                partition = $profile
                bytes = $selected[$index].Bytes
                sha256 = $selected[$index].SHA256
            }
        }
        $archives[$profile] = [ordered]@{
            file = Split-Path -Leaf $archivePath
            members = $selected.Count
            bytes = (Get-Item -LiteralPath $archivePath).Length
            sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $symbols[$profile] = Get-ArchiveSymbols $archivePath
    }
    $baseRequiresAzure = @($symbols.base.Undefined | Where-Object {
        -not $symbols.base.Defined.Contains($_) -and $symbols.azure.Defined.Contains($_)
    } | Sort-Object -CaseSensitive)
    $sharedDefinitions = @($symbols.base.Defined | Where-Object { $symbols.azure.Defined.Contains($_) } | Sort-Object -CaseSensitive)
    $conflictingDefinitions = @($sharedDefinitions | Where-Object {
        $symbols.base.Strong.Contains($_) -or $symbols.azure.Strong.Contains($_)
    })
    $report = [ordered]@{
        schemaVersion = 1
        source = $manifest.source
        sourceSha256 = $sourceHash
        manifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        provenance = $manifest.provenance
        archiver = @(Invoke-ArchiveTool $archiver @('--version'))[0]
        archives = $archives
        baseRequiresAzure = $baseRequiresAzure
        sharedDefinitions = $sharedDefinitions
        conflictingDefinitions = $conflictingDefinitions
        azureRequiresBase = @($symbols.azure.Undefined | Where-Object {
            -not $symbols.azure.Defined.Contains($_) -and $symbols.base.Defined.Contains($_)
        } | Sort-Object -CaseSensitive)
        members = @($records | Sort-Object index)
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot 'partition.json') -Encoding utf8
    if ($baseRequiresAzure.Count -gt 0) { throw "Base archive requires Azure symbols: $($baseRequiresAzure -join ', ')" }
    if ($conflictingDefinitions.Count -gt 0) { throw "Cross-partition strong symbol definitions require review: $($conflictingDefinitions -join ', ')" }
    if ((Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant() -cne $sourceHash) { throw 'Input archive changed during partitioning.' }
    Write-Host "PASS $($members.Count) original member occurrences preserved; base=$($archives.base.members), azure=$($archives.azure.members); no base-to-Azure imports."
    [pscustomobject]$report
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}