[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/40-dxr-v2.2-quality-lab1-multilight-composite.patch'

# Exact Git blob hashes after patch 10 -> patch 20 Stable Clear v2.1 -> patch 30 v2.2.
# Quality Lab 1 must never be applied to v2.3 or to a mixed v6/v7 tree.
$ExpectedV22Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = '0f779861ee2335459be850f1ca38c0a5430bd5d9'
    'src/opengl/opengl.h'             = 'b17240e3d8eacf0dbfde8679fbde18dcff3cd1ce'
    'src/renderer/tr_backend.cpp'     = 'ab8a8a7d2e4d027ce57cdb3929303f9d5fa5bdbd'
    'src/renderer/tr_init.cpp'        = '8258b2d38bd810d3353603f0e0eccad1180b628a'
    'src/renderer/tr_local.h'         = '0ae73546440c684b26dcaeb4e053cb6e877853ce'
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

function Assert-QualityLab1Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $init = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_init.cpp') -Raw
    $local = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_local.h') -Raw
    $api = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/opengl.h') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'float3 authoredDirectUnshadowed = 0.0;'; Name = 'unshadowed authored-light accumulator' },
        @{ Text = $ray; Pattern = 'float3 authoredDirectShadowed = 0.0;'; Name = 'shadowed authored-light accumulator' },
        @{ Text = $ray; Pattern = 'float multiLightVisibility'; Name = 'energy-weighted multi-light visibility' },
        @{ Text = $ray; Pattern = 'ApplyAcesHighlightCompression'; Name = 'highlight compression' },
        @{ Text = $ray; Pattern = 'gFallbackDiffuseScale'; Name = 'camera-fill diffuse limiter' },
        @{ Text = $ray; Pattern = 'gDebugMode == 6'; Name = 'unshadowed-direct diagnostic mode' },
        @{ Text = $ray; Pattern = 'gDebugMode == 7'; Name = 'shadowed-direct diagnostic mode' },
        @{ Text = $ray; Pattern = 'gDebugMode == 9'; Name = 'camera-fill diagnostic mode' },
        @{ Text = $backend; Pattern = 'DXR v2.2 Quality Lab 1:'; Name = 'Quality Lab 1 runtime marker' },
        @{ Text = $backend; Pattern = 'glRaytracingLightingSetCompositeOptions'; Name = 'composite options upload' },
        @{ Text = $backend; Pattern = 'r_dxrDebugLights'; Name = 'selected-light dump control' },
        @{ Text = $init; Pattern = 'r_dxrFallbackDiffuseScale'; Name = 'fallback diffuse CVar' },
        @{ Text = $init; Pattern = 'r_dxrHighlightCompression'; Name = 'highlight compression CVar' },
        @{ Text = $local; Pattern = 'extern cvar_t   *r_dxrDebugLights'; Name = 'debug light CVar declaration' },
        @{ Text = $api; Pattern = 'glRaytracingLightingGetSelectedLight'; Name = 'selected-light diagnostic API' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required Quality Lab 1 marker missing: $($item.Name)"
        }
    }

    $forbidden = @(
        @{ Text = $ray; Pattern = 'float strongestDirectWeight'; Name = 'single winning-light shadow mask' },
        @{ Text = $ray; Pattern = 'float strongestDirectVisibility'; Name = 'single-light visibility state' },
        @{ Text = $backend; Pattern = 'DXR v2.3 shadow-composite:'; Name = 'v2.3 experimental source mixed into v2.2 lab' }
    )

    foreach ($item in $forbidden) {
        if ($item.Text.Contains($item.Pattern)) {
            throw "Forbidden Quality Lab 1 marker found: $($item.Name)"
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
        Write-Host 'Quality Lab 1 patch is already applied.'
        Assert-QualityLab1Markers
        exit 0
    }

    foreach ($entry in $ExpectedV22Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required v2.2 source file is missing: $($entry.Key)"
        }
        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Stable Clear v2.2 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nApply patch 10, patch 20 Stable Clear v2.1 and patch 30 v2.2 first. Do not apply this patch over v2.3/v6/v7."
        }
        Write-Host "v2.2 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Quality Lab 1 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Quality Lab 1.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Quality Lab 1 patch.`n$($diffCheck.Output)"
    }

    Assert-QualityLab1Markers
    Write-Host 'DarkWolf DXR Stable Clear v2.2 Quality Lab 1 patch applied successfully.'
}
finally {
    Pop-Location
}
