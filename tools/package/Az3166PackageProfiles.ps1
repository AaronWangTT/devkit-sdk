#requires -Version 7.0

. (Join-Path $PSScriptRoot '../build/Az3166Symbols.ps1')

function Get-Az3166DefinedSymbols {
    param([string]$Path, [string]$Nm)

    $definitions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $lines = @(& $Nm '-g' '-A' '-P' '--defined-only' $Path)
    if ($LASTEXITCODE -ne 0) { throw "Cannot read defined symbols: $Path" }
    foreach ($record in @(ConvertFrom-Az3166NmOutput -Lines $lines)) {
        if ($record.Type -cnotin @('U', 'w', 'v')) { $null = $definitions.Add($record.Name) }
    }
    if ($definitions.Count -eq 0) { throw "Empty symbol inventory: $Path" }
    return ,$definitions
}

function Export-Az3166RevisionFile {
    param([string]$RepositoryRoot, [string]$Revision, [string]$Source, [string]$Destination)

    $process = [Diagnostics.Process]::new()
    $stream = $null
    try {
        $process.StartInfo.FileName = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        foreach ($argument in @('-C', $RepositoryRoot, 'cat-file', 'blob', "${Revision}:$Source")) {
            $process.StartInfo.ArgumentList.Add($argument)
        }
        $null = $process.Start()
        $errorText = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::Create($Destination)
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Cannot read committed file ${Source}: $($errorText.GetAwaiter().GetResult())" }
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $process.Dispose()
    }
}

function Add-Az3166ProfileArtifacts {
    param($Layout, [string]$RepositoryRoot, [string]$Destination, [string]$Ar, [string]$Nm)

    if ($Layout.ArchiveInputs.Count -eq 0) { return }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166-profile-$([guid]::NewGuid().ToString('N'))"
    try {
        foreach ($inputFile in $Layout.ArchiveInputs) {
            $target = Join-Path $temporaryRoot $inputFile
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            if ($Layout.Revision) {
                Export-Az3166RevisionFile $RepositoryRoot $Layout.Revision $inputFile $target
            }
            else { Copy-Item -LiteralPath (Join-Path $RepositoryRoot $inputFile) -Destination $target }
        }
        $partitionPath = Join-Path $temporaryRoot $Layout.ArchivePartition
        $partition = Get-Content -Raw -LiteralPath $partitionPath | ConvertFrom-Json
        $splitRoot = Join-Path $temporaryRoot 'split'
        $report = & (Join-Path $temporaryRoot 'tools/build/Split-Az3166CoreArchive.ps1') `
            -ManifestPath $partitionPath -InputArchive (Join-Path $temporaryRoot $partition.source) `
            -OutputDirectory $splitRoot -Ar $Ar -Nm $Nm
        $selectedArchives = [ordered]@{}
        foreach ($component in @('base', 'azure')) {
            if ($component -eq 'azure' -and $Layout.Profile -eq 'base') { continue }
            $archive = $report.archives[$component]
            $target = Join-Path $Destination "system/$($archive.file)"
            if (Test-Path -LiteralPath $target) { throw "Generated archive destination already exists: $target" }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            Copy-Item -LiteralPath (Join-Path $splitRoot $archive.file) -Destination $target
            $selectedArchives[$component] = $archive
        }
        $metadata = [ordered]@{
            schemaVersion = 1
            profile = $Layout.Profile
            sourceRevision = $Layout.Revision
            archiveSourceSha256 = $report.sourceSha256
            partitionManifestSha256 = $report.manifestSha256
            archives = $selectedArchives
        }
        $metadataPath = Join-Path $Destination 'package-profile.json'
        if (Test-Path -LiteralPath $metadataPath) { throw 'Generated profile metadata destination already exists.' }
        $json = ($metadata | ConvertTo-Json -Depth 6).Replace("`r`n", "`n") + "`n"
        [IO.File]::WriteAllText($metadataPath, $json, [Text.UTF8Encoding]::new($false))
    }
    finally { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Assert-Az3166PackagedProfile {
    param([string]$PlatformDirectory, [string]$Profile, [string]$Revision)

    $metadata = Get-Content -Raw -LiteralPath (Join-Path $PlatformDirectory 'package-profile.json') | ConvertFrom-Json
    if ($metadata.schemaVersion -ne 1 -or $metadata.profile -cne $Profile -or
        ($Revision -and $metadata.sourceRevision -cne $Revision)) { throw 'Packaged profile or revision does not match the request.' }
    foreach ($component in @('base', 'azure')) {
        $path = Join-Path $PlatformDirectory "system/libdevkit-sdk-$component.a"
        if ($component -eq 'azure' -and $Profile -eq 'base') {
            if (Test-Path -LiteralPath $path) { throw 'Base package contains the Azure archive.' }
        }
        else {
            if (-not $metadata.archives.PSObject.Properties[$component] -or
                (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $metadata.archives.$component.sha256) {
                throw "Packaged archive hash mismatch: $component"
            }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $PlatformDirectory 'system/libdevkit-sdk-core-lib.a')) {
        throw 'Profile package contains the original monolithic archive.'
    }
    foreach ($path in @('libraries/AzureIoT', 'system/azure-iot-sdk-c', 'cores/arduino/system/azure-iot',
        'cores/arduino/Telemetry/TelemetryClient.cpp', 'platform.local.txt')) {
        $exists = Test-Path -LiteralPath (Join-Path $PlatformDirectory $path)
        if ($exists -ne ($Profile -eq 'azure-iot')) { throw "Wrong $Profile package content: $path" }
    }
}