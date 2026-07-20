[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $RepoRoot 'src\opengl\gl_d3d12raylight.cpp'
if (!(Test-Path -LiteralPath $sourcePath)) {
    throw "Source not found: $sourcePath"
}

$source = Get-Content -LiteralPath $sourcePath -Raw
$declToken = 'float2 DecorrelateSample2D(float2 xi, float seed)'
$callToken = 'DecorrelateSample2D('
$decl = $source.IndexOf($declToken, [System.StringComparison]::Ordinal)
$first = $source.IndexOf($callToken, [System.StringComparison]::Ordinal)

if ($decl -lt 0) {
    throw 'DecorrelateSample2D declaration is missing.'
}
if ($first -ne $decl + 'float2 '.Length) {
    throw "DecorrelateSample2D is used before declaration. first=$first declaration=$decl"
}
if ($source.Contains('StableCosineHemisphereSample(') -or $source.Contains('float2 Rotate2D(')) {
    throw 'Broken patch-71 helper path is still present.'
}

$openParen = ($source.ToCharArray() | Where-Object { $_ -eq '(' }).Count
$closeParen = ($source.ToCharArray() | Where-Object { $_ -eq ')' }).Count
$openBrace = ($source.ToCharArray() | Where-Object { $_ -eq '{' }).Count
$closeBrace = ($source.ToCharArray() | Where-Object { $_ -eq '}' }).Count

if ($openParen -ne $closeParen) {
    throw "Parenthesis count mismatch: $openParen / $closeParen"
}
if ($openBrace -ne $closeBrace) {
    throw "Brace count mismatch: $openBrace / $closeBrace"
}

Write-Host 'Image Cleanup HLSL structural validation passed.'
