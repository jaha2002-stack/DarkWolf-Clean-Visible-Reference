param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$v7Relative = '.github/workflows/darkwolf-d3d12-performance-lifecycle-exp22_6-exact-v7.yml'
$v7 = Join-Path $repo $v7Relative
if (-not (Test-Path -LiteralPath $v7 -PathType Leaf)) {
  throw "Hash-locked EXP22.6 payload source is missing: $v7"
}

$expectedV7BlobSha = 'ff39e6d63987865de168260784af6449e236301d'
$actualV7BlobSha = (& git -C $repo hash-object -- $v7Relative).Trim()
if ($LASTEXITCODE -ne 0 -or $actualV7BlobSha -ne $expectedV7BlobSha) {
  throw "EXP22.6 v7 payload container mismatch. Expected=$expectedV7BlobSha Actual=$actualV7BlobSha"
}

$v7Text = [IO.File]::ReadAllText((Resolve-Path $v7), [Text.Encoding]::UTF8)
$archiveMatch = [regex]::Match(
  $v7Text,
  "(?ms)^\s*\`$base64\s*=\s*@'\s*(?<payload>.*?)^\s*'@\s*\`$payload\s*=\s*\`$base64"
)
if (-not $archiveMatch.Success) {
  throw 'Unable to locate the hash-locked EXP22.6 exact-patch archive in v7.'
}

$archive = Join-Path $env:RUNNER_TEMP 'exp22_6-exact-patch-kit.zip'
$archiveBase64 = $archiveMatch.Groups['payload'].Value -replace '\s', ''
[IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String($archiveBase64))

$expectedArchiveSha = '459B7A90D171CAC002D7D87AFFD4F90C160A744C46893D71E47EB5503A74E284'
$actualArchiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
if ($actualArchiveSha -ne $expectedArchiveSha) {
  throw "EXP22.6 kit archive hash mismatch. Expected=$expectedArchiveSha Actual=$actualArchiveSha"
}

Expand-Archive -LiteralPath $archive -DestinationPath $work -Force
$kit = Join-Path $work 'ci/exp22_6'
if (-not (Test-Path -LiteralPath $kit -PathType Container)) {
  throw "EXP22.6 kit directory is missing after extraction: $kit"
}

$requiredKitFiles = @(
  '350-d3d12-performance-lifecycle-exp22_6-exact.patch',
  'SOURCE_CONTRACT_SUMMARY.txt',
  'SOURCE_INPUT_SHA256SUMS.txt',
  'SOURCE_OUTPUT_SHA256SUMS.txt',
  'EXP22_6_KIT_SHA256SUMS.txt',
  'darkwolf_exp22_6_production.cfg',
  '01_compression_off.cfg',
  '02_compression_on.cfg',
  '03_reflections_off.cfg',
  '04_dxr_off.cfg',
  'RUN_EXP22_6_PRODUCTION.bat',
  'RUN_EXP22_6_TESTS.bat',
  'RUN_WITHOUT_4K_PACKS.ps1',
  'EXP22_6_COLLECT_RESULTS.ps1'
)
foreach ($name in $requiredKitFiles) {
  $path = Join-Path $kit $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required EXP22.6 kit file is missing: $path"
  }
}

$kitManifest = Join-Path $kit 'EXP22_6_KIT_SHA256SUMS.txt'
$verifiedKitFiles = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $kitManifest))) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split '\s{2,}', 2
  if ($parts.Count -ne 2) { throw "Malformed EXP22.6 kit manifest line: $line" }
  $relative = $parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
  $path = Join-Path $work $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.6 kit manifest file is missing: $($parts[1])"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  if ($actual -ne $parts[0]) {
    throw "EXP22.6 kit file hash mismatch: $($parts[1]) Expected=$($parts[0]) Actual=$actual"
  }
  ++$verifiedKitFiles
}
if ($verifiedKitFiles -lt 10) {
  throw "EXP22.6 kit manifest verified too few files: $verifiedKitFiles"
}

$patch = Join-Path $kit '350-d3d12-performance-lifecycle-exp22_6-exact.patch'
$expectedPatchSha = '176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170'
$actualPatchSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $patch).Hash
if ($actualPatchSha -ne $expectedPatchSha) {
  throw "EXP22.6 patch hash mismatch. Expected=$expectedPatchSha Actual=$actualPatchSha"
}

$sourceFiles = @(
  'src/opengl/opengl.h',
  'src/opengl/gl_d3d12raylight.cpp',
  'src/opengl/gl_d3d12shim.cpp',
  'src/renderer/tr_backend.cpp',
  'src/renderer/tr_cmds.cpp',
  'src/renderer/tr_cmesh.cpp'
)

