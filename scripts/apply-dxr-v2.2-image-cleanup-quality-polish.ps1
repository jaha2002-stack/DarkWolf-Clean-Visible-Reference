[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$patch = Join-Path $RepoRoot 'patches\71-dxr-v2.2-image-cleanup-quality-polish.patch'
if (!(Test-Path -LiteralPath $patch)) {
    throw "Patch not found: $patch"
}

Push-Location $RepoRoot
try {
    & git apply --check --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch 71 validation failed.' }

    & git apply --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch 71 application failed.' }

    Write-Host 'Applied DXR v2.2 Image Cleanup / Quality Polish patch.'
}
finally {
    Pop-Location
}
