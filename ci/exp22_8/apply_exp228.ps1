param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$kit = Join-Path $repo 'ci/exp22_8'
$patchSource = Join-Path $kit '420-d3d12-persistent-dynamic-sbt-exp22_8.patch'
$inputManifest = Join-Path $kit 'SOURCE_INPUT_SHA256SUMS.txt'
$outputManifest = Join-Path $kit 'SOURCE_OUTPUT_SHA256SUMS.txt'
$contract = Join-Path $kit 'SOURCE_CONTRACT_SUMMARY.txt'
$expectedPatchSha = 'D9DAE13EA2DA365EFCFC11A9F42F5F78B1D0673516E589DEDB4F87287B660BE3'
$sourceFiles = @(
  'src/opengl/gl_d3d12raylight.cpp',
  'src/opengl/opengl.h',
  'src/renderer/tr_cmds.cpp',
  'src/renderer/tr_backend.cpp'
)

foreach ($required in @($patchSource,$inputManifest,$outputManifest,$contract)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required EXP22.8 kit file is missing: $required"
  }
}

function Get-Sha256Hex {
  param([Parameter(Mandatory=$true)][byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
  finally { $sha.Dispose() }
}

$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$rawPatchBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $patchSource))
try { $patchText = $utf8Strict.GetString($rawPatchBytes) }
catch { throw "EXP22.8 patch is not valid UTF-8: $($_.Exception.Message)" }
if ($patchText.Length -gt 0 -and $patchText[0] -eq [char]0xFEFF) {
  $patchText = $patchText.Substring(1)
}
$crlfCount = ([regex]::Matches($patchText, "`r`n")).Count
$canonicalText = $patchText.Replace("`r`n", "`n").Replace("`r", "`n")
$canonicalBytes = $utf8NoBom.GetBytes($canonicalText)
$canonicalSha = Get-Sha256Hex -Bytes $canonicalBytes
$rawSha = Get-Sha256Hex -Bytes $rawPatchBytes
if ($canonicalSha -ne $expectedPatchSha) {
  throw "EXP22.8 canonical patch hash mismatch. Expected=$expectedPatchSha Actual=$canonicalSha Raw=$rawSha"
}

$canonicalPatch = Join-Path $env:RUNNER_TEMP 'exp22_8-persistent-dynamic-sbt-canonical-lf.patch'
[IO.File]::WriteAllBytes($canonicalPatch, $canonicalBytes)
$auditDir = Join-Path $work 'ci/exp22_8'
New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
[IO.File]::WriteAllLines(
  (Join-Path $auditDir 'PATCH_TRANSPORT_AUDIT.txt'),
  @(
    'DARKWOLF_EXP22_8_PATCH_TRANSPORT_AUDIT',
    "SourcePath=$patchSource",
    "RawSHA256=$rawSha",
    "CanonicalLFSHA256=$canonicalSha",
    "ExpectedCanonicalLFSHA256=$expectedPatchSha",
    "RawBytes=$($rawPatchBytes.Length)",
    "CanonicalBytes=$($canonicalBytes.Length)",
    "CRLFSequences=$crlfCount",
    'CanonicalEncoding=UTF-8-no-BOM',
    'CanonicalLineEnding=LF'
  ),
  $utf8NoBom)
[IO.File]::WriteAllBytes(
  (Join-Path $auditDir '420-d3d12-persistent-dynamic-sbt-exp22_8-canonical-lf.patch'),
  $canonicalBytes)

function Normalize-SourceToLf {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $path = Join-Path $work $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.8 source file is missing: $RelativePath"
  }
  $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path))
  $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
  [IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

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
    Write-Host "EXP22_8_SOURCE_${Phase}_SHA256 $actual $($parts[1])"
    ++$verified
  }
  if ($verified -ne 4) {
    throw "$Phase source manifest count mismatch. Expected=4 Actual=$verified"
  }
}

