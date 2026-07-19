[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/30-dxr-stable-clear-v2.2-visual-correctness.patch'

# Git blob hashes of the exact Stable Clear v2.1 source state. Patch 30 must be
# applied after patch 10 and patch 20, never directly to clean upstream or v2.
$ExpectedV21Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = '770a067addd9fdc90fc49f1d93a35d8955e41c48'
    'src/opengl/gl_d3d12shim.cpp'     = '49a4f3c109d70cfa01105bd5506b9664925c5508'
    'src/renderer/tr_backend.cpp'      = '55dd51c2da6f3b5982373c0981ae5b8a50064578'
    'src/renderer/tr_init.cpp'         = '8cf26ed22d740860a60f3d97995cd627b41222e3'
    'src/renderer/tr_local.h'          = '8baa2cc40889c2968a31870badea4126ac4c9409'
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

function Assert-V22Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $shim = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12shim.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $init = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_init.cpp') -Raw
    $local = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_local.h') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'GL_RAYTRACING_LIGHT_FLAG_FILL_ONLY'; Name = 'fill-only fallback flag' },
        @{ Text = $ray; Pattern = 'RAY_FLAG_CULL_FRONT_FACING_TRIANGLES | RAY_FLAG_FORCE_OPAQUE'; Name = 'front-face self-shadow suppression' },
        @{ Text = $ray; Pattern = 'if (positionSample.w < 0.5)'; Name = 'invalid G-buffer pass-through' },
        @{ Text = $ray; Pattern = 'float geoFlag = positionSample.w - 1.0;'; Name = 'G-buffer validity decoding' },
        @{ Text = $ray; Pattern = 'if (light.pad1 >= 0.5f)'; Name = 'fallback-only light-selection priority' },
        @{ Text = $shim; Pattern = 'DXGI_FORMAT_R32G32B32A32_FLOAT'; Name = 'full-precision world-position buffer' },
        @{ Text = $shim; Pattern = 'D3D12_FILTER_ANISOTROPIC'; Name = 'anisotropic texture filtering' },
        @{ Text = $shim; Pattern = 'samps[i].MaxAnisotropy = 8;'; Name = '8x anisotropy' },
        @{ Text = $shim; Pattern = 'o.position = float4(i.worldPos, i.attr.x + 1.0);'; Name = 'valid G-buffer marker' },
        @{ Text = $backend; Pattern = 'DXR v2.2 visual-correct:'; Name = 'v2.2 runtime marker' },
        @{ Text = $backend; Pattern = 'r_dxrFallbackCastsShadows'; Name = 'camera-fill shadow gate' },
        @{ Text = $init; Pattern = 'ri.Cvar_Get( "r_dxrFallbackCastsShadows", "0"'; Name = 'safe fallback shadow default' },
        @{ Text = $local; Pattern = 'extern cvar_t   *r_dxrFallbackCastsShadows'; Name = 'fallback shadow cvar declaration' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required marker missing after Stable Clear v2.2 patch: $($item.Name)"
        }
    }

    $forbidden = @(
        @{ Text = $ray; Pattern = 'if (!light.persistant)'; Name = 'all-dynamic-lights selection boost' },
        @{ Text = $shim; Pattern = 'TinyNoise(int2(i.pos.xy)) * 0.0005'; Name = 'screen-space texture-coordinate jitter' },
        @{ Text = $shim; Pattern = 'CreateRenderTexture(w.positionBuffers[i], w.positionBufferState[i], DXGI_FORMAT_R16G16B16A16_FLOAT'; Name = 'half-precision absolute world positions' }
    )

    foreach ($item in $forbidden) {
        if ($item.Text.Contains($item.Pattern)) {
            throw "Forbidden marker found after Stable Clear v2.2 patch: $($item.Name)"
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
        Write-Host 'Stable Clear v2.2 patch is already applied.'
        Assert-V22Markers
        exit 0
    }

    foreach ($entry in $ExpectedV21Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required Stable Clear v2.1 source file is missing: $($entry.Key)"
        }

        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Stable Clear v2.1 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nPatch 30 must be applied after patch 10 and patch 20, with no v6/v7/v2 source mixed in."
        }
        Write-Host "v2.1 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Stable Clear v2.2 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Stable Clear v2.2.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Stable Clear v2.2 patch.`n$($diffCheck.Output)"
    }

    Assert-V22Markers
    Write-Host 'DarkWolf DXR Stable Clear v2.2 visual-correctness patch applied successfully.'
}
finally {
    Pop-Location
}
