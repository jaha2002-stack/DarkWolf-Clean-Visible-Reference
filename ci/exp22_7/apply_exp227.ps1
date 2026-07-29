param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$kit = Join-Path $repo 'ci/exp22_7'
$patch = Join-Path $kit '360-d3d12-static-dynamic-hit-table-exp22_7.patch'
$inputManifest = Join-Path $kit 'SOURCE_INPUT_SHA256SUMS.txt'
$outputManifest = Join-Path $kit 'SOURCE_OUTPUT_SHA256SUMS.txt'
$contract = Join-Path $kit 'SOURCE_CONTRACT_SUMMARY.txt'

foreach ($required in @($patch,$inputManifest,$outputManifest,$contract)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required EXP22.7 kit file is missing: $required"
  }
}

$expectedPatchSha = '04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444'
$actualPatchSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $patch).Hash
if ($actualPatchSha -ne $expectedPatchSha) {
  throw "EXP22.7 patch hash mismatch. Expected=$expectedPatchSha Actual=$actualPatchSha"
}

$sourceFiles = @(
  'src/opengl/gl_d3d12raylight.cpp',
  'src/opengl/opengl.h',
  'src/renderer/tr_cmds.cpp'
)

function Test-Manifest {
  param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$Phase
  )
  $verified = 0
  foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Manifest))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s{2,}', 2
    if ($parts.Count -ne 2) { throw "$Phase malformed manifest line: $line" }
    $relative = $parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = Join-Path $work $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "$Phase source file missing: $($parts[1])"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actual -ne $parts[0]) {
      throw "$Phase source hash mismatch: $($parts[1]) Expected=$($parts[0]) Actual=$actual"
    }
    Write-Host "EXP22_7_SOURCE_${Phase}_SHA256 $actual $($parts[1])"
    ++$verified
  }
  if ($verified -ne 3) {
    throw "$Phase source manifest count mismatch. Expected=3 Actual=$verified"
  }
}

Push-Location $work
try {
  git config core.autocrlf false
  if ($LASTEXITCODE -ne 0) { throw 'Unable to disable Git CRLF conversion.' }
  git config core.eol lf
  if ($LASTEXITCODE -ne 0) { throw 'Unable to select LF line endings.' }

  Test-Manifest -Manifest $inputManifest -Phase 'INPUT'

  git apply --check --whitespace=error-all -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 patch pre-apply check failed.' }
  git apply --whitespace=error-all -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 patch application failed.' }
  git diff --check -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 source diff contains whitespace errors.' }
  git apply --reverse --check -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 reverse patch verification failed.' }

  Test-Manifest -Manifest $outputManifest -Phase 'OUTPUT'

  $changed = @(git diff --name-only -- $sourceFiles)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate EXP22.7 changed files.' }
  $unexpected = @($changed | Where-Object { $_ -notin $sourceFiles })
  if ($unexpected.Count -ne 0) {
    throw "EXP22.7 changed unexpected files: $($unexpected -join ', ')"
  }
  if ($changed.Count -ne 3) {
    throw "EXP22.7 changed-file count mismatch. Expected=3 Actual=$($changed.Count)"
  }

  $markers = @(
    @('src/opengl/gl_d3d12raylight.cpp', 'GL_RAYTRACING_EXP227_STATIC_SLOT_LIMIT'),
    @('src/opengl/gl_d3d12raylight.cpp', 'glRaytracingExp227AllocateHitSlot'),
    @('src/opengl/gl_d3d12raylight.cpp', 'exp227TableDirty'),
    @('src/opengl/gl_d3d12raylight.cpp', 'hitTableCpuShadow'),
    @('src/opengl/gl_d3d12raylight.cpp', 'glRaytracingWaitMainCmdFence'),
    @('src/opengl/gl_d3d12raylight.cpp', 'exp227PartialTableUpdates'),
    @('src/renderer/tr_cmds.cpp', 'EXP22_7_PERF'),
    @('src/opengl/opengl.h', 'fullTableRebuilds')
  )
  foreach ($marker in $markers) {
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $marker[0]))
    if (-not $body.Contains($marker[1])) {
      throw "EXP22.7 required marker missing: $($marker[0]) :: $($marker[1])"
    }
  }

  $diff = git diff -- $sourceFiles
  $diffText = $diff -join "`n"
  if ([string]::IsNullOrWhiteSpace($diffText)) {
    throw 'EXP22.7 patch produced no source diff.'
  }
  $auditDir = Join-Path $work 'ci/exp22_7'
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $auditDir 'EXP22_7_SOURCE_DIFF.patch'),
    ($diffText + "`n"),
    [Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath $inputManifest -Destination (Join-Path $auditDir 'SOURCE_INPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $outputManifest -Destination (Join-Path $auditDir 'SOURCE_OUTPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $contract -Destination (Join-Path $auditDir 'SOURCE_CONTRACT_SUMMARY.txt') -Force

  Write-Host "EXP22_7_PATCH=PASS SHA256=$actualPatchSha FILES=3"
  Write-Host 'EXP22_7_SOURCE_AUDIT=PASS'
}
finally {
  Pop-Location
}
