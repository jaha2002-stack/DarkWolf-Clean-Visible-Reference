[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/10-dxr-clean-reference-rebase-current-main.patch'

$ExpectedSourceBlobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = 'd757f7056a3f44aa0b9d388bdc6d3fd6308301b6'
    'src/opengl/gl_d3d12shim.cpp'     = '8a07ebe4d79fa4f29c08c81485d9b5cead82d9c8'
    'src/opengl/opengl.h'             = 'fbffbae699b01e9b24f8d9c0ed68c33f207756e2'
    'src/renderer/tr_backend.cpp'      = '56f388e520c9dca17e7908a942c7a22589e5af18'
    'src/renderer/tr_init.cpp'         = '11c14d043cce6b0e3ff903df45a16830da8444f8'
    'src/renderer/tr_local.h'          = 'ab216053da15f25f3982fa5f35d3ba3db9b75a45'
    'src/botlib/be_aas_route.cpp'      = '599d2e1e8b4134fd0906701311d8e68da1258e61'
}

function Invoke-GitChecked {
    param([string[]]$Arguments)
    $output = & git @Arguments 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Output = ($output -join [Environment]::NewLine) }
}

function Assert-ReferenceMarkers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $shim = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12shim.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'float3 finalColor = lerp(rtLitColor, baseAlbedo, legacyKeep);'; Name = 'Clean Release composite' },
        @{ Text = $ray; Pattern = 'float    gExposure;'; Name = 'exposure constant' },
        @{ Text = $ray; Pattern = 'float    gLegacyBlend;'; Name = 'legacy blend constant' },
        @{ Text = $backend; Pattern = 'RB_AddDXRFallbackLightIfNeeded'; Name = 'fallback light' },
        @{ Text = $backend; Pattern = 'VectorMA(lightOrg, 128.0f'; Name = 'reference light position' },
        @{ Text = $shim; Pattern = 'if (!glRaytracingBuildScene())'; Name = 'checked scene build' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required marker missing after patch: $($item.Name)"
        }
    }

    if ($ray.Contains('CopyResource(backBuffer, pass->outputTexture)')) {
        throw 'Unsafe direct copy from DXR output to swapchain is still present.'
    }
}

Push-Location $RepoRoot
try {
    if (!(Test-Path -LiteralPath $PatchPath)) {
        throw "Patch file not found: $PatchPath"
    }

    Write-Host "Repository commit: $((& git rev-parse HEAD).Trim())"

    $reverse = Invoke-GitChecked @('apply', '--reverse', '--check', $PatchPath)
    if ($reverse.Code -eq 0) {
        Write-Host 'Clean Reference rebase patch is already applied.'
        Assert-ReferenceMarkers
        exit 0
    }

    foreach ($entry in $ExpectedSourceBlobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required source file is missing: $($entry.Key)"
        }

        $actual = (& git rev-parse "HEAD:$($entry.Key)" 2>$null).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $actual -ne $entry.Value) {
            throw "Source base mismatch: $($entry.Key)`nExpected Git blob: $($entry.Value)`nActual Git blob:   $actual`nThis kit is tied to the uploaded DarkWolf-Clean-Visible-Reference-main source state."
        }
        Write-Host "Base blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Rebased reference patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after patch.`n$($diffCheck.Output)"
    }

    Assert-ReferenceMarkers
    Write-Host 'DarkWolf DXR Clean Visible Reference rebase applied successfully.'
}
finally {
    Pop-Location
}
