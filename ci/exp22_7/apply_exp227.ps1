param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$kit = Join-Path $repo 'ci/exp22_7'
$patchSource = Join-Path $kit '360-d3d12-static-dynamic-hit-table-exp22_7.patch'
$inputManifest = Join-Path $kit 'SOURCE_INPUT_SHA256SUMS.txt'
$outputManifest = Join-Path $kit 'SOURCE_OUTPUT_SHA256SUMS.txt'
$contract = Join-Path $kit 'SOURCE_CONTRACT_SUMMARY.txt'

foreach ($required in @($patchSource,$inputManifest,$outputManifest,$contract)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required EXP22.7 kit file is missing: $required"
  }
}

$sourceFiles = @(
  'src/opengl/gl_d3d12raylight.cpp',
  'src/opengl/opengl.h',
  'src/renderer/tr_cmds.cpp'
)

function Get-Sha256Hex {
  param([Parameter(Mandatory=$true)][byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
  finally { $sha.Dispose() }
}

# The repository payload is validated first in its original canonical LF form.
# A deterministic two-site compatibility transform then protects std::max from
# the legacy Windows max macro without changing EXP22.7 runtime behavior.
$expectedSourcePatchSha = '04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444'
$expectedEffectivePatchSha = '6495B878E8E35E51080020236AE5075BDA5B0BC4482AE157BF3D6531D632F61E'
$rawPatchBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $patchSource))
$rawPatchSha = Get-Sha256Hex -Bytes $rawPatchBytes
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
try { $patchText = $utf8Strict.GetString($rawPatchBytes) }
catch { throw "EXP22.7 patch is not valid UTF-8 text: $($_.Exception.Message)" }
if ($patchText.Length -gt 0 -and $patchText[0] -eq [char]0xFEFF) {
  $patchText = $patchText.Substring(1)
}
$crlfCount = ([regex]::Matches($patchText, "`r`n")).Count
$sourcePatchText = $patchText.Replace("`r`n", "`n").Replace("`r", "`n")
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$sourcePatchBytes = $utf8NoBom.GetBytes($sourcePatchText)
$sourcePatchSha = Get-Sha256Hex -Bytes $sourcePatchBytes
if ($sourcePatchSha -ne $expectedSourcePatchSha) {
  throw "EXP22.7 source patch hash mismatch. Expected=$expectedSourcePatchSha Actual=$sourcePatchSha Raw=$rawPatchSha"
}

$macroSites = @(
  'g_glRaytracingExp226.exp227HitSlotHighWater = std::max(',
  'highestActiveSlot = std::max(highestActiveSlot, inst.exp227HitSlot + 1u);'
)
foreach ($site in $macroSites) {
  $count = ([regex]::Matches($sourcePatchText, [regex]::Escape($site))).Count
  if ($count -ne 1) {
    throw "EXP22.7 MSVC compatibility anchor count mismatch. Anchor=[$site] Expected=1 Actual=$count"
  }
}
$effectivePatchText = $sourcePatchText.Replace(
  $macroSites[0],
  'g_glRaytracingExp226.exp227HitSlotHighWater = (std::max)(').Replace(
  $macroSites[1],
  'highestActiveSlot = (std::max)(highestActiveSlot, inst.exp227HitSlot + 1u);')
$effectivePatchBytes = $utf8NoBom.GetBytes($effectivePatchText)
$effectivePatchSha = Get-Sha256Hex -Bytes $effectivePatchBytes
if ($effectivePatchSha -ne $expectedEffectivePatchSha) {
  throw "EXP22.7 effective patch hash mismatch. Expected=$expectedEffectivePatchSha Actual=$effectivePatchSha"
}

$effectivePatch = Join-Path $env:RUNNER_TEMP 'exp22_7-static-dynamic-hit-table-msvc-safe-lf.patch'
[IO.File]::WriteAllBytes($effectivePatch, $effectivePatchBytes)

