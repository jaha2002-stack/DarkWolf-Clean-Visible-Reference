[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/61-dxr-v2.2-quality-lab3.1-startup-safe-no-history.patch'

# Exact Git blobs after patch 60 Quality Lab 3.
$ExpectedQL3Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = '02fed812b77a58d8723efa21c6a0694ded1c88f5'
    'src/renderer/tr_backend.cpp'      = '2ae500d717f9096f55ec12c821d2a37df1debab2'
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

function Assert-QualityLab31Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'gPointShadowRadiusScale'; Name = 'point-light source-size control' },
        @{ Text = $ray; Pattern = 'selectedReservedLocalCount'; Name = 'local-light reservation' },
        @{ Text = $ray; Pattern = 'g_glRaytracingDynamicMode = 0'; Name = 'hybrid BLAS auto mode' },
        @{ Text = $ray; Pattern = 'hd.NumDescriptors = 7;'; Name = 'proven seven-descriptor heap' },
        @{ Text = $ray; Pattern = 'ranges[0].NumDescriptors = 6;'; Name = 'proven six-SRV table' },
        @{ Text = $ray; Pattern = 'ranges[1].NumDescriptors = 1;'; Name = 'single output UAV table' },
        @{ Text = $ray; Pattern = 'const uint32_t newTemporalEnabled = 0u;'; Name = 'hard temporal safety gate' },
        @{ Text = $ray; Pattern = 'const uint32_t newSpatialRadius = 0u;'; Name = 'hard history-filter safety gate' },
        @{ Text = $backend; Pattern = 'DXR v2.2 Quality Lab 3.1 Startup Safe:'; Name = 'QL3.1 runtime marker' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required Quality Lab 3.1 marker missing: $($item.Name)"
        }
    }

    $forbidden = @(
        'gShadowHistoryOut',
        'gShadowHistoryTex',
        'glRaytracingLightingEnsureHistory',
        'shadowHistoryWriteIndex',
        'shadowHistoryState[',
        'DXGI_FORMAT_R16G16_FLOAT',
        'pass->velocityTexture',
        'pass->previousPositionTexture',
        'pass->previousNormalTexture',
        'hd.NumDescriptors = 12;',
        'ranges[0].NumDescriptors = 10;',
        'ranges[1].NumDescriptors = 2;'
    )
    foreach ($pattern in $forbidden) {
        if ($ray.Contains($pattern)) {
            throw "Unsafe QL3 temporal-history marker still present: $pattern"
        }
    }

    # Keep every embedded HLSL literal below the conservative MSVC C2026 limit.
    $matches = [regex]::Matches(
        $ray,
        'R"QL3HLSL\((.*?)\)QL3HLSL"',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matches.Count -lt 2) {
        throw 'QL3.1 embedded HLSL chunks were not found.'
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
        Write-Host 'Quality Lab 3.1 startup-safe patch is already applied.'
        Assert-QualityLab31Markers
        exit 0
    }

    foreach ($entry in $ExpectedQL3Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required QL3 source file is missing: $($entry.Key)"
        }
        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Quality Lab 3 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nApply patches 10, 20, 30, 40, 50 and 60 first."
        }
        Write-Host "QL3 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Quality Lab 3.1 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Quality Lab 3.1.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Quality Lab 3.1 patch.`n$($diffCheck.Output)"
    }

    Assert-QualityLab31Markers
    Write-Host 'DarkWolf DXR v2.2 Quality Lab 3.1 startup-safe patch applied successfully.'
}
finally {
    Pop-Location
}
