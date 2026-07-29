param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$kit = Join-Path $repo 'ci/exp22_9'
$patchSource = Join-Path $kit '430-d3d12-dynamic-blas-budget-exp22_9.patch'
$inputManifest = Join-Path $kit 'SOURCE_INPUT_SHA256SUMS.txt'
$outputManifest = Join-Path $kit 'SOURCE_OUTPUT_SHA256SUMS.txt'
$contract = Join-Path $kit 'SOURCE_CONTRACT_SUMMARY.txt'
$expectedPatchSha = '10B24C26D4A061AFD69EA307FCF369A5AFB92650A0B1141321EDF2AD0A092AC4'
$sourceFiles = @(
  'src/opengl/gl_d3d12raylight.cpp',
  'src/opengl/opengl.h',
  'src/renderer/tr_backend.cpp',
  'src/renderer/tr_cmds.cpp'
)

foreach ($required in @($patchSource,$inputManifest,$outputManifest,$contract)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing EXP22.9 kit file: $required" }
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
$raw = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $patchSource))
$text = [Text.UTF8Encoding]::new($false,$true).GetString($raw)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
$canonical = $text.Replace("`r`n","`n").Replace("`r","`n")
$canonicalBytes = $utf8NoBom.GetBytes($canonical)
$sha = [Security.Cryptography.SHA256]::Create()
try { $actualPatchSha = ([BitConverter]::ToString($sha.ComputeHash($canonicalBytes))).Replace('-','') }
finally { $sha.Dispose() }
if ($actualPatchSha -ne $expectedPatchSha) { throw "EXP22.9 patch hash mismatch. Expected=$expectedPatchSha Actual=$actualPatchSha" }
$canonicalPatch = Join-Path $env:RUNNER_TEMP 'exp22_9-dynamic-blas-budget-canonical-lf.patch'
[IO.File]::WriteAllBytes($canonicalPatch,$canonicalBytes)

$auditDir = Join-Path $work 'ci/exp22_9'
New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
[IO.File]::WriteAllLines((Join-Path $auditDir 'PATCH_TRANSPORT_AUDIT.txt'), @(
  'DARKWOLF_EXP22_9_PATCH_TRANSPORT_AUDIT',
  "CanonicalLFSHA256=$actualPatchSha",
  "ExpectedCanonicalLFSHA256=$expectedPatchSha",
  "CanonicalBytes=$($canonicalBytes.Length)",
  'CanonicalEncoding=UTF-8-no-BOM',
  'CanonicalLineEnding=LF'
), $utf8NoBom)

function Normalize-SourceToLf([string]$RelativePath) {
  $path = Join-Path $work $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "EXP22.9 source missing: $RelativePath" }
  $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path)).Replace("`r`n","`n").Replace("`r","`n")
  [IO.File]::WriteAllText($path,$body,$utf8NoBom)
}
function Test-Manifest([string]$Manifest,[string]$Phase) {
  $count = 0
  foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Manifest))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s{2,}',2
    if ($parts.Count -ne 2) { throw "$Phase malformed line: $line" }
    $path = Join-Path $work $parts[1].Replace('/',[IO.Path]::DirectorySeparatorChar)
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actual -ne $parts[0]) { throw "$Phase hash mismatch $($parts[1]) Expected=$($parts[0]) Actual=$actual" }
    ++$count
  }
  if ($count -ne 4) { throw "$Phase manifest count mismatch: $count" }
}

Push-Location $work
try {
  git config core.autocrlf false
  git config core.eol lf
  foreach ($file in $sourceFiles) { Normalize-SourceToLf $file }
  Test-Manifest $inputManifest 'INPUT'
  git apply --check --whitespace=error-all -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.9 patch check failed.' }
  git apply --whitespace=error-all -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.9 patch apply failed.' }
  git diff --check -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.9 whitespace check failed.' }
  git apply --reverse --check -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.9 reverse check failed.' }
  Test-Manifest $outputManifest 'OUTPUT'

  $changed = @(git diff --name-only -- $sourceFiles)
  if ($changed.Count -ne 4) { throw "EXP22.9 changed-file count mismatch: $($changed.Count)" }
  foreach ($file in $sourceFiles) { if ($file -notin $changed) { throw "EXP22.9 expected changed file missing: $file" } }

  $markers = @(
    @('src/opengl/gl_d3d12raylight.cpp','exp229BlasUpdateBudget = 24'),
    @('src/opengl/gl_d3d12raylight.cpp','PREFER_FAST_BUILD'),
    @('src/opengl/gl_d3d12raylight.cpp','exp229LastBlasDeferred'),
    @('src/opengl/gl_d3d12raylight.cpp','glRaytracingExp229WaitForBlasGeometryWrite'),
    @('src/opengl/gl_d3d12raylight.cpp','glRaytracingExp229RecordViewWeaponSkip'),
    @('src/renderer/tr_backend.cpp','RF_FIRST_PERSON | RF_DEPTHHACK'),
    @('src/renderer/tr_cmds.cpp','EXP22_9_PERF'),
    @('src/opengl/opengl.h','blasFenceWaitMs')
  )
  foreach ($m in $markers) {
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $m[0]))
    if (-not $body.Contains($m[1])) { throw "EXP22.9 marker missing: $($m[0]) :: $($m[1])" }
  }
  $ray = [IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/opengl/gl_d3d12raylight.cpp'))
  if ($ray.Contains('std::max(') -or $ray.Contains('std::min(')) { throw 'EXP22.9 contains unprotected Windows min/max macro call.' }

  $diff = (git diff -- $sourceFiles) -join "`n"
  [IO.File]::WriteAllText((Join-Path $auditDir 'EXP22_9_SOURCE_DIFF.patch'),$diff+"`n",$utf8NoBom)
  Copy-Item $inputManifest (Join-Path $auditDir 'SOURCE_INPUT_SHA256SUMS.txt') -Force
  Copy-Item $outputManifest (Join-Path $auditDir 'SOURCE_OUTPUT_SHA256SUMS.txt') -Force
  Copy-Item $contract (Join-Path $auditDir 'SOURCE_CONTRACT_SUMMARY.txt') -Force
  Write-Host "EXP22_9_PATCH=PASS SHA256=$actualPatchSha FILES=4 BLAS_BUDGET=24 VIEW_WEAPON_ISOLATION=1"
}
finally { Pop-Location }