function Convert-ToCanonicalLfNoBom {
  param([Parameter(Mandatory=$true)][string]$Path)
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  [byte[]]$bytes = [IO.File]::ReadAllBytes($resolved)
  $start = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $start = 3
  }
  $output = [System.Collections.Generic.List[byte]]::new($bytes.Length)
  for ($i = $start; $i -lt $bytes.Length; ++$i) {
    if ($bytes[$i] -eq 13) {
      if (($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { ++$i }
      $output.Add([byte]10)
    }
    else {
      $output.Add($bytes[$i])
    }
  }
  [IO.File]::WriteAllBytes($resolved, $output.ToArray())
}

function Test-SourceManifest {
  param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$Phase
  )
  $verified = 0
  foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $Manifest))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s{2,}', 2
    if ($parts.Count -ne 2) { throw "$Phase malformed source manifest line: $line" }
    $relative = $parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = Join-Path $work $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "$Phase source file missing: $($parts[1])"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actual -ne $parts[0]) {
      throw "$Phase source hash mismatch: $($parts[1]) Expected=$($parts[0]) Actual=$actual"
    }
    Write-Host "EXP22_6_SOURCE_${Phase}_SHA256 $actual $($parts[1])"
    ++$verified
  }
  if ($verified -ne 6) { throw "$Phase source manifest count mismatch. Expected=6 Actual=$verified" }
}

Push-Location $work
try {
  git config core.autocrlf false
  if ($LASTEXITCODE -ne 0) { throw 'Unable to disable Git CRLF conversion.' }
  git config core.eol lf
  if ($LASTEXITCODE -ne 0) { throw 'Unable to select LF line endings.' }

  foreach ($sourceFile in $sourceFiles) {
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
      throw "Exact source file missing: $sourceFile"
    }
    Convert-ToCanonicalLfNoBom -Path $sourceFile
  }

  Test-SourceManifest -Manifest (Join-Path $kit 'SOURCE_INPUT_SHA256SUMS.txt') -Phase 'INPUT'

  git add -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the exact post-EXP22.4 source snapshot.' }
  git -c user.name='DarkWolf EXP22.6 CI' -c user.email='exp226-ci@localhost' commit --allow-empty --no-gpg-sign -m 'CI snapshot: exact post-EXP22.4 source'
  if ($LASTEXITCODE -ne 0) { throw 'Unable to create the exact post-EXP22.4 source snapshot.' }

  git apply --check --whitespace=error-all -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.6 exact patch pre-apply check failed.' }
  git apply --whitespace=error-all -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.6 exact patch application failed.' }
  git diff --check -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.6 source diff contains whitespace errors.' }
  git apply --reverse --check -- $patch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.6 reverse patch verification failed.' }

  Test-SourceManifest -Manifest (Join-Path $kit 'SOURCE_OUTPUT_SHA256SUMS.txt') -Phase 'OUTPUT'

  $diff = git diff -- $sourceFiles
  $diffText = $diff -join "`n"
  if ([string]::IsNullOrWhiteSpace($diffText)) { throw 'EXP22.6 exact patch produced no source diff.' }
  [IO.File]::WriteAllText(
    (Join-Path $kit 'EXP22_6_SOURCE_DIFF.patch'),
    ($diffText + "`n"),
    [Text.UTF8Encoding]::new($false)
  )

  foreach ($marker in @(
    @('src/opengl/gl_d3d12raylight.cpp', 'glRaytracingExp226TouchInstance'),
    @('src/opengl/gl_d3d12raylight.cpp', 'minimal shadow-compatible SBT'),
    @('src/opengl/gl_d3d12shim.cpp', 'D3D12_QUERY_HEAP_TYPE_TIMESTAMP'),
    @('src/renderer/tr_cmds.cpp', 'EXP22_6_PERF avgFps='),
    @('src/renderer/tr_cmesh.cpp', 'EXP22_6_MODEL_FRAME_WRAP')
  )) {
    $body = [IO.File]::ReadAllText((Resolve-Path $marker[0]))
    if (-not $body.Contains($marker[1])) {
      throw "EXP22.6 required marker missing: $($marker[0]) :: $($marker[1])"
    }
  }
}
finally {
  Pop-Location
}

Write-Host "EXP22_6_KIT=PASS ARCHIVE_SHA256=$actualArchiveSha FILES=$verifiedKitFiles"
Write-Host "EXP22_6_EXACT_PATCH=PASS SHA256=$actualPatchSha"
Write-Host 'EXP22_6_SOURCE_AUDIT=PASS'
