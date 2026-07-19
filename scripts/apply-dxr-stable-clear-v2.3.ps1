[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchPath = Join-Path $RepoRoot 'patches/40-dxr-stable-clear-v2.3-shadow-composite.patch'

# Exact Stable Clear v2.2 blobs. Patch 40 is intentionally small and may only
# be applied after patches 10, 20 and 30.
$ExpectedV22Blobs = [ordered]@{
    'src/opengl/gl_d3d12raylight.cpp' = '0f779861ee2335459be850f1ca38c0a5430bd5d9'
    'src/renderer/tr_backend.cpp'      = 'ab8a8a7d2e4d027ce57cdb3929303f9d5fa5bdbd'
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

function Assert-V23Markers {
    $ray = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/opengl/gl_d3d12raylight.cpp') -Raw
    $backend = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/renderer/tr_backend.cpp') -Raw

    $required = @(
        @{ Text = $ray; Pattern = 'float3 rtDiffuseColor = max(albedo * lightingAccum, baseAlbedo * 0.15);'; Name = 'separate RT diffuse' },
        @{ Text = $ray; Pattern = 'float legacyShadowInfluence = saturate(strongestDirectWeight * 3.00);'; Name = 'stronger authored-light influence' },
        @{ Text = $ray; Pattern = 'float3 blendedDiffuse = lerp(rtDiffuseColor, baseAlbedo, legacyKeep);'; Name = 'diffuse composite' },
        @{ Text = $ray; Pattern = 'float3 finalColor = blendedDiffuse * legacyShadow +'; Name = 'whole-diffuse shadow application' },
        @{ Text = $ray; Pattern = 'float specularShadow = lerp(1.0, legacyShadow, 0.35);'; Name = 'partial specular shadowing' },
        @{ Text = $backend; Pattern = 'DXR v2.3 shadow-composite:'; Name = 'v2.3 runtime marker' }
    )

    foreach ($item in $required) {
        if (-not $item.Text.Contains($item.Pattern)) {
            throw "Required marker missing after Stable Clear v2.3 patch: $($item.Name)"
        }
    }

    if ($ray.Contains('float3 finalColor = lerp(rtLitColor, baseAlbedo * legacyShadow, legacyKeep);')) {
        throw 'Old v2.2 shadow-washing composite is still present.'
    }
}

Push-Location $RepoRoot
try {
    if (!(Test-Path -LiteralPath $PatchPath)) {
        throw "Patch file not found: $PatchPath"
    }

    $reverse = Invoke-GitChecked @('apply', '--reverse', '--check', $PatchPath)
    if ($reverse.Code -eq 0) {
        Write-Host 'Stable Clear v2.3 patch is already applied.'
        Assert-V23Markers
        exit 0
    }

    foreach ($entry in $ExpectedV22Blobs.GetEnumerator()) {
        $path = Join-Path $RepoRoot $entry.Key
        if (!(Test-Path -LiteralPath $path)) {
            throw "Required Stable Clear v2.2 source file is missing: $($entry.Key)"
        }

        $actual = Get-WorkingBlobHash $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Stable Clear v2.2 source mismatch: $($entry.Key)`nExpected blob: $($entry.Value)`nActual blob:   $actual`nPatch 40 must be applied after patches 10, 20 and 30, with no later source changes mixed in."
        }
        Write-Host "v2.2 blob OK: $($entry.Key)"
    }

    $check = Invoke-GitChecked @('apply', '--check', $PatchPath)
    if ($check.Code -ne 0) {
        throw "Stable Clear v2.3 patch cannot be applied cleanly.`n$($check.Output)"
    }

    $apply = Invoke-GitChecked @('apply', '--whitespace=nowarn', $PatchPath)
    if ($apply.Code -ne 0) {
        throw "git apply failed for Stable Clear v2.3.`n$($apply.Output)"
    }

    $diffCheck = Invoke-GitChecked @('diff', '--check')
    if ($diffCheck.Code -ne 0) {
        throw "git diff --check failed after Stable Clear v2.3 patch.`n$($diffCheck.Output)"
    }

    Assert-V23Markers
    Write-Host 'DarkWolf DXR Stable Clear v2.3 shadow-composite patch applied successfully.'
}
finally {
    Pop-Location
}
