param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$basePackager = Join-Path $repo 'ci/exp22_6/package_exp226.ps1'
if (-not (Test-Path -LiteralPath $basePackager -PathType Leaf)) {
  throw "Proven EXP22.6 packager is missing: $basePackager"
}

& $basePackager -WorkRoot $work
if ($LASTEXITCODE -ne 0) { throw "EXP22.6 base packager returned exit code $LASTEXITCODE" }

$baseRelease = Join-Path $work 'release-darkwolf-exp22_6-performance-lifecycle'
$release = Join-Path $work 'release-darkwolf-exp22_8-persistent-dynamic-sbt'
if (-not (Test-Path -LiteralPath $baseRelease -PathType Container)) {
  throw "EXP22.6 base runtime was not produced: $baseRelease"
}
if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Recurse -Force }
Move-Item -LiteralPath $baseRelease -Destination $release

$main = Join-Path $release 'main'
$baseCfg = Join-Path $main 'darkwolf_exp22_6_production.cfg'
$cfg = Join-Path $main 'darkwolf_exp22_8_production.cfg'
if (-not (Test-Path -LiteralPath $baseCfg -PathType Leaf)) {
  throw "Base production profile is missing: $baseCfg"
}
Copy-Item -LiteralPath $baseCfg -Destination $cfg -Force

foreach ($obsolete in @(
  'RUN_DARKWOLF_EXP22_6_PRODUCTION.bat',
  'README_EXP22_6_PERFORMANCE_LIFECYCLE_RU.txt'
)) {
  $path = Join-Path $release $obsolete
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

$launcher = @(
  '@echo off',
  'setlocal EnableExtensions',
  'cd /d "%~dp0"',
  'echo Starting DarkWolf EXP22.8 Persistent Dynamic SBT...',
  'WolfSP.exe +set r_dxr 1 +exec darkwolf_exp22_8_production.cfg',
  'endlocal'
)
[IO.File]::WriteAllText(
  (Join-Path $release 'RUN_DARKWOLF_EXP22_8_PRODUCTION.bat'),
  (($launcher -join "`r`n") + "`r`n"),
  [Text.Encoding]::ASCII)

$runtimeTools = Join-Path $repo 'ci/exp22_8/runtime_tools'
foreach ($name in @(
  'RUN_EXP22_8_TEST_AND_AUTO_COLLECT.bat',
  'EXP22_8_TEST_AND_AUTO_COLLECT.ps1'
)) {
  $source = Join-Path $runtimeTools $name
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "EXP22.8 runtime test tool is missing: $source"
  }
  Copy-Item -LiteralPath $source -Destination (Join-Path $release $name) -Force
}

$exe = Join-Path $release 'WolfSP.exe'
$compileManifest = Join-Path $work 'ci/exp22_8/EXP22_8_COMPILE_MANIFEST.txt'
$sourceDiff = Join-Path $work 'ci/exp22_8/EXP22_8_SOURCE_DIFF.patch'
foreach ($required in @($exe,$compileManifest,$sourceDiff)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required EXP22.8 package input is missing: $required"
  }
}
Copy-Item -LiteralPath $compileManifest -Destination (Join-Path $release 'EXP22_8_COMPILE_MANIFEST.txt') -Force

$exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$sourceDiffSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceDiff).Hash
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$readme = @"
DarkWolf EXP22.8 - Persistent Dynamic SBT Capacity and Transient Effect Isolation
=================================================================================

Это полный Release x64 runtime поверх проверенной цепочки EXP22.4, EXP22.6 и EXP22.7.
Графические параметры EXP20 и EXP22.4 не изменены.

Основные изменения EXP22.8:
- shader binding table выделяется один раз на полную емкость 131072 slots;
- рост dynamic high-water больше не пересоздает SBT и не переписывает старые records;
- новый dynamic slot записывает только свою пару shadow/reflection records;
- отдельно учитываются allocated capacity, monotonic high-water, active high-water,
  live records и фактический DispatchRays span;
- transform, position, touch, visibility и animation frame с тем же SRV не повышают bindingRev;
- muzzle flash, smoke, particles, brass, impacts, decals и additive effects
  отсекаются до создания BLAS/TLAS и reflection SBT entry;
- добавлена телеметрия EXP22_8_PERF.

Коды fullRebuildReason:
  0 = none / no resource rebuild recorded;
  1 = initial full-capacity allocation;
  2 = D3D12 SBT resource recovery;
  3 = CPU shadow recovery.

Запуск игры:
  RUN_DARKWOLF_EXP22_8_PRODUCTION.bat

Автоматический тест и сбор ZIP после закрытия игры:
  RUN_EXP22_8_TEST_AND_AUTO_COLLECT.bat

