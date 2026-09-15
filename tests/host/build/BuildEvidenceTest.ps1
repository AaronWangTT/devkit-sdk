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
    Write-Host 'PASS compilation database structure and built-sketch identity'

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
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory $summaryRoot -ArtifactUrl 'https://example.test/artifact') -join "`n"
    Assert-EvidenceTest ($summary.Contains('[Failed/build.log](https://example.test/artifact)')) 'CI summary did not link the retained artifact.'
    $summary = (Get-Az3166EvidenceSummary -OutputDirectory (Join-Path $fixtureRoot 'not-created')) -join "`n"
    Assert-EvidenceTest ($summary.Contains('No sketch evidence was produced.')) 'An interrupted setup could not be summarized.'
    Write-Host 'PASS failed builds without firmware retain working summary links'

    $workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github/workflows/core-package-ci.yml')
    $upload = @($workflow -split '\r?\n      - name:' | Where-Object { $_.Contains('id: build-evidence') })
    Assert-EvidenceTest ($upload.Count -eq 1 -and $upload[0].Contains('if: always()') -and $upload[0].Contains('retention-days: 30')) 'CI must always upload build evidence with review retention.'
    Assert-EvidenceTest ($upload[0].Contains('path: ${{ runner.temp }}/az3166-build-evidence')) 'CI does not upload the complete evidence directory.'
    Assert-EvidenceTest ($workflow.Contains('Validate failed-build evidence') -and $workflow.Contains('Get-Az3166EvidenceSummary')) 'CI is missing failed-build validation or the evidence summary.'
    Write-Host 'PASS CI retains complete build evidence on failure and publishes a linked summary'

    if ($ArduinoCli) {
        Assert-EvidenceTest (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) 'Target evidence tests require -OutputDirectory.'
        $driver = Join-Path $repositoryRoot 'tools/test/Test-Az3166Sketches.ps1'
        $sources = [ordered]@{
            ACompileFailure = "#error AZ3166_EXPECTED_COMPILE_FAILURE`nvoid setup() {}`nvoid loop() {}`n"
            BLinkFailure = "extern void AZ3166_EXPECTED_LINK_FAILURE();`nvoid setup() { AZ3166_EXPECTED_LINK_FAILURE(); }`nvoid loop() {}`n"
            ZValidEvidence = "void setup() {}`nvoid loop() {}`n"
        }
        $sketches = @(
            foreach ($source in $sources.GetEnumerator()) {
                $directory = Join-Path $fixtureRoot $source.Key
                New-Item -ItemType Directory -Path $directory | Out-Null
                Set-Content -LiteralPath (Join-Path $directory "$($source.Key).ino") -Value $source.Value -Encoding utf8
                $directory
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
        try { & $driver @arguments }
        catch { $failure = $_.Exception.Message }
        Assert-EvidenceTest ($failure -like '2 Arduino test sketch build(s) failed:*') "Expected aggregate failure of two sketches, received: $failure"
        foreach ($name in $sources.Keys) {
            $directory = Join-Path $OutputDirectory $name
            foreach ($file in @('build.log', 'build-context.json', 'compiler-versions.txt')) {
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory $file)).Length -gt 0) "Missing retained $name/$file"
            }
            $context = Get-Content -Raw -LiteralPath (Join-Path $directory 'build-context.json') | ConvertFrom-Json
            $logContent = Get-Content -Raw -LiteralPath (Join-Path $directory 'build.log')
            Assert-EvidenceTest ($context.compile.arguments -contains '--verbose') 'The driver did not enable verbose compilation.'
            Assert-EvidenceTest ($context.compilationDatabase.arguments -contains '--only-compilation-database') 'The driver did not explicitly request a compilation database.'
            foreach ($property in @('os', 'architecture', 'powershell', 'tools', 'coreVersion', 'fqbn', 'lockSha256', 'revision', 'dirtyWorktree')) {
                Assert-EvidenceTest ($property -in @($context.environment.PSObject.Properties.Name)) "Missing context identity: $property"
            }
            if ($name -ne 'ZValidEvidence') {
                $diagnostic = if ($name -eq 'ACompileFailure') { 'AZ3166_EXPECTED_COMPILE_FAILURE' } else { 'AZ3166_EXPECTED_LINK_FAILURE' }
                Assert-EvidenceTest ($context.status -eq 'failed' -and $context.compile.exitCode -ne 0) "Failure exit code was lost for $name"
                Assert-EvidenceTest ($logContent.Contains($diagnostic) -and $logContent.Contains('Error during build')) "Complete diagnostic missing for $name"
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory "build/sketch/$name.ino.cpp")).Length -gt 0) "Generated source was deleted for $name"
                continue
            }
            Assert-EvidenceTest ($context.status -eq 'passed' -and $context.compile.exitCode -eq 0 -and $context.compilationDatabase.exitCode -eq 0) 'Valid sketch after failures was not compiled successfully.'
            foreach ($file in @('compile_commands.json', 'size.txt', 'size.json', "$name.ino.elf", "$name.ino.map", "$name.ino.bin")) {
                Assert-EvidenceTest ((Get-Item -LiteralPath (Join-Path $directory $file)).Length -gt 0) "Missing retained $name/$file"
            }
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
        Assert-EvidenceTest ($failure -like 'Sketch output already exists;*') 'A repeated run accepted stale evidence.'
        Assert-EvidenceTest ($before -ceq (Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'ZValidEvidence/ZValidEvidence.ino.bin')).Hash) 'Rejected reuse modified prior evidence.'
        Write-Host 'PASS real compiler/linker failures, complete diagnostics, partial artifacts, continued builds, native statuses, identities, space-containing paths, and stale-evidence rejection'
    }
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}