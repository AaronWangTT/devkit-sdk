#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $repositoryRoot 'tools/build/Az3166Build.Common.ps1')
. (Join-Path $repositoryRoot 'tools/test/Az3166CompilerParameters.ps1')
$lock = Get-Az3166BuildLock
$baseline = Get-Az3166CompilerBaseline -RepositoryRoot $repositoryRoot
$board = $lock.arduino.fqbn.Split(':')[2]
$before = Get-Az3166RecipeProperties -Platform $baseline.Platform -Boards $baseline.Boards -Board $board
$after = Get-Az3166RecipeProperties `
    -Platform (Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'platform/az3166/platform.txt')) `
    -Boards (Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'platform/az3166/boards.txt')) -Board $board

function Assert-CompilerParameters {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

foreach ($group in @(
    'compiler.cpu.flags', 'build.instruction_set.flags', 'build.float_abi.flags', 'build.fpu.flags',
    'compiler.optimization.flags', 'compiler.debug.flags', 'compiler.language.c.flags', 'compiler.language.cpp.flags',
    'compiler.codegen.sections.flags', 'compiler.codegen.dependencies.flags', 'compiler.defines.target',
    'compiler.defines.assembly', 'compiler.defines.arduino', 'compiler.includes.system', 'compiler.includes.mbed',
    'compiler.includes.bsp', 'compiler.includes.azure', 'compiler.includes.core', 'compiler.warnings.first_party',
    'compiler.warnings.historical', 'compiler.link.diagnostics.flags', 'compiler.link.script.flags',
    'compiler.link.map.flags', 'compiler.link.sections.flags', 'compiler.link.search.flags', 'compiler.link.wrap.flags',
    'compiler.link.libraries.flags', 'compiler.link.specs.flags', 'compiler.link.symbols.flags'
)) {
    Assert-CompilerParameters ($after.ContainsKey($group) -and -not [string]::IsNullOrWhiteSpace($after[$group])) "Missing named compiler-parameter group: $group"
}

$properties = @(
    'compiler.c.flags', 'compiler.cpp.flags', 'compiler.S.flags', 'compiler.c.elf.flags',
    'compiler.ar.flags', 'compiler.objcopy.eep.flags', 'compiler.elf2hex.flags',
    'compiler.libstm.c.flags', 'build.extra_flags',
    'recipe.c.o.pattern', 'recipe.cpp.o.pattern', 'recipe.S.o.pattern',
    'recipe.ar.pattern', 'recipe.c.combine.pattern', 'recipe.objcopy.bin.pattern', 'recipe.size.pattern'
)
foreach ($profile in @('none', 'default', 'more', 'all')) {
    $before['compiler.warning_flags'] = $before["compiler.warning_flags.$profile"]
    $after['compiler.warning_flags'] = $after["compiler.warning_flags.$profile"]
    foreach ($name in $properties) {
        $expected = Expand-Az3166RecipeProperty -Properties $before -Name $name
        $actual = Expand-Az3166RecipeProperty -Properties $after -Name $name
        Assert-CompilerParameters ($expected -ceq $actual) "Expanded property changed for ${profile}/${name}.`nExpected: $expected`nActual: $actual"
    }
}
Write-Host 'PASS all compiler/assembler/archive/link/objcopy/size recipes and flags expand identically for all warning profiles'

$fixture = @{ root = 'before {group} {unknown} after'; group = '-O2 {debug}'; debug = '-g' }
Assert-CompilerParameters ((Expand-Az3166RecipeProperty $fixture 'root') -ceq 'before -O2 -g {unknown} after') 'Recursive expansion lost argument order or unresolved runtime properties.'
$fixture['debug'] = '{group}'
$rejected = $false
try { $null = Expand-Az3166RecipeProperty $fixture 'root' }
catch { $rejected = $true }
Assert-CompilerParameters $rejected 'A recursive property cycle was accepted.'
Write-Host 'PASS recursive property expansion preserves order and detects cycles'

$changed = $after.Clone()
$changed['compiler.c.flags'] = '-DUNEXPECTED ' + $changed['compiler.c.flags']
Assert-CompilerParameters ((Expand-Az3166RecipeProperty $changed 'recipe.c.o.pattern') -cne
    (Expand-Az3166RecipeProperty $after 'recipe.c.o.pattern')) 'The contract failed to detect an added compiler argument.'
Write-Host 'PASS an injected compiler flag changes the expanded command'

$arguments = ConvertFrom-Az3166VerboseCommand '"C:\\tool path\\arm-none-eabi-g++.exe" -c "-IC:\\source path" "-DVALUE=\"quoted\"" "C:\\build path\\Sketch.ino.cpp"'
Assert-CompilerParameters ($arguments.Count -eq 5 -and $arguments[0] -ceq 'C:\tool path\arm-none-eabi-g++.exe' -and
    $arguments[2] -ceq '-IC:\source path' -and $arguments[3] -ceq '-DVALUE="quoted"' -and
    $arguments[4] -ceq 'C:\build path\Sketch.ino.cpp') 'Verbose command parsing changed quoted argument boundaries.'
Write-Host 'PASS CLI-rendered tokens preserve spaces, defines, and escaped paths/quotes'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "az3166 parameters $([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $logPath = Join-Path $fixtureRoot 'commands.log'
    $compilerPath = Join-Path $fixtureRoot 'arm-none-eabi-gcc'
    $compiler = ConvertTo-Json -InputObject $compilerPath -Compress
    $archiverCommand = ConvertTo-Json -InputObject (Join-Path $fixtureRoot 'arm-none-eabi-ar') -Compress
    $objcopyCommand = ConvertTo-Json -InputObject (Join-Path $fixtureRoot 'arm-none-eabi-objcopy') -Compress
    $sizeCommand = ConvertTo-Json -InputObject (Join-Path $fixtureRoot 'arm-none-eabi-size') -Compress
    $lines = @(
        "$compiler -c input.c -o output.o"
        "$compiler -c other.c -o other.o"
        "$archiverCommand rcs core.a first.o second.o"
        "$compiler first.o core.a -o firmware.elf"
        "$objcopyCommand -O binary firmware.elf firmware.bin"
        "$sizeCommand -A firmware.elf"
        "$compiler -E source.cpp -o $(ConvertTo-Json -InputObject (Join-Path ([IO.Path]::GetTempPath()) '123456/sketch_merged.cpp') -Compress)"
    )
    $lines | Set-Content -LiteralPath $logPath -Encoding utf8
    $captured = Get-Az3166BuildCommands -LogPath $logPath
    Assert-CompilerParameters (@($captured | Where-Object { $_.kind -ceq 'compiler' })[0].arguments[0] -ceq
        $compilerPath) 'The space-containing compiler path was not preserved as one argument.'
    Assert-CompilerParameters (@($captured | Where-Object { $_.kind -ceq 'preprocessor' })[0].arguments[-1] -ceq
        '<arduino-preprocess>/sketch_merged.cpp') 'The CLI-only preprocessing path was not canonicalized.'
    $archiver = @($captured | Where-Object { $_.kind -ceq 'archiver' })[0]
    Assert-CompilerParameters (($archiver.arguments[-2..-1] -join ',') -ceq 'first.o,second.o') 'Archiver object order was changed.'
    $parallelReordered = @($lines[1], $lines[0]) + $lines[2..($lines.Count - 1)]
    $parallelReordered | Set-Content -LiteralPath $logPath -Encoding utf8
    $canonical = ConvertTo-Json -InputObject $captured -Depth 5 -Compress
    Assert-CompilerParameters ($canonical -ceq (ConvertTo-Json -InputObject (Get-Az3166BuildCommands $logPath) -Depth 5 -Compress)) 'Independent compiler reordering changed the comparison.'
    $sequentialReordered = @($lines[0], $lines[1], $lines[2], $lines[4], $lines[3], $lines[5], $lines[6])
    $sequentialReordered | Set-Content -LiteralPath $logPath -Encoding utf8
    Assert-CompilerParameters ($canonical -cne (ConvertTo-Json -InputObject (Get-Az3166BuildCommands $logPath) -Depth 5 -Compress)) 'Linker/objcopy phase reordering was hidden.'
    ($lines | Where-Object { $_ -notmatch 'arm-none-eabi-objcopy' }) | Set-Content -LiteralPath $logPath -Encoding utf8
    $rejected = $false
    try { $null = Get-Az3166BuildCommands -LogPath $logPath }
    catch { $rejected = $true }
    Assert-CompilerParameters $rejected 'Missing required command coverage was accepted.'
    Write-Host 'PASS narrow CLI temporary-path canonicalization, object ordering, and required command coverage'

    $databasePath = Join-Path $fixtureRoot 'database.json'
    '[{"directory":"fixed","file":"source.cpp","arguments":["g++","-c","source.cpp"]}]' |
        Set-Content -LiteralPath $databasePath -Encoding utf8
    Assert-CompilerParameters ((Get-Az3166CompilerDatabase $databasePath).Count -eq 1) 'Pinned CLI arguments-form database was rejected.'
    foreach ($invalid in @('[]', '{}', '[{"command":"g++ -c source.cpp","file":"source.cpp"}]', '[{"arguments":null}]', '[{"arguments":[1]}]')) {
        Set-Content -LiteralPath $databasePath -Value $invalid -Encoding utf8
        $rejected = $false
        try { $null = Get-Az3166CompilerDatabase $databasePath }
        catch { $rejected = $true }
        Assert-CompilerParameters $rejected "Unsupported compiler database was accepted: $invalid"
    }
    Write-Host 'PASS pinned CLI arguments-form database is explicit and command-string entries are rejected'

    $harnessPath = Join-Path $repositoryRoot 'tools/test/Test-Az3166CompilerParameters.ps1'
    $routingFunction = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$null, [ref]$null).Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-Az3166FixedRootBuild'
    }, $true)
    . ([scriptblock]::Create($routingFunction.Extent.Text))
    $fakeDriver = Join-Path $fixtureRoot 'driver.ps1'
    @'
