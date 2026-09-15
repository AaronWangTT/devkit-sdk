#requires -Version 7.0

Set-StrictMode -Version Latest

function Invoke-Az3166EvidenceProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$LogPath,

        [string]$StreamLogPrefix,

        [switch]$CaptureOutput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $writer = [IO.TextWriter]::Null
    if ($LogPath) {
        $writer = [IO.StreamWriter]::new($LogPath, $true, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
    }
    $captured = [Text.StringBuilder]::new()
    $started = $false
    $streamWriters = @([IO.TextWriter]::Null, [IO.TextWriter]::Null)
    try {
        if ($StreamLogPrefix) {
            foreach ($streamIndex in 0..1) {
                $suffix = @('stdout', 'stderr')[$streamIndex]
                $streamWriters[$streamIndex] = [IO.StreamWriter]::new("$StreamLogPrefix.$suffix.log", $true, [Text.UTF8Encoding]::new($false))
                $streamWriters[$streamIndex].AutoFlush = $true
            }
        }
        $command = @{ executable = $FilePath; arguments = @($Arguments) } | ConvertTo-Json -Compress
        $writer.WriteLine("Command: $command")
        Write-Host "Command: $command"
        $started = $process.Start()
        $streams = [Collections.Generic.List[object]]::new()
        $readers = @($process.StandardOutput, $process.StandardError)
        foreach ($streamIndex in 0..1) {
            $reader = $readers[$streamIndex]
            $buffer = [char[]]::new(4096)
            $streams.Add(@{
                Reader = $reader
                Writer = $streamWriters[$streamIndex]
                Buffer = $buffer
                Pending = $reader.ReadAsync($buffer, 0, $buffer.Length)
            })
        }
        while ($streams.Count -gt 0) {
            $index = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($streams | ForEach-Object { $_.Pending }))
            $stream = $streams[$index]
            $count = $stream.Pending.GetAwaiter().GetResult()
            if ($count -eq 0) {
                $streams.RemoveAt($index)
                continue
            }
            $text = [string]::new($stream.Buffer, 0, $count)
            $writer.Write($text)
            $stream.Writer.Write($text)
            Write-Host -NoNewline $text
            if ($CaptureOutput) {
                $null = $captured.Append($text)
            }
            $stream.Pending = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $captured.ToString()
        }
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
        }
        finally {
            try { $writer.Dispose() }
            finally {
                try { $streamWriters[0].Dispose() }
                finally {
                    try { $streamWriters[1].Dispose() }
                    finally { $process.Dispose() }
                }
            }
        }
    }
}

function Assert-Az3166CompilationDatabase {
    param([string]$Path, [string]$SketchSource)

    $database = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -NoEnumerate
    if ($database -isnot [array] -or $database.Count -eq 0) {
        throw 'Compilation database must be a nonempty JSON array.'
    }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $expected = [IO.Path]::GetFullPath($SketchSource)
    $matchesSketch = $false
    foreach ($entry in $database) {
        $properties = @($entry.PSObject.Properties.Name)
        if ('file' -notin $properties -or 'directory' -notin $properties -or
            $entry.file -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.file) -or
            $entry.directory -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($entry.directory)) {
            throw 'Compilation database entry is missing a source file or absolute working directory.'
        }
        $hasArguments = 'arguments' -in $properties -and $entry.arguments -is [array] -and
            $entry.arguments.Count -gt 0 -and @($entry.arguments | Where-Object { $_ -isnot [string] -or $_.Length -eq 0 }).Count -eq 0
        $hasCommand = 'command' -in $properties -and $entry.command -is [string] -and
            -not [string]::IsNullOrWhiteSpace($entry.command)
        if (-not $hasArguments -and -not $hasCommand) {
            throw 'Compilation database entry is missing compiler arguments.'
        }
        if ([IO.Path]::IsPathRooted($entry.file) -and -not [IO.Path]::IsPathFullyQualified($entry.file)) {
            throw 'Compilation database source must be fully qualified or relative to its working directory.'
        }
        $source = if ([IO.Path]::IsPathFullyQualified($entry.file)) { $entry.file } else { Join-Path $entry.directory $entry.file }
        if ([IO.Path]::GetFullPath($source).Equals($expected, $comparison)) {
            $matchesSketch = $true
        }
    }
    if (-not $matchesSketch) {
        throw "Compilation database has no entry for the built sketch: $SketchSource"
    }
    return $database.Count
}

