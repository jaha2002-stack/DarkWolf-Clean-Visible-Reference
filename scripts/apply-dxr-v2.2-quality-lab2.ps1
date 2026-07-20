[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/50-dxr-v2.2-quality-lab2-shadow-authority-dynamic-blas.patch'

# Exact Git blob hashes after patch 10 -> 20 -> 30 -> 40 Quality Lab 1.
# QL2 is intentionally based on the user's compiled, stable QL1 branch.
$ExpectedQL1Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = '43213e67bcdab60a52e48468720421f37e8a2f83'
    'src/opengl/opengl.h'             = 'fe7e3f528864d75be1e9607f8a32ab96b9fc86b9'
    'src/renderer/tr_backend.cpp'     = 'f5696951977419edb302b4b03bc3f99a9dab98e7'
    'src/renderer/tr_cmesh.cpp'       = '82b17717fc0a7f2a7ea583a3442e7065c8882ad2'
    'src/renderer/tr_init.cpp'        = '2bfd3d3a8aa07df5ce8fdd196ca27e751e5f1017'
    'src/renderer/tr_local.h'         = '6bfa98811972347689468231c8baabb3e3bae1c0'
    'src/renderer/tr_mesh.cpp'        = '11b6ed71b57ed55f4c317127ad77cb21ce220865'
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

function Assert-QualityLab2Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw
    $init = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_init.cpp') -Raw
    $local = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_local.h') -Raw
    $api = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/opengl.h') -Raw
    $cmesh = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_cmesh.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'float strongestShadowLoss = 0.0;'; Name = 'local shadow-evidence accumulator' },
        @{ Text = $ray; Pattern = 'float compositeVisibility'; Name = 'retained composite visibility' },
        @{ Text = $ray; Pattern = 'gShadowRetention'; Name = 'shadow-retention constant' },
        @{ Text = $ray; Pattern = 'forceFullRebuild'; Name = 'animated BLAS full-rebuild path' },
        @{ Text = $ray; Pattern = 'dynamicFullRebuilds'; Name = 'dynamic BLAS diagnostics' },
        @{ Text = $ray; Pattern = 'gDebugMode == 11'; Name = 'shadow-evidence debug mode' },
        @{ Text = $ray; Pattern = 'gDebugMode == 12'; Name = 'retained-visibility debug mode' },
        @{ Text = $backend; Pattern = 'DXR v2.2 Quality Lab 2:'; Name = 'QL2 runtime marker' },
        @{ Text = $backend; Pattern = 'glRaytracingSetDynamicGeometryOptions'; Name = 'dynamic geometry policy upload' },
        @{ Text = $init; Pattern = 'r_dxrDynamicBLASFullRebuild'; Name = 'dynamic BLAS CVar' },
        @{ Text = $local; Pattern = 'r_dxrShadowCompositeMinLight'; Name = 'composite threshold declaration' },
        @{ Text = $api; Pattern = 'glRaytracingGetDynamicFullRebuildCount'; Name = 'dynamic diagnostics API' },
        @{ Text = $cmesh; Pattern = 'last-to-first interpolation'; Name = 'cage loop-seam frame fix' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required Quality Lab 2 marker missing: $($item.Name)"
        }
    }

    if ($ray.Contains('smoothstep(0.05, 0.65, authoredDirectShare)')) {
        throw 'Obsolete QL1 direct-share gate is still present.'
    }
    if ($backend.Contains('DXR v2.3 shadow-composite:')) {
        throw 'Experimental v2.3 source was mixed into the QL2 branch.'
    }
}

Push-Location $RepoRoot
try {
    if (!(Test-Path -LiteralPath $PatchPath)) {
        throw "Patch file not found: $PatchPath"
    }

    $reverse = Invoke-GitChecked @('apply', '--reverse', '--check', $PatchPath)
    if ($reverse.Code -eq 0) {
        Write-Host 'Quality Lab 2 patch is already applied.'
        Assert-QualityLab2Markers
        exit 0
    }

    foreach ($entry in $ExpectedQL1Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required QL1 source file is missing: $($entry.Key)"
        }
        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Quality Lab 1 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nApply patches 10, 20, 30 and 40 first. Do not apply patch 50 over v2.3 or a mixed tree."
        }
        Write-Host "QL1 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Quality Lab 2 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Quality Lab 2.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Quality Lab 2 patch.`n$($diffCheck.Output)"
    }

    Assert-QualityLab2Markers
    Write-Host 'DarkWolf DXR v2.2 Quality Lab 2 patch applied successfully.'
}
finally {
    Pop-Location
}