Ключевой критерий теста при стрельбе:
- fullRebuilds не должен увеличиваться из-за sbtHighWater/dispatchSlots;
- updatedNow должен отражать только новые или реально измененные bindings;
- transientSkipped и muzzleInstances должны увеличиваться;
- hitTableMs не должен соответствовать переписыванию 15-16 тысяч records.

Оригинальные коммерческие RTCW PK3 в архив не включены.

WolfSP.exe SHA-256: $exeSha
EXP22.8 source diff SHA-256: $sourceDiffSha
Canonical base: 229cd5d93b4c24ba705c9821a871cccf31b34b96
EXP22.6 patch SHA-256: 176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170
EXP22.7 source patch SHA-256: 04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444
EXP22.8 patch SHA-256: D9DAE13EA2DA365EFCFC11A9F42F5F78B1D0673516E589DEDB4F87287B660BE3
"@
[IO.File]::WriteAllText(
  (Join-Path $release 'README_EXP22_8_PERSISTENT_DYNAMIC_SBT_RU.txt'),
  ($readme.Trim() + "`r`n"),
  $utf8NoBom)

$manifestPath = Join-Path $release 'BUILD_MANIFEST.txt'
$existingManifest = if (Test-Path -LiteralPath $manifestPath) {
  [IO.File]::ReadAllText((Resolve-Path -LiteralPath $manifestPath))
} else { '' }
$exp228Manifest = @"

DARKWOLF_EXP22_8_PERSISTENT_DYNAMIC_SBT
EXP22_8_PatchSHA256=D9DAE13EA2DA365EFCFC11A9F42F5F78B1D0673516E589DEDB4F87287B660BE3
EXP22_8_SourceDiffSHA256=$sourceDiffSha
EXP22_8_SBTCapacitySlots=131072
EXP22_8_StaticSlotLimit=32768
EXP22_8_HighWaterReallocation=0
EXP22_8_HighWaterFullRewrite=0
EXP22_8_PerSlotIncrementalWrite=1
EXP22_8_TransientIsolationBeforeBLAS=1
EXP22_8_TransformOnlyBindingRevision=0
EXP22_8_TouchVisibilityBindingRevision=0
EXP22_8_SameSRVAnimationBindingRevision=0
EXP22_8_TelemetryPrefix=EXP22_8_PERF
WolfSP_SHA256=$exeSha
"@
[IO.File]::WriteAllText(
  $manifestPath,
  ($existingManifest.TrimEnd() + $exp228Manifest + "`r`n"),
  $utf8NoBom)

foreach ($name in @('SHA256SUMS.txt','FULL_RELEASE_CONTENTS.txt')) {
  $path = Join-Path $release $name
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
$filesBeforeSums = @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)
$sumLines = foreach ($file in $filesBeforeSums) {
  $relative = $file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/')
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
  "$hash  $relative"
}
[IO.File]::WriteAllText(
  (Join-Path $release 'SHA256SUMS.txt'),
  (($sumLines -join "`r`n") + "`r`n"),
  $utf8NoBom)

$finalFiles = @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)
$totalBytes = [int64](($finalFiles | Measure-Object -Property Length -Sum).Sum)
$totalMiB = [math]::Round($totalBytes / 1MB, 2)
if ($totalBytes -lt 100MB -or $totalBytes -gt 165MB) {
  throw "EXP22.8 full runtime size is outside the validated range: $totalMiB MiB"
}
$contentLines = foreach ($file in $finalFiles) {
  $relative = $file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/')
  '{0,12}  {1}' -f $file.Length, $relative
}
[IO.File]::WriteAllText(
  (Join-Path $release 'FULL_RELEASE_CONTENTS.txt'),
  ((@("TOTAL_BYTES=$totalBytes", "TOTAL_MIB=$totalMiB", '') + $contentLines) -join "`r`n") + "`r`n",
  $utf8NoBom)

foreach ($required in @(
  'WolfSP.exe',
  'RUN_DARKWOLF_EXP22_8_PRODUCTION.bat',
  'RUN_EXP22_8_TEST_AND_AUTO_COLLECT.bat',
  'EXP22_8_TEST_AND_AUTO_COLLECT.ps1',
  'main/cgamex64.dll',
  'main/qagamex64.dll',
  'main/uix64.dll',
  'main/darkwolf_exp22_8_production.cfg',
  'README_EXP22_8_PERSISTENT_DYNAMIC_SBT_RU.txt',
  'EXP22_8_COMPILE_MANIFEST.txt',
  'BUILD_MANIFEST.txt',
  'SHA256SUMS.txt',
  'FULL_RELEASE_CONTENTS.txt'
)) {
  $path = Join-Path $release $required
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.8 packaged runtime file is missing: $required"
  }
}

Write-Host "EXP22_8_FULL_PRODUCTION_PACKAGE=PASS FILES=$($finalFiles.Count) TOTAL_MIB=$totalMiB WolfSP_SHA256=$exeSha"