function Complete-Az3166BuildEvidence {
    param(
        [Collections.IDictionary]$Context,
        [Collections.Generic.List[string]]$Issues,
        [string]$ContextPath,
        [string]$LogPath
    )

    try {
        foreach ($issue in $Issues) {
            Write-Host $issue
            Add-Content -LiteralPath $LogPath -Value $issue -Encoding utf8 -ErrorAction Stop
        }
    }
    catch {
        $Issues.Add("Could not append evidence diagnostics: $($_.Exception.Message)")
        Write-Host $Issues[-1]
    }
    $Context.finishedAt = [DateTime]::UtcNow.ToString('o')
    $Context.status = if ($Issues.Count -eq 0) { 'passed' } else { 'failed' }
    $Context.errors = @($Issues)
    $Context | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ContextPath -Encoding utf8 -ErrorAction Stop
}

function ConvertFrom-Az3166SizeReport {
    param([string]$Output, [string]$ElfName)

    $sections = @(
        foreach ($line in ($Output -split '\r?\n')) {
            if ($line -match '^\s*(?<name>\S+)\s+(?<size>[0-9]+)\s+(?<address>[0-9]+)\s*$') {
                [ordered]@{
                    name = $Matches.name
                    size = [long]$Matches.size
                    address = [long]$Matches.address
                }
            }
        }
    )
    if ($sections.Count -eq 0 -or '.text' -notin @($sections.name)) {
        throw 'GNU size output contains no .text section.'
    }
    $flash = 0L
    $ram = 0L
    $total = 0L
    foreach ($section in $sections) {
        $total += $section.size
        if ($section.name -in @('.text', '.data', '.rodata')) { $flash += $section.size }
        if ($section.name -in @('.data', '.bss', '._user_heap_stack')) { $ram += $section.size }
    }
    return [ordered]@{
        schemaVersion = 1
        elf = $ElfName
        format = 'GNU size -A (decimal bytes and addresses)'
        flashBytes = $flash
        ramBytes = $ram
        totalSectionBytes = $total
        sections = $sections
    }
}

function Get-Az3166EvidenceSummary {
    param(
        [string]$OutputDirectory,
        [string]$ArtifactUrl,
        [string]$ArtifactRootDirectory = $OutputDirectory
    )

    '### AZ3166 build evidence (compile only)'
    ''
    if ($ArtifactUrl) {
        "[Download complete evidence]($ArtifactUrl). File links download this archive; labels identify paths inside it."
        ''
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        'No sketch evidence was produced.'
        return
    }
    '| Sketch | Status | Log | Sizes | Firmware |'
    '| --- | --- | --- | --- | --- |'
    foreach ($directory in (Get-ChildItem -LiteralPath $OutputDirectory -Directory -Force | Sort-Object Name)) {
        $contextPath = Join-Path $directory.FullName 'build-context.json'
        if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { continue }
        $context = Get-Content -Raw -LiteralPath $contextPath | ConvertFrom-Json
        $links = @{}
        foreach ($name in @('build.log', 'size.txt', 'size.json') + @($context.artifacts | ForEach-Object { $_.name })) {
            if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName $name) -PathType Leaf)) { continue }
            $relative = "$($directory.Name)/$name"
            if ($ArtifactUrl) {
                $relative = [IO.Path]::GetRelativePath($ArtifactRootDirectory, (Join-Path $directory.FullName $name)).Replace('\', '/')
            }
            $target = if ($ArtifactUrl) { $ArtifactUrl } else { ($relative.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/' }
            $links[$name] = "[$relative]($target)"
        }
        $sizes = @(@('size.txt', 'size.json') | Where-Object { $links.ContainsKey($_) } | ForEach-Object { $links[$_] }) -join ', '
        $firmware = @($context.artifacts | ForEach-Object { $links[$_.name] }) -join ', '
        "| $($directory.Name) | $($context.status) | $($links['build.log']) | $sizes | $firmware |"
    }
}