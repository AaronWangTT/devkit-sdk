#requires -Version 7.0

function ConvertFrom-Az3166NmOutput {
    param([AllowEmptyCollection()][string[]]$Lines)

    foreach ($line in $Lines) {
        $record = $line.Trim()
        if ($record.Length -eq 0 -or $record -match '^.+:\s*$') { continue }
        if ($record -notmatch '^(?:.+:\s+)?(?<name>\S+)\s+(?<type>[A-Za-z?])(?:\s+[0-9a-fA-F]+(?:\s+[0-9a-fA-F]+)?)?\s*$') {
            throw "Unsupported POSIX nm record: $line"
        }
        [pscustomobject]@{ Name = $Matches.name; Type = $Matches.type }
    }
}