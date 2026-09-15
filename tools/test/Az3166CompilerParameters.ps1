#requires -Version 7.0

Set-StrictMode -Version Latest

function Get-Az3166CompilerBaseline {
    param(
        [string]$RepositoryRoot,
        [string]$Revision = '6d145395ae3aaeb14cec2a3f739e33d34ec628ac'
    )

    . (Join-Path $PSScriptRoot '../package/Az3166PackageLayout.ps1')
    return @{
        Revision = Invoke-Az3166LayoutGit $RepositoryRoot @('rev-parse', "$Revision^{commit}")
        Platform = Invoke-Az3166LayoutGit $RepositoryRoot @('show', "${Revision}:platform/az3166/platform.txt")
        Boards = Invoke-Az3166LayoutGit $RepositoryRoot @('show', "${Revision}:platform/az3166/boards.txt")
    }
}

function Get-Az3166RecipeProperties {
    param([string]$Platform, [string]$Boards, [string]$Board)

    $properties = @{}
    foreach ($content in @($Platform, $Boards)) {
        foreach ($line in ($content -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
            $parts = $line.Split('=', 2)
            if ($parts.Count -ne 2) { throw "Invalid Arduino property: $line" }
            $name = $parts[0].Trim()
            if ($name.StartsWith("$Board.", [StringComparison]::Ordinal)) {
                $name = $name.Substring($Board.Length + 1)
            }
            $properties[$name] = $parts[1].Trim()
        }
    }
    return $properties
}

function Expand-Az3166RecipeProperty {
    param([hashtable]$Properties, [string]$Name, [string[]]$Ancestors = @())

    if ($Name -cin $Ancestors) { throw "Recursive Arduino property: $(@($Ancestors) + $Name -join ' -> ')" }
    if (-not $Properties.ContainsKey($Name)) { return "{$Name}" }
    return [regex]::Replace($Properties[$Name], '\{([^{}]+)\}', {
        param($match)
        Expand-Az3166RecipeProperty -Properties $Properties -Name $match.Groups[1].Value -Ancestors (@($Ancestors) + $Name)
    })
}

function ConvertFrom-Az3166VerboseCommand {
    param([string]$Command)

    $text = $Command.Trim()
    $matches = [regex]::Matches($text, '(?:^|\s+)(?<token>"(?:\\.|[^"\\])*"|[^\s"]+)(?=\s|$)')
    if ($matches.Count -eq 0 -or ($matches | ForEach-Object { $_.Value }) -join '' -cne $text) {
        throw "Unsupported Arduino CLI command formatting: $Command"
    }
    return ,@($matches | ForEach-Object {
        $token = $_.Groups['token'].Value
        if ($token.StartsWith('"')) { ConvertFrom-Json -InputObject $token }
        else { $token }
    })
}

function Get-Az3166BuildCommands {
    param([string]$LogPath)

    $commands = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadLines($LogPath)) {
        if ($line -notmatch '^"?[^"\r\n]*[/\\]arm-none-eabi-(gcc|g\+\+|as|ar|ld|objcopy|size)(\.exe)?"?\s') { continue }
        $arguments = ConvertFrom-Az3166VerboseCommand $line
        $tool = [IO.Path]::GetFileNameWithoutExtension($arguments[0]) -replace '^arm-none-eabi-', ''
        $kind = switch ($tool) {
            'ar' { 'archiver' }
            'as' { 'assembler' }
            'ld' { 'linker' }
            'objcopy' { 'objcopy' }
            'size' { 'size' }
            default {
                if ($arguments -contains '-E') { 'preprocessor' }
                elseif ($arguments -contains 'assembler-with-cpp') { 'assembler' }
                elseif ($arguments -contains '-c') { 'compiler' }
                else { 'linker' }
            }
        }
        if ($kind -ceq 'preprocessor') {
            $temporaryPrefix = [regex]::Escape([IO.Path]::GetTempPath())
            for ($index = 1; $index -lt $arguments.Count - 1; $index++) {
                if ($arguments[$index] -ceq '-o' -and
                    $arguments[$index + 1] -cmatch "\A${temporaryPrefix}[0-9]+[\\/]sketch_merged\.cpp\z") {
                    $arguments[$index + 1] = '<arduino-preprocess>/sketch_merged.cpp'
                }
            }
        }
        $commands.Add([ordered]@{ kind = $kind; arguments = $arguments })
    }
    foreach ($required in @('compiler', 'archiver', 'linker', 'objcopy', 'size')) {
        if (@($commands | Where-Object { $_.kind -ceq $required }).Count -eq 0) {
            throw "No $required commands were captured from $LogPath"
        }
    }
    return ,@($commands | Sort-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress } -CaseSensitive)
}

