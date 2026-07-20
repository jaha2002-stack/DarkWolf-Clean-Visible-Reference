[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/60-dxr-v2.2-quality-lab3-shadow-quality-selection-hybrid-blas.patch'

# Exact Git blobs after patch 10 -> 20 -> 30 -> 40 -> 50 Quality Lab 2.
$ExpectedQL2Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = 'eaf7b9ae5d952d0596a1ea2b502b4bab805a94dd'
    'src/opengl/gl_d3d12shim.cpp'     = 'c1883ead4fe7bd840f26d1fa96cce0a12ae77142'
    'src/opengl/opengl.h'             = '4bd993568149b86b8a02e5c6d48e36e1d16aaefe'
    'src/renderer/tr_backend.cpp'     = 'e1e5ebf39ff0e5dca0658719686868a87b0a697d'
    'src/renderer/tr_cmesh.cpp'       = '28d6a4462df60bcaa9181a268be1491ff55b35b5'
    'src/renderer/tr_init.cpp'        = '90039d1a2159504078a8421646e466778b3dbd70'
    'src/renderer/tr_local.h'         = '7c925803f3739cb1ca9723796b581b44beab4bda'
    'src/renderer/tr_mesh.cpp'        = 'd47ecaf1c4eba9e5399343e2c1e74b4b2cf3fda7'
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

function Assert-QualityLab3Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $shim = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12shim.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $init = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_init.cpp') -Raw
    $local = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_local.h') -Raw
    $api = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/opengl.h') -Raw
    $mesh = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_mesh.cpp') -Raw
    $cmesh = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_cmesh.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'gPointShadowRadiusScale'; Name = 'point-light source-size control' },
        @{ Text = $ray; Pattern = 'FilterShadowHistory('; Name = 'temporal edge-aware shadow filter' },
        @{ Text = $ray; Pattern = 'gShadowHistoryOut'; Name = 'shadow-history UAV' },
        @{ Text = $ray; Pattern = 'frameRotation = (gShadowTemporalEnabled != 0)'; Name = 'temporal source-sample rotation' },
        @{ Text = $ray; Pattern = 'selectedReservedLocalCount'; Name = 'local-light reservation diagnostics' },
        @{ Text = $ray; Pattern = 'g_glRaytracingDynamicMode = 0'; Name = 'hybrid BLAS auto policy' },
        @{ Text = $ray; Pattern = 'static_assert(sizeof(glRaytracingLightingConstants_t) == 320'; Name = 'C++/HLSL constant layout guard' },
        @{ Text = $shim; Pattern = 'pass.previousPositionTexture = previousPosition'; Name = 'previous-position reprojection guide' },
        @{ Text = $shim; Pattern = 'pass.velocityTexture = sceneVelocity'; Name = 'motion-vector reprojection guide' },
        @{ Text = $backend; Pattern = 'DXR v2.2 Quality Lab 3:'; Name = 'QL3 runtime marker' },
        @{ Text = $backend; Pattern = 'glRaytracingLightingSetShadowFilterOptions'; Name = 'shadow filter CVar upload' },
        @{ Text = $backend; Pattern = 'glRaytracingLightingSetLightSelectionOptions'; Name = 'light selection CVar upload' },
        @{ Text = $init; Pattern = 'r_dxrDynamicBLASMode'; Name = 'hybrid BLAS CVar' },
        @{ Text = $local; Pattern = 'r_dxrShadowSpatialNormalPower'; Name = 'edge-aware CVar declaration' },
        @{ Text = $api; Pattern = 'glRaytracingLightingResetHistory'; Name = 'history reset API' },
        @{ Text = $mesh; Pattern = 'Component models can have fewer frames'; Name = 'generic MD3 frame normalization' },
        @{ Text = $cmesh; Pattern = 'Component models can have fewer frames'; Name = 'generic MDC frame normalization' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required Quality Lab 3 marker missing: $($item.Name)"
        }
    }

    if ($backend.Contains('DXR v2.3 shadow-composite:')) {
        throw 'Experimental v2.3 source was mixed into Quality Lab 3.'
    }

    # Prevent recurrence of MSVC C2026: every embedded HLSL literal stays below
    # the conservative 8000-byte limit used by the validated patch pipeline.
    $matches = [regex]::Matches(
        $ray,
        'R"QL3HLSL\((.*?)\)QL3HLSL"',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matches.Count -lt 2) {
        throw 'QL3 embedded HLSL chunks were not found.'
    }
    foreach ($match in $matches) {
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($match.Groups[1].Value)
        if ($bytes -gt 8000) {
            throw "Embedded HLSL chunk exceeds 8000 bytes: $bytes"
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
        Write-Host 'Quality Lab 3 patch is already applied.'
        Assert-QualityLab3Markers
        exit 0
    }

    foreach ($entry in $ExpectedQL2Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required QL2 source file is missing: $($entry.Key)"
        }
        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Quality Lab 2 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nApply patches 10, 20, 30, 40 and 50 first. Do not apply patch 60 over a mixed source tree."
        }
        Write-Host "QL2 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Quality Lab 3 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Quality Lab 3.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Quality Lab 3 patch.`n$($diffCheck.Output)"
    }

    Assert-QualityLab3Markers
    Write-Host 'DarkWolf DXR v2.2 Quality Lab 3 patch applied successfully.'
}
finally {
    Pop-Location
}
