#requires -Version 7.0

function Assert-Az3166ReleaseRequest {
    param([string]$Version, [string]$Profile, $LayoutManifest, [string]$CoreVersion, [string]$LegacyVersion)

    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'Release version must be a numeric semantic version.'
    }
    if ($Profile -cnotin @('base', 'azure-iot')) { throw 'Release profile must be base or azure-iot.' }
    if ($CoreVersion -cne $Version) { throw 'Release tag does not match the core runtime version.' }
    if (([version]$Version).Major -ne (([version]$LegacyVersion).Major + 1)) {
        throw 'Profile-based publication requires the approved next major core version.'
    }
    if (-not $LayoutManifest.PSObject.Properties['defaultProfile'] -or $LayoutManifest.defaultProfile -cne 'base') {
        throw 'Profile-based publication requires defaultProfile to remain base.'
    }
    if ($LayoutManifest.schemaVersion -ne 2 -or -not $LayoutManifest.PSObject.Properties['releaseProfile'] -or
        $LayoutManifest.releaseProfile -cne $Profile) {
        throw 'Release profile must match releaseProfile recorded in the tagged package layout.'
    }
}

function New-Az3166ReleaseMetadata {
    param([string]$Version, [string]$Profile, [string]$Revision, [string]$Repository,
        [string]$PackagePath, [string]$ExpectedSHA256)

    if ($Profile -cnotin @('base', 'azure-iot') -or
        $Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        $Revision -cnotmatch '^[0-9a-f]{40,64}$' -or
        $Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or
        $ExpectedSHA256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid release metadata inputs.' }
    $fileName = [IO.Path]::GetFileName($PackagePath)
    if ($fileName -cne "AZ3166-$Version-$Profile.zip") { throw 'Package filename does not match the release version/profile.' }
    $hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $ExpectedSHA256) { throw 'Release package changed after verification.' }
    return [ordered]@{
        schemaVersion = 1
        profile = $Profile
        revision = $Revision
        repository = $Repository
        boardManagerUpdate = [ordered]@{
            version = $Version
            url = "https://github.com/$Repository/releases/download/$Version/$fileName"
            archiveFileName = $fileName
            checksum = "SHA-256:$hash"
            size = [string](Get-Item -LiteralPath $PackagePath).Length
        }
    }
}