function Export-Az3166CompilerEvidence {
    param([string]$Directory)

    . (Join-Path $PSScriptRoot 'Az3166BuildEvidence.ps1')
    $context = Get-Content -Raw -LiteralPath (Join-Path $Directory 'build-context.json') | ConvertFrom-Json
    if ($context.status -cne 'passed') { throw "Cannot compare an unsuccessful sketch: $Directory" }
    $commands = Get-Az3166BuildCommands -LogPath (Join-Path $Directory 'build.stdout.log')
    ConvertTo-Json -InputObject $commands -Depth 6 | Set-Content -LiteralPath (Join-Path $Directory 'commands.json') -Encoding utf8
    $database = Get-Content -Raw -LiteralPath (Join-Path $Directory 'compile_commands.build.json') | ConvertFrom-Json
    $databaseCommands = @($database | ForEach-Object {
        [ordered]@{ directory = $_.directory; file = $_.file; arguments = @($_.arguments) }
    } | Sort-Object { $_.file } -CaseSensitive)
    $compilerTokens = @($commands | Where-Object { $_.kind -in 'compiler', 'assembler' } |
        ForEach-Object { ConvertTo-Json -InputObject $_.arguments -Compress } | Sort-Object -CaseSensitive)
    $databaseTokens = @($databaseCommands | ForEach-Object { ConvertTo-Json -InputObject $_.arguments -Compress } | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json -InputObject $compilerTokens -Compress) -cne (ConvertTo-Json -InputObject $databaseTokens -Compress)) {
        throw "Verbose compiler commands do not match the original compilation database: $Directory"
    }
    ConvertTo-Json -InputObject $databaseCommands -Depth 6 | Set-Content -LiteralPath (Join-Path $Directory 'database-commands.json') -Encoding utf8
    $elf = @($context.artifacts | Where-Object { $_.name.EndsWith('.elf') })[0]
    $readelf = Join-Path (Split-Path -Parent $context.environment.tools.gcc.path) 'arm-none-eabi-readelf.exe'
    $report = Invoke-Az3166EvidenceProcess -FilePath $readelf -Arguments @('-W', '-S', '-l', (Join-Path $Directory $elf.name)) `
        -LogPath (Join-Path $Directory 'inspection.log') -CaptureOutput
    if ($report.ExitCode -ne 0) { throw "ELF inspection failed: $Directory" }
    $report.Output | Set-Content -LiteralPath (Join-Path $Directory 'elf-sections-program-headers.txt') -Encoding utf8 -NoNewline
    return [ordered]@{
        sketch = Split-Path -Leaf $Directory
        commands = $commands.Count
        assemblerCommands = @($commands | Where-Object { $_.kind -ceq 'assembler' }).Count
    }
}

function Compare-Az3166CompilerEvidence {
    param([string]$Before, [string]$After)

    $beforeContext = Get-Content -Raw -LiteralPath (Join-Path $Before 'build-context.json') | ConvertFrom-Json
    $afterContext = Get-Content -Raw -LiteralPath (Join-Path $After 'build-context.json') | ConvertFrom-Json
    if ($beforeContext.status -cne 'passed' -or $afterContext.status -cne 'passed') { throw 'Both comparison builds must have passed.' }
    $beforeArtifacts = @($beforeContext.artifacts | ForEach-Object { $_.name } | Sort-Object -CaseSensitive)
    $afterArtifacts = @($afterContext.artifacts | ForEach-Object { $_.name } | Sort-Object -CaseSensitive)
    if ((ConvertTo-Json -InputObject $beforeArtifacts -Compress) -cne (ConvertTo-Json -InputObject $afterArtifacts -Compress)) {
        throw 'Comparison firmware artifact sets differ.'
    }
    foreach ($name in @('revision', 'lockSha256', 'fqbn', 'stagedPlatformDirectory', 'repository', 'arduinoDataDirectory', 'arduinoUnitDirectory')) {
        if ($beforeContext.environment.$name -cne $afterContext.environment.$name) { throw "Comparison input changed: $name" }
    }
    if ($beforeContext.buildDirectory -cne $afterContext.buildDirectory) { throw 'Comparison build paths differ.' }
    if ((ConvertTo-Json -InputObject $beforeContext.environment.tools -Depth 5 -Compress) -cne
        (ConvertTo-Json -InputObject $afterContext.environment.tools -Depth 5 -Compress)) { throw 'Comparison tool identities differ.' }
    $files = @('commands.json', 'database-commands.json', 'size.txt', 'size.json', 'elf-sections-program-headers.txt') +
        @($beforeContext.artifacts | ForEach-Object { $_.name })
    $results = @(
        foreach ($name in $files) {
            $beforeFile = Get-Item -LiteralPath (Join-Path $Before $name)
            $afterFile = Get-Item -LiteralPath (Join-Path $After $name)
            if ($beforeFile.Length -eq 0 -or $afterFile.Length -eq 0) { throw "Empty comparison artifact: $name" }
            $beforeHash = (Get-FileHash -LiteralPath $beforeFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $afterHash = (Get-FileHash -LiteralPath $afterFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            [ordered]@{ file = $name; equal = $beforeHash -ceq $afterHash; beforeSha256 = $beforeHash; afterSha256 = $afterHash }
        }
    )
    return [ordered]@{
        sketch = Split-Path -Leaf $Before
        passed = @($results | Where-Object { -not $_.equal }).Count -eq 0
        files = $results
    }
}