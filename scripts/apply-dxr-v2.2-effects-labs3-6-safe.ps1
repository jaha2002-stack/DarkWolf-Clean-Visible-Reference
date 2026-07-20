[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$patch = Join-Path $RepoRoot 'patches\70-dxr-v2.2-effects-labs3-6-safe.patch'
if (!(Test-Path -LiteralPath $patch)) {
    throw "Patch not found: $patch"
}

Push-Location $RepoRoot
try {
    & git apply --check --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch 70 validation failed.' }

    & git apply --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch 70 application failed.' }

    Write-Host 'Applied DXR v2.2 Effects Labs 3-6 Safe patch.'
}
finally {
    Pop-Location
}