$auditDir = Join-Path $work 'ci/exp22_7'
New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
$transportAudit = @(
  'DARKWOLF_EXP22_7_PATCH_TRANSPORT_AUDIT',
  "SourcePath=$patchSource",
  "RawSHA256=$rawPatchSha",
  "SourceCanonicalLFSHA256=$sourcePatchSha",
  "ExpectedSourceCanonicalLFSHA256=$expectedSourcePatchSha",
  "EffectiveMSVCSafeLFSHA256=$effectivePatchSha",
  "ExpectedEffectiveMSVCSafeLFSHA256=$expectedEffectivePatchSha",
  "RawBytes=$($rawPatchBytes.Length)",
  "SourceCanonicalBytes=$($sourcePatchBytes.Length)",
  "EffectiveBytes=$($effectivePatchBytes.Length)",
  "CRLFSequences=$crlfCount",
  'CompatibilityTransform=parenthesize-two-std-max-calls',
  'CanonicalEncoding=UTF-8-no-BOM',
  'CanonicalLineEnding=LF'
)
[IO.File]::WriteAllLines((Join-Path $auditDir 'PATCH_TRANSPORT_AUDIT.txt'), $transportAudit, $utf8NoBom)
[IO.File]::WriteAllBytes(
  (Join-Path $auditDir '360-d3d12-static-dynamic-hit-table-exp22_7-effective-msvc-safe.patch'),
  $effectivePatchBytes)

function Normalize-SourceToCanonicalLf {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $path = Join-Path $work $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.7 source file is missing before normalization: $RelativePath"
  }
  $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path))
  [IO.File]::WriteAllText($path, $body.Replace("`r`n", "`n").Replace("`r", "`n"), $utf8NoBom)
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

  foreach ($sourceFile in $sourceFiles) {
    Normalize-SourceToCanonicalLf -RelativePath $sourceFile
  }

  Test-Manifest -Manifest $inputManifest -Phase 'INPUT'

  git apply --check --whitespace=error-all -- $effectivePatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 effective patch pre-apply check failed.' }
  git apply --whitespace=error-all -- $effectivePatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 effective patch application failed.' }
  git diff --check -- $sourceFiles
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 source diff contains whitespace errors.' }
  git apply --reverse --check -- $effectivePatch
  if ($LASTEXITCODE -ne 0) { throw 'EXP22.7 effective reverse patch verification failed.' }

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
    @('src/opengl/gl_d3d12raylight.cpp', '(std::max)('),
    @('src/renderer/tr_cmds.cpp', 'EXP22_7_PERF'),
    @('src/opengl/opengl.h', 'fullTableRebuilds')
  )
  foreach ($marker in $markers) {
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $marker[0]))
    if (-not $body.Contains($marker[1])) {
      throw "EXP22.7 required marker missing: $($marker[0]) :: $($marker[1])"
    }
  }
  $rayBody = [IO.File]::ReadAllText((Resolve-Path -LiteralPath 'src/opengl/gl_d3d12raylight.cpp'))
  if ($rayBody.Contains('std::max(')) {
    throw 'EXP22.7 source still contains an unprotected std::max call that can collide with the Windows max macro.'
  }

  $diff = git diff -- $sourceFiles
  $diffText = $diff -join "`n"
  if ([string]::IsNullOrWhiteSpace($diffText)) {
    throw 'EXP22.7 patch produced no source diff.'
  }
  [IO.File]::WriteAllText((Join-Path $auditDir 'EXP22_7_SOURCE_DIFF.patch'), ($diffText + "`n"), $utf8NoBom)
  Copy-Item -LiteralPath $inputManifest -Destination (Join-Path $auditDir 'SOURCE_INPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $outputManifest -Destination (Join-Path $auditDir 'SOURCE_OUTPUT_SHA256SUMS.txt') -Force
  Copy-Item -LiteralPath $contract -Destination (Join-Path $auditDir 'SOURCE_CONTRACT_SUMMARY.txt') -Force

  Write-Host "EXP22_7_PATCH_TRANSPORT=PASS RAW_SHA256=$rawPatchSha SOURCE_LF_SHA256=$sourcePatchSha EFFECTIVE_SHA256=$effectivePatchSha CRLF=$crlfCount"
  Write-Host "EXP22_7_PATCH=PASS SHA256=$effectivePatchSha FILES=3 MSVC_MAX_MACRO_SAFE=1"
  Write-Host 'EXP22_7_SOURCE_AUDIT=PASS'
}
finally {
  Pop-Location
}