Push-Location $work
try {
  git config core.autocrlf false
  if ($LASTEXITCODE -ne 0) { throw 'Unable to disable Git CRLF conversion.' }
  git config core.eol lf
  if ($LASTEXITCODE -ne 0) { throw 'Unable to select LF line endings.' }

  foreach ($sourceFile in $sourceFiles) { Normalize-SourceToLf -RelativePath $sourceFile }
  Test-Manifest -Manifest $inputManifest -Phase 'INPUT'

  git apply --check --whitespace=error-all -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.8 canonical patch pre-apply check failed.' }
  git apply --whitespace=error-all -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.8 canonical patch application failed.' }
  git diff --check -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.8 source diff contains whitespace errors.' }
  git apply --reverse --check -- $canonicalPatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.8 canonical reverse patch verification failed.' }

  Test-Manifest -Manifest $outputManifest -Phase 'OUTPUT'

  $changed = @(git diff --name-only -- $sourceFiles)
  if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate EXP22.8 changed files.' }
  $unexpected = @($changed | Where-Object { $_ -notin $sourceFiles })
  if ($unexpected.Count -ne 0) { throw "EXP22.8 changed unexpected files: $($unexpected -join ', ')" }
  if ($changed.Count -ne 4) { throw "EXP22.8 changed-file count mismatch. Expected=4 Actual=$($changed.Count)" }

  $markers = @(
    @('src/opengl/gl_d3d12raylight.cpp','GL_RAYTRACING_EXP228_SBT_CAPACITY_SLOTS'),
    @('src/opengl/gl_d3d12raylight.cpp','exp228HighWaterGrowthEvents'),
    @('src/opengl/gl_d3d12raylight.cpp','GL_RAYTRACING_EXP228_REBUILD_INITIAL_ALLOCATION'),
    @('src/opengl/gl_d3d12raylight.cpp','glRaytracingExp228RecordTransientSkip'),
    @('src/opengl/gl_d3d12raylight.cpp','hitTableCapacitySlotCount'),
    @('src/opengl/gl_d3d12raylight.cpp','exp228TlasMs'),
    @('src/opengl/gl_d3d12raylight.cpp','exp228BlasMs'),
    @('src/opengl/opengl.h','GL_RAYTRACING_INSTANCE_FLAG_NO_REFLECTION'),
    @('src/opengl/opengl.h','fullRebuildReason'),
    @('src/renderer/tr_backend.cpp','RB_EXP228ClassifyTransientFlags'),
    @('src/renderer/tr_backend.cpp','GL_RAYTRACING_INSTANCE_FLAG_MUZZLE'),
    @('src/renderer/tr_cmds.cpp','EXP22_8_PERF')
  )
  foreach ($marker in $markers) {
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $marker[0]))
    if (-not $body.Contains($marker[1])) {
      throw "EXP22.8 required marker missing: $($marker[0]) :: $($marker[1])"
    }
  }

  $raylight = [IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/opengl/gl_d3d12raylight.cpp'))
  if ($raylight.Contains('std::max(')) {
    throw 'EXP22.8 output contains an unprotected std::max call and is unsafe with the Windows max macro.'
  }
  if ($raylight.Contains('hitTableCapacityBytes < requiredBytes')) {
    throw 'EXP22.8 retained the EXP22.7 high-water-driven SBT reallocation condition.'
  }
  if (-not $raylight.Contains('hitTableCapacityBytes < fullCapacityBytes')) {
    throw 'EXP22.8 full-capacity SBT allocation contract is missing.'
  }

  $diff = git diff -- $sourceFiles
  $diffText = $diff -join "`n"
  if ([string]::IsNullOrWhiteSpace($diffText)) { throw 'EXP22.8 patch produced no source diff.' }
  [IO.File]::WriteAllText(
    (Join-Path $auditDir 'EXP22_8_SOURCE_DIFF.patch'),
    ($diffText + "`n"),
    $utf8NoBom)
  Copy-Item -LiteralPath $inputManifest -Destination (Join-Path $auditDir 'SOURCE_INPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $outputManifest -Destination (Join-Path $auditDir 'SOURCE_OUTPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $contract -Destination (Join-Path $auditDir 'SOURCE_CONTRACT_SUMMARY.txt') -Force

  Write-Host "EXP22_8_PATCH_TRANSPORT=PASS RAW_SHA256=$rawSha CANONICAL_LF_SHA256=$canonicalSha CRLF=$crlfCount"
  Write-Host "EXP22_8_PATCH=PASS SHA256=$canonicalSha FILES=4"
  Write-Host 'EXP22_8_SOURCE_AUDIT=PASS FULL_CAPACITY_SBT=1 TRANSIENT_ISOLATION=1'
}
finally { Pop-Location }