param([int]$Calls, [string]$Expected)
for ($index = 0; $index -lt $Calls; $index++) {
    $actual = Join-Path ([IO.Path]::GetTempPath()) "az3166-tests-$([guid]::NewGuid().ToString('N'))"
    if ($actual -cne $Expected) { throw 'Staging path was not intercepted.' }
}
'@ | Set-Content -LiteralPath $fakeDriver -Encoding utf8
    $fixedStaging = Join-Path $fixtureRoot 'controlled-staging'
    Invoke-Az3166FixedRootBuild -DriverPath $fakeDriver -FixedStagingDirectory $fixedStaging -BuildArguments @{ Calls = 1; Expected = $fixedStaging }
    foreach ($calls in @(0, 2)) {
        $rejected = $false
        try { Invoke-Az3166FixedRootBuild -DriverPath $fakeDriver -FixedStagingDirectory $fixedStaging -BuildArguments @{ Calls = $calls; Expected = $fixedStaging } }
        catch { $rejected = $true }
        Assert-CompilerParameters $rejected "Fixed-root routing accepted $calls intercepted paths."
    }
    Write-Host 'PASS fixed-root routing accepts exactly one intercepted staging path'

    $beforePath = Join-Path $fixtureRoot 'before'
    $afterPath = Join-Path $fixtureRoot 'after'
    $context = @{
        status = 'passed'
        buildDirectory = 'fixed-build'
        environment = @{
            revision = 'same-revision'; lockSha256 = 'same-lock'; fqbn = 'same-board'
            stagedPlatformDirectory = 'fixed-staging'; repository = 'fixed-checkout'
            arduinoDataDirectory = 'fixed-data'; arduinoUnitDirectory = 'fixed-unit'; tools = @{ gcc = 'same-compiler' }
        }
        artifacts = @(@{ name = 'sketch.bin' }, @{ name = 'sketch.elf' }, @{ name = 'sketch.map' })
    }
    $artifactNames = @('commands.json', 'compile_commands.build.json', 'database-commands.json', 'size.txt', 'size.json', 'elf-sections-program-headers.txt', 'sketch.bin', 'sketch.elf', 'sketch.map')
    $databaseFixture = '[{"directory":"fixed","file":"first.cpp","arguments":["g++","first.cpp"],"output":"first.o"},{"directory":"fixed","file":"second.cpp","arguments":["g++","second.cpp"],"output":"second.o"}]'
    foreach ($directory in @($beforePath, $afterPath)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
        $context | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory 'build-context.json') -Encoding utf8
        foreach ($name in $artifactNames) {
            $value = if ($name -in 'compile_commands.build.json', 'database-commands.json') { $databaseFixture } else { "unchanged $name" }
            Set-Content -LiteralPath (Join-Path $directory $name) -Value $value -Encoding utf8
        }
    }
    Assert-CompilerParameters (Compare-Az3166CompilerEvidence -Before $beforePath -After $afterPath).passed 'Identical fixture evidence was rejected.'
    foreach ($name in $artifactNames) {
        Set-Content -LiteralPath (Join-Path $afterPath $name) -Value 'unexpected change' -Encoding utf8
        $comparison = Compare-Az3166CompilerEvidence -Before $beforePath -After $afterPath
        Assert-CompilerParameters (-not $comparison.passed -and @($comparison.files | Where-Object { -not $_.equal }).Count -eq 1) "Changed evidence was not isolated: $name"
        $value = if ($name -in 'compile_commands.build.json', 'database-commands.json') { $databaseFixture } else { "unchanged $name" }
        Set-Content -LiteralPath (Join-Path $afterPath $name) -Value $value -Encoding utf8
    }
    $entries = $databaseFixture | ConvertFrom-Json
    ConvertTo-Json -InputObject @($entries[1], $entries[0]) -Depth 5 | Set-Content -LiteralPath (Join-Path $afterPath 'compile_commands.build.json') -Encoding utf8
    $comparison = Compare-Az3166CompilerEvidence -Before $beforePath -After $afterPath
    $rawDatabase = @($comparison.files | Where-Object { $_.file -ceq 'compile_commands.build.json' })[0]
    Assert-CompilerParameters ($comparison.passed -and -not $rawDatabase.byteEqual) 'Parallel database entry order was not explicitly reported.'
    $entries[0].output = 'different.o'
    ConvertTo-Json -InputObject $entries -Depth 5 | Set-Content -LiteralPath (Join-Path $afterPath 'compile_commands.build.json') -Encoding utf8
    Assert-CompilerParameters (-not (Compare-Az3166CompilerEvidence -Before $beforePath -After $afterPath).passed) 'A raw database field outside the argument projection was dropped.'
    $context.environment.lockSha256 = 'different-lock'
    $context | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $afterPath 'build-context.json') -Encoding utf8
    $rejected = $false
    try { $null = Compare-Az3166CompilerEvidence -Before $beforePath -After $afterPath }
    catch { $rejected = $true }
    Assert-CompilerParameters $rejected 'Different comparison toolchain inputs were accepted.'
    Write-Host 'PASS sequential command order, complete raw database fields, binary/ELF/map/size changes, and toolchain identities are checked'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}