#requires -Version 7.0

Set-StrictMode -Version Latest

function ConvertTo-Az3166DiagnosticPath {
    param([string]$Path)

    $normalized = $Path.Replace('\', '/').TrimEnd('/')
    $prefix = if ($normalized.StartsWith('//')) { '//' } elseif ($normalized.StartsWith('/')) { '/' } else { '' }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($part in $normalized.Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($part -eq '.') { continue }
        if ($part -eq '..' -and $parts.Count -gt 0 -and $parts[-1] -ne '..' -and $parts[-1] -notmatch ':$') {
            $parts.RemoveAt($parts.Count - 1)
        }
        else {
            $parts.Add($part)
        }
    }
    return $prefix + ($parts -join '/')
}

function Get-Az3166DiagnosticRelativePath {
    param([string]$Path, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $normalizedRoot = ConvertTo-Az3166DiagnosticPath $Root
    $comparison = if ($normalizedRoot -match '^(?:[a-zA-Z]:/|//)') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($Path.StartsWith($normalizedRoot + '/', $comparison)) {
        return $Path.Substring($normalizedRoot.Length + 1)
    }
    if ($Path.Equals($normalizedRoot, $comparison)) { return '' }
    return $null
}

function Resolve-Az3166DiagnosticSource {
    param([string]$Path, $Context, $Layout, $Policy)

    $normalized = ConvertTo-Az3166DiagnosticPath $Path
    $source = $normalized
    $ownership = 'unclassified'
    $staged = Get-Az3166DiagnosticRelativePath -Path $normalized -Root $Context.environment.stagedPlatformDirectory
    if ($null -ne $staged) {
        foreach ($mapping in @($Layout.mappings | Sort-Object { $_.destination.Length } -Descending)) {
            $suffix = Get-Az3166DiagnosticRelativePath -Path $normalized -Root "$($Context.environment.stagedPlatformDirectory)/$($mapping.destination)"
            if ($null -ne $suffix) {
                $source = $mapping.source + $(if ($suffix) { '/' + $suffix })
                break
            }
        }
    }
    else {
        $relative = Get-Az3166DiagnosticRelativePath -Path $normalized -Root $Context.environment.repository
        if ($null -ne $relative) { $source = $relative }
    }

    if ($Policy -and @($Policy.vendorSnapshots | Where-Object { $_.source -ceq $source }).Count -eq 1) { $ownership = 'vendor' }
    elseif ($source -cmatch '^(src|libraries|examples|tests)/') { $ownership = 'first-party' }
    elseif ($source -cmatch '^vendor/') { $ownership = 'vendor' }
    else {
        foreach ($root in @($Context.environment.arduinoUnitDirectory, $Context.environment.stagedArduinoUnitDirectory)) {
            $relative = Get-Az3166DiagnosticRelativePath -Path $normalized -Root $root
            if ($null -ne $relative) {
                $source = "ArduinoUnit/$relative"
                $ownership = 'test-dependency'
                break
            }
        }
        if ($ownership -eq 'unclassified') {
            $relative = Get-Az3166DiagnosticRelativePath -Path $normalized -Root $Context.environment.compilerRoot
            if ($null -ne $relative) {
                $source = "toolchain/$relative"
                $ownership = 'toolchain'
            }
        }
        if ($ownership -eq 'unclassified') {
            foreach ($root in @($Context.sketchDirectory, "$($Context.buildDirectory)/sketch")) {
                $relative = Get-Az3166DiagnosticRelativePath -Path $normalized -Root $root
                if ($null -ne $relative) {
                    $source = "$($Context.sketch.Replace('\', '/'))/$relative"
                    $ownership = 'first-party'
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ source = $source; ownership = $ownership }
}

function ConvertFrom-Az3166Diagnostics {
    param([string[]]$Lines, $Context, $Layout, $Policy)

    $logLine = 0
    foreach ($raw in $Lines) {
        $logLine++
        $text = [regex]::Replace($raw, '\x1b\[[0-9;]*m', '')
        $line = $null
        $column = $null
        if ($text -match '^(?<source>.+?):(?<line>\d+)(?::(?<column>\d+))?:\s*(?<severity>fatal error|error|warning|note):\s*(?<message>.*)$') {
            $line = [int]$Matches.line
            if ($Matches.ContainsKey('column')) { $column = [int]$Matches.column }
        }
        elseif ($text -notmatch '^(?:(?<source>.+?):\s*)?(?<severity>fatal error|error|warning|note):\s*(?<message>.*)$') {
            continue
        }
        $originalSource = if ($Matches.ContainsKey('source')) { $Matches.source } else { '' }
        $severity = $Matches.severity.ToLowerInvariant()
        $message = $Matches.message
        $option = $null
        if ($message -match '\s+\[(?<option>-(?:W|f)[^\]\s]+)\]$') {
            $option = $Matches.option
            $message = $message.Substring(0, $message.Length - $Matches[0].Length)
        }
        $resolved = Resolve-Az3166DiagnosticSource -Path $originalSource -Context $Context -Layout $Layout -Policy $Policy
        [pscustomobject]@{
            source = $resolved.source
            ownership = $resolved.ownership
            originalSource = $originalSource
            line = $line
            column = $column
            severity = $severity
            option = $option
            message = $message
            logLine = $logLine
            raw = $raw
        }
    }
}

function Assert-Az3166WarningPolicy {
    param($Policy, $BuildLock)

    if ($Policy.schemaVersion -ne 1 -or $Policy.warningProfile -cne 'all') {
        throw 'Warning policy must use schema 1 and the all warning profile.'
    }
    $sketches = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sketch in $Policy.inventorySketches) {
        if ($sketch -cnotmatch '^(examples|tests/hardware)/[A-Za-z0-9_/-]+$' -or -not $sketches.Add($sketch)) {
            throw "Invalid or duplicate warning inventory sketch: $sketch"
        }
    }
    if ($sketches.Count -ne 13) { throw 'Warning policy must cover the existing 13-sketch inventory.' }
    $snapshots = @{}
    foreach ($snapshot in $Policy.vendorSnapshots) {
        if ($snapshot.source -cnotmatch '^libraries/[A-Za-z0-9_-]+/src/[A-Za-z0-9_-]+\.c$' -or
            $snapshot.version -cnotmatch '^snapshot@[0-9a-f]{40}$' -or $snapshot.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]::IsNullOrWhiteSpace($snapshot.component) -or $snapshots.ContainsKey($snapshot.source)) {
            throw 'Library-local vendor snapshots require unique exact source paths, components, immutable versions, and SHA-256 pins.'
        }
        $snapshots[$snapshot.source] = $snapshot
    }
    $identifiers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $Policy.allowances) {
        foreach ($field in @('id', 'ownership', 'sourceGlob', 'component', 'version', 'rationale', 'removalCondition')) {
            if (-not $rule.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($rule.$field)) {
                throw "Warning allowance requires $field."
            }
        }
        if ($rule.id -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $identifiers.Add($rule.id)) {
            throw "Invalid or duplicate warning allowance ID: $($rule.id)"
        }
        $scope = switch -CaseSensitive ($rule.ownership) {
            'vendor' { 'vendor/' }
            'test-dependency' { 'ArduinoUnit/' }
            'toolchain' { 'toolchain/' }
            default { throw "Warning allowances cannot exempt ownership: $($rule.ownership)" }
        }
        $pinnedSnapshot = $rule.ownership -eq 'vendor' -and $snapshots.ContainsKey($rule.sourceGlob)
        if ((-not $rule.sourceGlob.StartsWith($scope, [StringComparison]::Ordinal) -and -not $pinnedSnapshot) -or
            $rule.sourceGlob.Contains('..') -or $rule.sourceGlob.Contains('\') -or
            ($rule.sourceGlob -cnotmatch '^[A-Za-z0-9_./*+-]+\.(h|hpp|c|cpp)$' -and
                -not ($rule.ownership -eq 'toolchain' -and $rule.sourceGlob -ceq 'toolchain/arm-none-eabi/bin/ld.exe'))) {
            throw "Allowance source glob must name source files within $scope : $($rule.id)"
        }
        if ($pinnedSnapshot -and ($rule.component -cne $snapshots[$rule.sourceGlob].component -or $rule.version -cne $snapshots[$rule.sourceGlob].version)) {
            throw "Library-local vendor allowance must match its content-pinned snapshot: $($rule.id)"
        }
        $hasOption = $null -ne $rule.PSObject.Properties['option'] -and -not [string]::IsNullOrWhiteSpace($rule.option)
        $hasMessage = $null -ne $rule.PSObject.Properties['messageRegex'] -and -not [string]::IsNullOrWhiteSpace($rule.messageRegex)
        if ($hasOption -eq $hasMessage) { throw "Allowance must specify exactly one option or messageRegex: $($rule.id)" }
        if ($hasOption -and $rule.option -cnotmatch '^-W[a-z][a-z0-9=-]*$') { throw "Invalid warning option: $($rule.id)" }
        if ($hasMessage) {
            if (-not $rule.messageRegex.StartsWith('^') -or -not $rule.messageRegex.EndsWith('$') -or
                $rule.messageRegex -match '\.\*|\.\+') { throw "Allowance message must be narrowly anchored: $($rule.id)" }
            $null = [regex]::new($rule.messageRegex, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))
        }
        if ($rule.ownership -eq 'test-dependency' -and
            ($rule.component -cne 'ArduinoUnit' -or $rule.version -cne $BuildLock.arduino.unit.version)) {
            throw "ArduinoUnit allowance must match the build lock: $($rule.id)"
        }
        if ($rule.ownership -eq 'toolchain' -and
            ($rule.component -cne $BuildLock.tools.armNoneEabiGcc.packageName -or $rule.version -cne $BuildLock.tools.armNoneEabiGcc.version)) {
            throw "Toolchain allowance must match the build lock: $($rule.id)"
        }
        if ($rule.ownership -eq 'vendor' -and $rule.version -cnotmatch '^snapshot@[0-9a-f]{40}$') {
            throw "Vendor allowance must pin a repository snapshot commit: $($rule.id)"
        }
    }
}

function Get-Az3166WarningPolicy {
    param([string]$Path = (Join-Path $PSScriptRoot '../build/az3166-warning-policy.json'), $BuildLock)

    $policy = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    Assert-Az3166WarningPolicy -Policy $policy -BuildLock $BuildLock
    return $policy
}

function Assert-Az3166WarningSnapshots {
    param($Policy, [string]$RepositoryRoot)

    foreach ($snapshot in $Policy.vendorSnapshots) {
        $path = Join-Path $RepositoryRoot $snapshot.source
        $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($path).Replace("`r`n", "`n"))
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
        if ($hash -cne $snapshot.sha256) { throw "Vendor snapshot changed; review its ownership and warning allowances: $($snapshot.source)" }
    }
}

function Get-Az3166WarningResult {
    param([AllowEmptyCollection()][object[]]$Diagnostics, $Policy, [switch]$CheckStale)

    $counts = [ordered]@{}
    foreach ($rule in $Policy.allowances) { $counts[$rule.id] = 0 }
    $violations = [Collections.Generic.List[object]]::new()
    $classified = @(
        foreach ($diagnostic in $Diagnostics) {
            $ruleId = $null
            if ($diagnostic.severity -eq 'warning') {
                $matched = @(
                    foreach ($rule in $Policy.allowances) {
                        if ($diagnostic.ownership -cne $rule.ownership) { continue }
                        $glob = '^' + [regex]::Escape($rule.sourceGlob).Replace('\*\*', '\S*').Replace('\*', '[^/]*') + '$'
                        if (-not [regex]::IsMatch($diagnostic.source, $glob, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { continue }
                        if ($rule.PSObject.Properties['option'] -and $rule.option -ceq $diagnostic.option) { $rule }
                        elseif (-not $diagnostic.option -and $rule.PSObject.Properties['messageRegex'] -and
                            [regex]::IsMatch($diagnostic.message, $rule.messageRegex, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))) { $rule }
                    }
                )
                $reason = if ($diagnostic.ownership -eq 'first-party') { 'first-party-warning' }
                    elseif ($matched.Count -eq 0) { 'unclassified-warning' }
                    elseif ($matched.Count -gt 1) { 'ambiguous-allowance' }
                    else { $null }
                if ($reason) { $violations.Add([pscustomobject]@{ reason = $reason; diagnostic = $diagnostic }) }
                else {
                    $ruleId = $matched[0].id
                    $counts[$ruleId]++
                }
            }
            $diagnostic | Select-Object *, @{ Name = 'allowance'; Expression = { $ruleId } }
        }
    )
    $stale = @($counts.Keys | Where-Object { $CheckStale -and $counts[$_] -eq 0 })
    return [pscustomobject]@{
        schemaVersion = 1
        passed = $violations.Count -eq 0 -and $stale.Count -eq 0
        staleChecked = [bool]$CheckStale
        warningCount = @($Diagnostics | Where-Object { $_.severity -eq 'warning' }).Count
        firstPartyWarningCount = @($Diagnostics | Where-Object { $_.severity -eq 'warning' -and $_.ownership -eq 'first-party' }).Count
        allowedWarningCount = @($classified | Where-Object { $null -ne $_.allowance }).Count
        countsByRule = $counts
        staleAllowances = $stale
        violations = @($violations)
        diagnostics = $classified
    }
}

function Export-Az3166WarningEvidence {
    param([string]$OutputDirectory, $Policy, $Layout, [switch]$RequireCompleteInventory)

    $diagnostics = [Collections.Generic.List[object]]::new()
    $evidenceIssues = [Collections.Generic.List[string]]::new()
    $failedSketches = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sketches = [Collections.Generic.List[string]]::new()
    foreach ($directory in @(Get-ChildItem -LiteralPath $OutputDirectory -Directory -Force | Sort-Object Name -CaseSensitive)) {
        $contextPath = Join-Path $directory.FullName 'build-context.json'
        if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { continue }
        $context = Get-Content -Raw -LiteralPath $contextPath | ConvertFrom-Json
        $sketch = $context.sketch.Replace('\', '/')
        $sketches.Add($sketch)
        $sketchDiagnostics = [Collections.Generic.List[object]]::new()
        $issues = [Collections.Generic.List[string]]::new()
        $warningArguments = @($context.compile.arguments)
        $warningIndex = [Array]::IndexOf($warningArguments, '--warnings')
        if ($warningIndex -lt 0 -or $warningIndex -ge $warningArguments.Count - 1 -or
            $warningArguments[$warningIndex + 1] -cne $Policy.warningProfile) {
            $issues.Add('Build did not select the all warning profile.')
        }
        foreach ($stream in @('stdout', 'stderr')) {
            $logName = "build.$stream.log"
            $logPath = Join-Path $directory.FullName $logName
            try {
                if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Missing raw diagnostic stream: $logName" }
                foreach ($diagnostic in @(ConvertFrom-Az3166Diagnostics -Lines @([IO.File]::ReadAllLines($logPath)) -Context $context -Layout $Layout -Policy $Policy)) {
                    $record = $diagnostic | Select-Object *, @{ Name = 'sketch'; Expression = { $sketch } }, @{ Name = 'log'; Expression = { "$($directory.Name)/$logName" } }
                    $sketchDiagnostics.Add($record)
                    $diagnostics.Add($record)
                }
            }
            catch { $issues.Add($_.Exception.Message) }
        }
        $result = Get-Az3166WarningResult -Diagnostics @($sketchDiagnostics) -Policy $Policy
        if (-not $result.passed) { $issues.Add("Warning policy rejected $($result.violations.Count) diagnostic(s); see warnings.json.") }
        $result.passed = $result.passed -and $issues.Count -eq 0
        $result | Add-Member -NotePropertyName evidenceIssues -NotePropertyValue @($issues)
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $directory.FullName 'warnings.json') -Encoding utf8
        if ($issues.Count -gt 0) {
            $context.status = 'failed'
            $context.errors = @($context.errors) + @($issues)
            foreach ($issue in $issues) { $evidenceIssues.Add("${sketch}: $issue") }
        }
        if ($context.status -ne 'passed') { $null = $failedSketches.Add($context.sketch) }
        $context | Add-Member -Force -NotePropertyName warningPolicy -NotePropertyValue ([ordered]@{
            passed = $result.passed -and $issues.Count -eq 0
            warningCount = $result.warningCount
            firstPartyWarningCount = $result.firstPartyWarningCount
            allowedWarningCount = $result.allowedWarningCount
            report = 'warnings.json'
        })
        $context | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contextPath -Encoding utf8
    }
    $complete = $sketches.Count -eq $Policy.inventorySketches.Count -and
        (($sketches | Sort-Object -CaseSensitive) -join "`n") -ceq (($Policy.inventorySketches | Sort-Object -CaseSensitive) -join "`n")
    if ($RequireCompleteInventory -and -not $complete) { $evidenceIssues.Add('Warning inventory does not contain the required 13 sketches.') }
    if ($sketches.Count -eq 0) { $evidenceIssues.Add('No sketch build contexts were found.') }
    $report = Get-Az3166WarningResult -Diagnostics @($diagnostics) -Policy $Policy -CheckStale:$complete
    $report.passed = $report.passed -and $evidenceIssues.Count -eq 0 -and $failedSketches.Count -eq 0
    $report | Add-Member -NotePropertyName sketches -NotePropertyValue @($sketches)
    $report | Add-Member -NotePropertyName failedSketches -NotePropertyValue @($failedSketches)
    $report | Add-Member -NotePropertyName evidenceIssues -NotePropertyValue @($evidenceIssues)
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'warning-summary.json') -Encoding utf8
    $summary = @(
        '### AZ3166 warning policy (compile only)'
        ''
        "Passed: $($report.passed). Warnings: $($report.warningCount). First-party: $($report.firstPartyWarningCount). Allowed: $($report.allowedWarningCount)."
        "Complete inventory / stale checks: $complete."
        ''
        '| Allowance | Count |'
        '| --- | ---: |'
        foreach ($entry in $report.countsByRule.GetEnumerator()) { "| $($entry.Key) | $($entry.Value) |" }
        ''
        foreach ($rule in $report.staleAllowances) { "Stale allowance: $rule" }
        foreach ($issue in $evidenceIssues) { $issue }
        foreach ($violation in $report.violations) {
            "$($violation.reason): $($violation.diagnostic.source):$($violation.diagnostic.line): $($violation.diagnostic.message)"
        }
    )
    $summary | Set-Content -LiteralPath (Join-Path $OutputDirectory 'warning-summary.md') -Encoding utf8
    $summary | ForEach-Object { Write-Host $_ }
    return $report
}