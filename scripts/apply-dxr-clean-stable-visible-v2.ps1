[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/20-dxr-clean-stable-visible-v2.patch'

# These are Git blob hashes of the six files after the proven Clean Visible
# Reference patch (10-...) has been applied. The v2 patch is intentionally
# tied to that exact visual baseline and is not a v6/v7 overlay.
$ExpectedReferenceBlobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = 'a6219e6e879b066b19a61190328f0d608ed7352e'
    'src/opengl/opengl.h'             = '2346afbb2b7def952b65d938dce958dbe3a925fe'
    'src/renderer/tr_backend.cpp'      = '1204b8e20bfd6b36f98187b1c845a107ef24ead5'
    'src/renderer/tr_bsp.cpp'          = 'de497a25a98e8aaf99741230a22ad8b0219b99c1'
    'src/renderer/tr_init.cpp'         = 'e85310bba99e5f197e9ce235418c0cf6877d857a'
    'src/renderer/tr_local.h'          = '1816efa0d238c1129f030b15e93e3f5b5fbd7797'
}

function Invoke-GitChecked {
    param([string[]]$Arguments)
    $output = & git @Arguments 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Output = ($output -join [Environment]::NewLine) }
}

function Get-WorkingBlobHash {
    param([string]$RelativePath)
    $hash = (& git hash-object -- $RelativePath 2>$null).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or -not $hash) {
        throw "Unable to hash source file: $RelativePath"
    }
    return $hash
}

function Assert-StableVisibleMarkers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $bsp = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_bsp.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'float3 rtLitColor = albedo * lightingAccum + specularAccum;'; Name = 'Clean Reference visible relighting' },
        @{ Text = $ray; Pattern = 'glRaytracingLightingPrepareSelectedLights'; Name = 'importance light selection' },
        @{ Text = $ray; Pattern = 'gLegacyShadowStrength'; Name = 'legacy shadow modulation' },
        @{ Text = $ray; Pattern = 'gContactShadows'; Name = 'contact shadows' },
        @{ Text = $ray; Pattern = 'static_assert(sizeof(glRaytracingLightingConstants_t) == 256'; Name = 'constant-buffer layout check' },
        @{ Text = $backend; Pattern = 'RB_HashDXRGeometry'; Name = 'dynamic geometry cache' },
        @{ Text = $backend; Pattern = 'DXR v2:'; Name = 'v2 runtime marker' },
        @{ Text = $backend; Pattern = 'if (r_dxrCpuSync && r_dxrCpuSync->integer)'; Name = 'optional CPU synchronization' },
        @{ Text = $bsp; Pattern = 'r_dxrAlphaShadowGeometry'; Name = 'alpha-shadow geometry inclusion' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required marker missing after v2 patch: $($item.Name)"
        }
    }

    $forbidden = @(
        @{ Text = $ray; Pattern = 'MessageBoxA(nullptr, buffer, "glRaytracing Fatal"'; Name = 'blocking fatal dialog' },
        @{ Text = $ray; Pattern = 'CopyResource(backBuffer, pass->outputTexture)'; Name = 'unsafe direct swapchain copy' },
        @{ Text = $ray; Pattern = 'authoredHeadroom'; Name = 'v6.2 gameplay suppression' }
    )

    foreach ($item in $forbidden) {
        if ($item.Text.Contains($item.Pattern)) {
            throw "Forbidden marker found after v2 patch: $($item.Name)"
        }
    }
}

Push-Location $RepoRoot
try {
    if (!(Test-Path -LiteralPath $PatchPath)) {
        throw "Patch file not found: $PatchPath"
    }

    $reverse = Invoke-GitChecked @('apply', '--reverse', '--check', $PatchPath)
    if ($reverse.Code -eq 0) {
        Write-Host 'Clean Stable Visible v2 patch is already applied.'
        Assert-StableVisibleMarkers
        exit 0
    }

    foreach ($entry in $ExpectedReferenceBlobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required reference source file is missing: $($entry.Key)"
        }

        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Clean Visible Reference mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nApply patch 10 first and do not mix v6/v7 files into this repository."
        }
        Write-Host "Reference blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Stable Visible v2 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Stable Visible v2.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Stable Visible v2 patch.`n$($diffCheck.Output)"
    }

    Assert-StableVisibleMarkers
    Write-Host 'DarkWolf DXR Clean Stable Visible v2 patch applied successfully.'
}
finally {
    Pop-Location
}
