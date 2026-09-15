#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArduinoCli,
    [Parameter(Mandatory)][string]$ArduinoDataDirectory,
    [Parameter(Mandatory)][string]$ArduinoUnitDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The locked target equivalence harness requires Windows.' }
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'Az3166BuildEvidence.ps1')
. (Join-Path $PSScriptRoot 'Az3166CompilerParameters.ps1')
. (Join-Path $repositoryRoot 'tools/package/Az3166PackageLayout.ps1')
$baseline = Get-Az3166CompilerBaseline -RepositoryRoot $repositoryRoot
$sourceRevision = Invoke-Az3166LayoutGit $repositoryRoot @('rev-parse', 'HEAD')
$root = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $root) { throw "Equivalence output must not exist: $root" }
$payloadRoots = @('src', 'vendor', 'libraries', 'examples', 'tests/hardware', 'platform/az3166', 'tools/build')
$changed = @((Invoke-Az3166LayoutGit $repositoryRoot (@('diff', '--name-only', 'HEAD', '--') + $payloadRoots)) -split '\r?\n') +
    @((Invoke-Az3166LayoutGit $repositoryRoot (@('ls-files', '--others', '--exclude-standard', '--') + $payloadRoots)) -split '\r?\n')
if (@($changed | Where-Object { $_ -and $_ -notin @('platform/az3166/platform.txt', 'platform/az3166/boards.txt') }).Count -gt 0) {
    throw 'Commit or set aside unrelated payload/toolchain changes before comparing compiler properties.'
}
$candidate = @{
    Platform = [IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'platform/az3166/platform.txt'))
    Boards = [IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'platform/az3166/boards.txt'))
}
$checkout = Join-Path $root 'source'
$buildRoot = Join-Path $root 'build'
$fixedStage = Join-Path $root 'staging'
$git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
$previousDirectory = [Environment]::CurrentDirectory

function Invoke-Az3166FixedRootBuild {
    param([string]$DriverPath, [string]$FixedStagingDirectory, [hashtable]$BuildArguments)

    $routing = @{ Count = 0 }
    function Join-Path {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)][string[]]$Path,
            [Parameter(Position = 1)][string]$ChildPath,
            [Parameter(Position = 2, ValueFromRemainingArguments)][string[]]$AdditionalChildPath
        )

        if ($Path.Count -eq 1 -and $Path[0] -eq [IO.Path]::GetTempPath() -and
            $ChildPath -cmatch '\Aaz3166-tests-[0-9a-f]{32}\z') {
            $routing['Count']++
            return $FixedStagingDirectory
        }
        Microsoft.PowerShell.Management\Join-Path @PSBoundParameters
    }
    & $DriverPath @BuildArguments
    if ($routing['Count'] -ne 1) { throw 'The driver did not use exactly one controlled private staging root.' }
    if (Test-Path -LiteralPath $FixedStagingDirectory) { throw 'Private staging was not cleaned between comparison builds.' }
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $result = Invoke-Az3166EvidenceProcess -FilePath $git -Arguments @('clone', '--quiet', '--no-hardlinks', '--no-checkout', '--', $repositoryRoot, $checkout) `
        -LogPath (Join-Path $root 'harness.log')
    if ($result.ExitCode -ne 0) { throw 'Could not create the isolated equivalence checkout.' }
    $result = Invoke-Az3166EvidenceProcess -FilePath $git -Arguments @('-C', $checkout, 'checkout', '--quiet', '--detach', $sourceRevision) `
        -LogPath (Join-Path $root 'harness.log')
    if ($result.ExitCode -ne 0) { throw 'Could not check out the comparison source revision.' }
    $driverIdentities = @(
        foreach ($driverFile in @('Test-Az3166Sketches.ps1', 'Az3166BuildEvidence.ps1')) {
            $path = Join-Path $checkout "tools/test/$driverFile"
            [ordered]@{ path = "tools/test/$driverFile"; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    )
    [Environment]::CurrentDirectory = $checkout
    $captures = @{}
    foreach ($phase in @('before', 'after')) {
        $phaseDirectory = Join-Path $root $phase
        foreach ($propertyFile in @(@{ Name = 'Platform'; Path = 'platform.txt' }, @{ Name = 'Boards'; Path = 'boards.txt' })) {
            $destination = Join-Path $checkout "platform/az3166/$($propertyFile.Path)"
            if ($phase -eq 'before') {
                [IO.File]::WriteAllText($destination, $baseline[$propertyFile.Name], [Text.UTF8Encoding]::new($false))
            }
            else {
                [IO.File]::WriteAllBytes($destination, $candidate[$propertyFile.Name])
            }
        }
        try {
            Invoke-Az3166FixedRootBuild -DriverPath (Join-Path $checkout 'tools/test/Test-Az3166Sketches.ps1') `
                -FixedStagingDirectory $fixedStage -BuildArguments @{
                    ArduinoCli = $ArduinoCli
                    ArduinoDataDirectory = $ArduinoDataDirectory
                    ArduinoUnitDirectory = $ArduinoUnitDirectory
                    OutputDirectory = $buildRoot
                }
        }
        finally {
            if (Test-Path -LiteralPath $buildRoot -PathType Container) {
                Move-Item -LiteralPath $buildRoot -Destination $phaseDirectory
            }
        }
        foreach ($propertyFile in @('platform.txt', 'boards.txt')) {
            Copy-Item -LiteralPath (Join-Path $checkout "platform/az3166/$propertyFile") -Destination (Join-Path $phaseDirectory $propertyFile)
        }
        $sketches = @(Get-ChildItem -LiteralPath $phaseDirectory -Directory -Force | Sort-Object Name -CaseSensitive)
        if ($sketches.Count -ne 13) { throw "Expected the 13-sketch baseline, found $($sketches.Count)." }
        $captures[$phase] = @($sketches | ForEach-Object { Export-Az3166CompilerEvidence -Directory $_.FullName })
    }
    $comparisons = @(
        foreach ($sketch in $captures.before) {
            Compare-Az3166CompilerEvidence -Before (Join-Path $root "before/$($sketch.sketch)") -After (Join-Path $root "after/$($sketch.sketch)")
        }
    )
    $report = [ordered]@{
        schemaVersion = 1
        baselineRevision = $baseline.Revision
        sourceRevision = $sourceRevision
        fixedCheckout = $checkout
        fixedBuildRoot = $buildRoot
        fixedStagingRoot = $fixedStage
        driverScripts = $driverIdentities
        canonicalization = @('CLI quoted-string escaping', 'preprocessor -o <temporary directory>/<digits>/sketch_merged.cpp only', 'contiguous parallel compiler/assembler groups only; sequential commands and argument order unchanged', 'complete database compiler records compared independently of parallel entry order; raw files and hashes retained')
        commandCaptures = $captures
        comparisons = $comparisons
        passed = @($comparisons | Where-Object { -not $_.passed }).Count -eq 0
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'comparison.json') -Encoding utf8
    $comparisons | ForEach-Object { Write-Host "$($_.sketch): equal=$($_.passed)" }
    if (-not $report.passed) { throw "Compiler normalization equivalence failed; inspect $root/comparison.json" }
    Write-Host 'PASS all 13 command sequences, binaries, complete ELFs, section sizes/program headers, and complete maps are identical.'
}
finally {
    [Environment]::CurrentDirectory = $previousDirectory
}