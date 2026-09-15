#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ArduinoCli,
    [string]$ArduinoDataDirectory,
    [string]$ArduinoUnitDirectory,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tools/test/Az3166BuildEvidence.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166 evidence $([guid]::NewGuid().ToString('N'))"

function Assert-EvidenceTest {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $fixture = Join-Path $fixtureRoot 'process fixture.ps1'
    $log = Join-Path $fixtureRoot 'build log.txt'
    @'
param([string]$Value, [string]$LogPath)
$ErrorActionPreference = 'Stop'
[Console]::Out.WriteLine('stream-start')
[Console]::Out.Flush()
$streamed = [Threading.SpinWait]::SpinUntil([Func[bool]] {
    $file = [IO.File]::Open($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($file)
    try { return $reader.ReadToEnd().Contains('stream-start') }
    finally { $reader.Dispose() }
}, 10000)
if (-not $streamed) { exit 99 }
[Console]::Out.WriteLine($Value)
[Console]::Error.WriteLine('stderr-diagnostic')
for ($index = 0; $index -lt 32; $index++) {
    [Console]::Out.Write('o' * 4096)
    [Console]::Error.Write('e' * 4096)
}
[Console]::Error.Write('stderr-final')
[Console]::Out.Write('stdout-final')
exit 23
'@ | Set-Content -LiteralPath $fixture -Encoding utf8
    $value = 'path with spaces\trailing\ and "quotes"; $notCode'
    $console = @(& {
        $script:result = Invoke-Az3166EvidenceProcess -FilePath (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) `
            -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fixture, '-Value', $value, '-LogPath', $log) `
            -LogPath $log -CaptureOutput
    } 6>&1 | ForEach-Object { $_.ToString() }) -join ''
    $retained = Get-Content -Raw -LiteralPath $log
    Assert-EvidenceTest ($result.ExitCode -eq 23) "Native exit code was lost, or output was buffered: $($result.ExitCode)"
    foreach ($output in @($retained, $console, $result.Output)) {
        foreach ($expected in @('stream-start', $value, 'stderr-diagnostic', 'stdout-final', 'stderr-final')) {
            Assert-EvidenceTest ($output.Contains($expected)) "Missing process output: $expected"
        }
        Assert-EvidenceTest (($output.ToCharArray() | Where-Object { $_ -ceq 'o' }).Count -ge (32 * 4096)) 'Large stdout was truncated.'
        Assert-EvidenceTest (($output.ToCharArray() | Where-Object { $_ -ceq 'e' }).Count -ge (32 * 4096)) 'Large stderr was truncated.'
    }
    $command = ($retained -split '\r?\n')[0].Substring('Command: '.Length) | ConvertFrom-Json
    Assert-EvidenceTest ($command.arguments[-3] -ceq $value) 'Structured command arguments were corrupted.'
    Write-Host 'PASS live stdout/stderr, large output, trailing diagnostics, literal arguments, and native failure exit code'

    $launchLog = Join-Path $fixtureRoot 'launch-failure.log'
    $rejected = $false
    try { $null = Invoke-Az3166EvidenceProcess -FilePath (Join-Path $fixtureRoot 'missing-tool') -LogPath $launchLog }
    catch { $rejected = $true }
    Assert-EvidenceTest ($rejected -and (Get-Content -Raw -LiteralPath $launchLog).Contains('missing-tool')) 'A process launch failure lost its attempted command.'
    Write-Host 'PASS process launch failure preserves the attempted command'

    $databasePath = Join-Path $fixtureRoot 'compile_commands.json'
    $sketchSource = Join-Path $fixtureRoot 'sketch/Example.ino.cpp'
    $entry = @{ directory = $fixtureRoot; file = 'sketch/Example.ino.cpp'; arguments = @('g++', '-c', $sketchSource) }
    ConvertTo-Json -InputObject @($entry) -Depth 4 | Set-Content -LiteralPath $databasePath -Encoding utf8
    Assert-EvidenceTest ((Assert-Az3166CompilationDatabase -Path $databasePath -SketchSource $sketchSource) -eq 1) 'Valid compilation database was rejected.'
    foreach ($invalid in @('[]', '{}', '[{"file":"other.cpp"}]', (ConvertTo-Json -InputObject @($entry) -Depth 4).Replace('Example.ino.cpp', 'Other.ino.cpp'))) {
        Set-Content -LiteralPath $databasePath -Value $invalid -Encoding utf8
        $rejected = $false
        try { $null = Assert-Az3166CompilationDatabase -Path $databasePath -SketchSource $sketchSource }
        catch { $rejected = $true }
        Assert-EvidenceTest $rejected "Invalid compilation database was accepted: $invalid"
    }
    if ($IsWindows) {
        foreach ($property in @('directory', 'file')) {
            foreach ($partialPath in @('\root-relative', 'C:drive-relative')) {
                $invalidEntry = $entry.Clone()
                $invalidEntry[$property] = $partialPath
                ConvertTo-Json -InputObject @($invalidEntry) -Depth 4 | Set-Content -LiteralPath $databasePath -Encoding utf8
                $rejected = $false
                try { $null = Assert-Az3166CompilationDatabase -Path $databasePath -SketchSource $sketchSource }
                catch { $rejected = $true }
                Assert-EvidenceTest $rejected "Partially qualified database path was accepted: $property=$partialPath"
            }
        }
    }
    Write-Host 'PASS compilation database structure and built-sketch identity'

    $failedContextPath = Join-Path $fixtureRoot 'final-context.json'
    $failedContext = [ordered]@{ status = 'running'; errors = @(); finishedAt = $null }
    $failedIssues = [Collections.Generic.List[string]]::new()
    $failedIssues.Add('original compile failure')
    & {
        function Add-Content { throw 'fixture append failure' }
        Complete-Az3166BuildEvidence -Context $failedContext -Issues $failedIssues -ContextPath $failedContextPath -LogPath $log
    }
    $finalContext = Get-Content -Raw -LiteralPath $failedContextPath | ConvertFrom-Json
    Assert-EvidenceTest ($finalContext.status -ceq 'failed' -and $finalContext.errors.Count -eq 2 -and
        $finalContext.errors[1].Contains('fixture append failure')) 'Final context omitted the diagnostic-log write failure.'
    Write-Host 'PASS retained context includes diagnostic-log write failures'

    $size = ConvertFrom-Az3166SizeReport -ElfName 'Example.ino.elf' -Output @'
Example.ino.elf :
section              size        addr
.text                 100   134266880
.rodata                20   134266980
.data                  12   536870912
.bss                   32   536870924
._user_heap_stack      128   536870956
.debug_info            200           0
Total                 492
'@
    Assert-EvidenceTest ($size.flashBytes -eq 132 -and $size.ramBytes -eq 172 -and $size.totalSectionBytes -eq 492) 'Size totals do not match the unchanged platform recipes.'
    Assert-EvidenceTest ($size.sections.Count -eq 6 -and $size.elf -ceq 'Example.ino.elf') 'Structured sizes lost sections or sketch identity.'
    Write-Host 'PASS raw GNU section sizes map to structured flash and RAM totals'

    $summaryRoot = Join-Path $fixtureRoot 'summary'
    $failedPath = Join-Path $summaryRoot 'Failed'
    New-Item -ItemType Directory -Path $failedPath -Force | Out-Null
    @{ status = 'failed'; artifacts = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $failedPath 'build-context.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $failedPath 'build.log') -Value 'compiler failed' -Encoding utf8
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory $summaryRoot) -join "`n"
    Assert-EvidenceTest ($summary.Contains('[Failed/build.log](Failed/build.log)') -and $summary.Contains('| failed |')) 'An early failure was omitted from the evidence summary.'
    Assert-EvidenceTest (-not $summary.Contains('size.txt') -and -not $summary.Contains('size.json')) 'Missing size reports were listed in a failed-build summary.'
    foreach ($sizeName in @('size.txt', 'size.json')) {
        Set-Content -LiteralPath (Join-Path $failedPath $sizeName) -Value 'retained size report' -Encoding utf8
    }
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory $summaryRoot) -join "`n"
    foreach ($sizeName in @('size.txt', 'size.json')) {
        Assert-EvidenceTest ($summary.Contains("[Failed/$sizeName](Failed/$sizeName)")) "Missing size-report hyperlink: $sizeName"
    }
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory $summaryRoot -ArtifactUrl 'https://example.test/artifact') -join "`n"
    Assert-EvidenceTest ($summary.Contains('[Failed/build.log](https://example.test/artifact)')) 'CI summary did not link the retained artifact.'
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory $summaryRoot -ArtifactUrl 'https://example.test/artifact' -ArtifactRootDirectory $fixtureRoot) -join "`n"
    Assert-EvidenceTest ($summary.Contains('[summary/Failed/build.log](https://example.test/artifact)')) 'Nested evidence labels are not relative to the uploaded archive root.'
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory (Join-Path $fixtureRoot 'not-created')) -join "`n"
    Assert-EvidenceTest ($summary.Contains('No sketch evidence was produced.')) 'An interrupted setup could not be summarized.'
    Write-Host 'PASS failed builds without firmware retain working summary links'

    $workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-package-ci.yml')
    $upload = @($workflow -split '\r?\n      - name:' | Where-Object { $_.Contains('id: build-evidence') })
    Assert-EvidenceTest ($upload.Count -eq 1 -and $upload[0].Contains('if: always()') -and $upload[0].Contains('retention-days: 30')) 'CI must always upload build evidence with review retention.'
    Assert-EvidenceTest ($upload[0].Contains('path: ${{ runner.temp }}/az3166-build-evidence')) 'CI does not upload the complete evidence directory.'
    Assert-EvidenceTest ($workflow.Contains('Validate failed-build evidence') -and $workflow.Contains('Get-Az3166EvidenceSummary')) 'CI is missing failed-build validation or the evidence summary.'
    Write-Host 'PASS CI retains complete build evidence on failure and publishes a linked summary'

    $driver = Join-Path $repositoryRoot 'tools/test/Test-Az3166Sketches.ps1'
    $preflightSketch = Join-Path $fixtureRoot 'Preflight'
    $preflightUnit = Join-Path $fixtureRoot 'ArduinoUnit'
    New-Item -ItemType Directory -Path $preflightSketch, $preflightUnit | Out-Null
    Set-Content -LiteralPath (Join-Path $preflightSketch 'Preflight.ino') -Value 'void setup() {} void loop() {}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $preflightUnit 'library.properties') -Value 'name=ArduinoUnit' -Encoding utf8
    $preflightOutput = Join-Path $fixtureRoot 'prior evidence'
    New-Item -ItemType Directory -Path $preflightOutput | Out-Null
    $sentinel = Join-Path $preflightOutput 'compiler-versions.txt'
    Set-Content -LiteralPath $sentinel -Value 'prior-run' -Encoding utf8
    $before = (Get-FileHash -LiteralPath $sentinel).Hash
    $failure = $null
    try {
        & $driver -ArduinoCli (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) `
            -ArduinoDataDirectory $fixtureRoot -ArduinoUnitDirectory $preflightUnit `
            -OutputDirectory $preflightOutput -Sketch (Join-Path $preflightSketch 'Preflight.ino')
    }
    catch { $failure = $_.Exception.Message }
    Assert-EvidenceTest ($failure -like 'Output directory must be empty;*') 'A mixed-run output root was accepted.'
    Assert-EvidenceTest ($before -ceq (Get-FileHash -LiteralPath $sentinel).Hash) 'Output-root preflight modified earlier evidence.'
    Assert-EvidenceTest (@(Get-ChildItem -LiteralPath $preflightOutput -Force).Count -eq 1) 'Output-root preflight created new evidence.'
    Write-Host 'PASS nonempty output roots are rejected without appending or overwriting prior evidence'

    foreach ($reservedName in @('compiler-versions.txt', 'az3166-build-lock.json', 'summary.md', 'SUMMARY.MD')) {
        $reservedSketch = Join-Path $fixtureRoot $reservedName
        New-Item -ItemType Directory -Path $reservedSketch -Force | Out-Null
        $unusedOutput = Join-Path $fixtureRoot 'reserved-name-output'
        $failure = $null
        try {
            & $driver -ArduinoCli (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) `
                -ArduinoDataDirectory $fixtureRoot -ArduinoUnitDirectory $preflightUnit `
                -OutputDirectory $unusedOutput -Sketch $reservedSketch
        }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like 'Sketch names must be unique safe directory names and not reserved for evidence:*') "Reserved evidence name was accepted: $reservedName"
        Assert-EvidenceTest (-not (Test-Path -LiteralPath $unusedOutput)) 'Reserved-name rejection created output.'
    }
    Write-Host 'PASS root evidence filenames cannot collide with sketch names'

    if (-not $IsWindows) {
        $caseSketches = @(@('CaseSketch', 'casesketch') | ForEach-Object { Join-Path $fixtureRoot $_ })
        foreach ($directory in $caseSketches) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $unusedOutput = Join-Path $fixtureRoot 'case-collision-output'
        $failure = $null
        try {
            & $driver -ArduinoCli (Join-Path $PSHOME 'pwsh') `
                -ArduinoDataDirectory $fixtureRoot -ArduinoUnitDirectory $preflightUnit `
                -OutputDirectory $unusedOutput -Sketch $caseSketches
        }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like 'Sketch names must be unique safe directory names and not reserved for evidence:*') 'Case-only sketch selections were silently deduplicated.'
        Assert-EvidenceTest (-not (Test-Path -LiteralPath $unusedOutput)) 'Case-collision rejection created output.'
        Write-Host 'PASS distinct case-only sketch paths are rejected rather than silently deduplicated'
    }

    if ($IsWindows) {
        $longOutput = Join-Path ([IO.Path]::GetPathRoot($fixtureRoot)) "az3166-length-$([guid]::NewGuid().ToString('N'))"
        $longOutput += 'p' * (141 - $longOutput.Length - '\Preflight\build'.Length)
        Assert-EvidenceTest ((Join-Path $longOutput 'Preflight/build').Length -eq 141) 'The over-limit build path fixture is not 141 characters long.'
        $failure = $null
        try {
            & $driver -ArduinoCli (Join-Path $PSHOME 'pwsh.exe') `
                -ArduinoDataDirectory $fixtureRoot -ArduinoUnitDirectory $preflightUnit `
                -OutputDirectory $longOutput -Sketch $preflightSketch
        }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like 'Windows build path length 141 exceeds the supported maximum of 140;*') 'An untested long Windows build path was accepted.'
        Assert-EvidenceTest (-not (Test-Path -LiteralPath $longOutput)) 'Build-path length preflight created output.'
        Write-Host 'PASS Windows build paths beyond the measured 140-character support limit are rejected before writes'
    }

    if ($ArduinoCli) {
        Assert-EvidenceTest (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) 'Target evidence tests require -OutputDirectory.'
        $sources = [ordered]@{
            ACompileFailure = "#error AZ3166_EXPECTED_COMPILE_FAILURE`nvoid setup() {}`nvoid loop() {}`n"
            BLinkFailure = "extern void AZ3166_EXPECTED_LINK_FAILURE();`nvoid setup() { AZ3166_EXPECTED_LINK_FAILURE(); }`nvoid loop() {}`n"
            CPreparationFailure = "void setup() {}`nvoid loop() {}`n"
            ZValidEvidence = "void setup() {}`nvoid loop() {}`n"
        }
        $sketches = @(
            foreach ($source in $sources.GetEnumerator()) {
                $directory = Join-Path $fixtureRoot $source.Key
                New-Item -ItemType Directory -Path $directory | Out-Null
                Set-Content -LiteralPath (Join-Path $directory "$($source.Key).ino") -Value $source.Value -Encoding utf8
                if ($source.Key -eq 'ZValidEvidence') { Join-Path $directory "$($source.Key).ino" }
                else { $directory }
            }
        )
        $arguments = @{
            ArduinoCli = $ArduinoCli
            ArduinoDataDirectory = $ArduinoDataDirectory
            ArduinoUnitDirectory = $ArduinoUnitDirectory
            OutputDirectory = $OutputDirectory
            Sketch = $sketches
        }
        $failure = $null
        try {
            & {
                function Copy-Item {
                    [CmdletBinding()]
                    param([string]$LiteralPath, [string]$Destination, [switch]$Recurse)

                    if ((Split-Path -Leaf $Destination) -eq 'compiler-versions.txt' -and
                        (Split-Path -Leaf (Split-Path -Parent $Destination)) -eq 'CPreparationFailure') {
                        throw 'AZ3166_EXPECTED_PREPARATION_FAILURE'
                    }
                    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
                }
                & $driver @arguments
            }
        }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like '3 Arduino test sketch build(s) failed:*') "Expected aggregate failure of three sketches, received: $failure"
        foreach ($name in $sources.Keys) {
            $directory = Join-Path $OutputDirectory $name
            $required = @('build.log', 'build-context.json')
            if ($name -ne 'CPreparationFailure') { $required += 'compiler-versions.txt' }
            foreach ($file in $required) {
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory $file)).Length -gt 0) "Missing retained $name/$file"
            }
            $context = Get-Content -Raw -LiteralPath (Join-Path $directory 'build-context.json') | ConvertFrom-Json
            $logContent = Get-Content -Raw -LiteralPath (Join-Path $directory 'build.log')
            Assert-EvidenceTest ($context.compile.arguments -contains '--verbose') 'The driver did not enable verbose compilation.'
            Assert-EvidenceTest ($context.compilationDatabase.arguments -contains '--only-compilation-database') 'The driver did not explicitly request a compilation database.'
            foreach ($property in @('os', 'architecture', 'powershell', 'tools', 'coreVersion', 'fqbn', 'lockSha256', 'revision', 'dirtyWorktree')) {
                Assert-EvidenceTest ($property -in @($context.environment.PSObject.Properties.Name)) "Missing context identity: $property"
            }
            if ($name -eq 'CPreparationFailure') {
                Assert-EvidenceTest ($context.status -eq 'failed' -and $null -eq $context.compile.exitCode -and
                    $logContent.Contains('AZ3166_EXPECTED_PREPARATION_FAILURE') -and
                    ($context.errors -join ' ').Contains('AZ3166_EXPECTED_PREPARATION_FAILURE')) 'Evidence preparation failure was not retained with an honest unstarted compile status.'
                $summary = Get-Content -Raw -LiteralPath (Join-Path $OutputDirectory 'summary.md')
                Assert-EvidenceTest ($summary.Contains('| CPreparationFailure | failed |') -and $summary.Contains('CPreparationFailure/build.log')) 'Preparation failure was omitted from the retained summary.'
                continue
            }
            if ($name -ne 'ZValidEvidence') {
                $diagnostic = if ($name -eq 'ACompileFailure') { 'AZ3166_EXPECTED_COMPILE_FAILURE' } else { 'AZ3166_EXPECTED_LINK_FAILURE' }
                Assert-EvidenceTest ($context.status -eq 'failed' -and $context.compile.exitCode -ne 0) "Failure exit code was lost for $name"
                Assert-EvidenceTest ($logContent.Contains($diagnostic) -and $logContent.Contains('Error during build')) "Complete diagnostic missing for $name"
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory "build/sketch/$name.ino.cpp")).Length -gt 0) "Generated source was deleted for $name"
                continue
            }
            Assert-EvidenceTest ($context.status -eq 'passed' -and $context.compile.exitCode -eq 0 -and $context.compilationDatabase.exitCode -eq 0) 'Valid sketch after failures was not compiled successfully.'
            foreach ($file in @('compile_commands.json', 'compile_commands.build.json', 'size.txt', 'size.json', "$name.ino.elf", "$name.ino.map", "$name.ino.bin")) {
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory $file)).Length -gt 0) "Missing retained $name/$file"
            }
            $originalEntries = Assert-Az3166CompilationDatabase -Path (Join-Path $directory 'compile_commands.build.json') `
                -SketchSource (Join-Path $directory "build/sketch/$name.ino.cpp")
            Assert-EvidenceTest ($originalEntries -gt 0) 'The ordinary-build database does not describe the selected sketch file.'
            foreach ($artifact in $context.artifacts) {
                $retainedHash = (Get-FileHash -LiteralPath (Join-Path $directory $artifact.name) -Algorithm SHA256).Hash.ToLowerInvariant()
                $originalHash = (Get-FileHash -LiteralPath (Join-Path $directory "build/$($artifact.name)") -Algorithm SHA256).Hash.ToLowerInvariant()
                Assert-EvidenceTest ($retainedHash -ceq $artifact.sha256 -and $retainedHash -ceq $originalHash) 'Evidence copying changed a build artifact.'
            }
            foreach ($tool in @('arm-none-eabi-g++', 'arm-none-eabi-ar', 'arm-none-eabi-gcc', 'arm-none-eabi-objcopy', 'arm-none-eabi-size')) {
                Assert-EvidenceTest ($logContent.Contains($tool)) "Verbose build omitted $tool"
            }
            Assert-EvidenceTest (-not (Test-Path -LiteralPath $context.environment.stagedPlatformDirectory)) 'Private platform staging was not cleaned up.'
        }
        Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $OutputDirectory 'BLinkFailure/BLinkFailure.ino.map')).Length -gt 0) 'Link failure lost its partial map.'
        $objects = @(Get-ChildItem -LiteralPath (Join-Path $OutputDirectory 'BLinkFailure/build') -Filter '*.o' -File -Recurse)
        Assert-EvidenceTest ($objects.Count -gt 0) 'Link failure lost intermediate object files.'
        $before = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'ZValidEvidence/ZValidEvidence.ino.bin')).Hash
        $failure = $null
        try { & $driver @arguments }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like 'Output directory must be empty;*') 'A repeated run accepted stale evidence.'
        Assert-EvidenceTest ($before -ceq (Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'ZValidEvidence/ZValidEvidence.ino.bin')).Hash) 'Rejected reuse modified prior evidence.'
        $invalidLayout = Join-Path $fixtureRoot 'MismatchedName'
        New-Item -ItemType Directory -Path $invalidLayout | Out-Null
        Set-Content -LiteralPath (Join-Path $invalidLayout 'Other.ino') -Value 'void setup() {} void loop() {}' -Encoding utf8
        $fqbn = (Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'tools/build/az3166-build-lock.json') | ConvertFrom-Json).arduino.fqbn
        $layoutSketchbook = Join-Path $fixtureRoot 'layout-sketchbook'
        . (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
        Copy-Az3166Platform -RepositoryRoot $repositoryRoot -Destination (Join-Path $layoutSketchbook 'hardware/AZ3166Checkout/stm32f4')
        $layoutConfig = Join-Path $OutputDirectory 'invalid-sketch-layout-config.json'
        @{
            directories = @{
                data = [IO.Path]::GetFullPath($ArduinoDataDirectory)
                downloads = Join-Path $fixtureRoot 'layout-downloads'
                user = $layoutSketchbook
            }
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $layoutConfig -Encoding utf8
        $invalidResult = Invoke-Az3166EvidenceProcess -FilePath $ArduinoCli `
            -Arguments @('--config-file', $layoutConfig, 'compile', '--fqbn', $fqbn, '--only-compilation-database', $invalidLayout) `
            -LogPath (Join-Path $OutputDirectory 'invalid-sketch-layout.log') -CaptureOutput
        Assert-EvidenceTest ($invalidResult.ExitCode -ne 0 -and $invalidResult.Output.Contains('main file missing from sketch')) 'Pinned CLI unexpectedly accepted a sketch without its matching main file.'
        Write-Host 'PASS compiler/linker and evidence-preparation failures, complete diagnostics, partial artifacts, continued builds, native statuses, identities, space-containing paths, and stale-evidence rejection'
    }
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}