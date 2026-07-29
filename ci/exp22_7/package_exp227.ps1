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

$baseRelease = Join-Path $work 'release-darkwolf-exp22_6-performance-lifecycle'
$release = Join-Path $work 'release-darkwolf-exp22_7-static-dynamic-hit-table'
if (-not (Test-Path -LiteralPath $baseRelease -PathType Container)) {
  throw "EXP22.6 base runtime was not produced: $baseRelease"
}
if (Test-Path -LiteralPath $release) {
  Remove-Item -LiteralPath $release -Recurse -Force
}
Move-Item -LiteralPath $baseRelease -Destination $release

$main = Join-Path $release 'main'
$baseCfg = Join-Path $main 'darkwolf_exp22_6_production.cfg'
$cfg = Join-Path $main 'darkwolf_exp22_7_production.cfg'
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
  'setlocal',
  'cd /d "%~dp0"',
  'echo Starting DarkWolf EXP22.7 Static/Dynamic Hit Table...',
  'WolfSP.exe +set r_dxr 1 +exec darkwolf_exp22_7_production.cfg',
  'endlocal'
)
[IO.File]::WriteAllText(
  (Join-Path $release 'RUN_DARKWOLF_EXP22_7_PRODUCTION.bat'),
  (($launcher -join "`r`n") + "`r`n"),
  [Text.Encoding]::ASCII)

$runtimeTools = Join-Path $repo 'ci/exp22_7/runtime_tools'
foreach ($name in @(
  'RUN_EXP22_7_TEST_AND_AUTO_COLLECT.bat',
  'EXP22_7_TEST_AND_AUTO_COLLECT.ps1'
)) {
  $source = Join-Path $runtimeTools $name
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "EXP22.7 runtime test tool is missing: $source"
  }
  Copy-Item -LiteralPath $source -Destination (Join-Path $release $name) -Force
}

$exe = Join-Path $release 'WolfSP.exe'
$compileManifest = Join-Path $work 'ci/exp22_7/EXP22_7_COMPILE_MANIFEST.txt'
$sourceDiff = Join-Path $work 'ci/exp22_7/EXP22_7_SOURCE_DIFF.patch'
foreach ($required in @($exe,$compileManifest,$sourceDiff)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required EXP22.7 package input is missing: $required"
  }
}
$exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$sourceDiffSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceDiff).Hash
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$readme = @"
DarkWolf EXP22.7 - Static/Dynamic Hit Table Split and Incremental Binding Updates
=================================================================================

Это полный игровой runtime, построенный на проверенной цепочке EXP22.5/EXP22.6.
Графические параметры EXP20 и EXP22.4 не изменены.

Основные изменения EXP22.7:
- стабильные hit-table slots вместо привязки к плотному индексу active list;
- логическое разделение статических и динамических записей в одном D3D12 SBT;
- статический диапазон 0..32767, динамический диапазон 32768..131071;
- обновление только dirty texture descriptors и shader records;
- постоянный CPU shadow и persistently mapped upload hit table;
- повторное использование освобождённых slots;
- compaction при не менее 256 stale instances и доле stale от 5%;
- один fence wait перед изменением shared descriptors/SBT вместо повторного wait внутри hit-table timing;
- новая телеметрия EXP22_7_PERF.

Запуск игры:
  RUN_DARKWOLF_EXP22_7_PRODUCTION.bat

Полностью автоматический тест и сбор ZIP после закрытия игры:
  RUN_EXP22_7_TEST_AND_AUTO_COLLECT.bat

Ожидаемое поведение телеметрии:
- fullRebuilds увеличивается главным образом при первом построении/расширении таблицы;
- partialUpdates увеличивается при изменениях динамических материалов;
- updatedNow обычно значительно меньше active;
- staticActive остаётся стабильным;
- reusedSlots увеличивается при удалении и повторном создании динамических объектов;
- hitTableMs на partial update не должен соответствовать стоимости полного прохода по 15 тысячам записей.

Оригинальные коммерческие RTCW PK3 в архив не включены.

WolfSP.exe SHA-256: $exeSha
EXP22.7 source diff SHA-256: $sourceDiffSha
Canonical base: 229cd5d93b4c24ba705c9821a871cccf31b34b96
EXP22.6 patch SHA-256: 176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170
EXP22.7 patch SHA-256: 04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444
"@
[IO.File]::WriteAllText(
  (Join-Path $release 'README_EXP22_7_STATIC_DYNAMIC_HIT_TABLE_RU.txt'),
  ($readme.Trim() + "`r`n"),
  $utf8NoBom)

$manifestPath = Join-Path $release 'BUILD_MANIFEST.txt'
$existingManifest = if (Test-Path -LiteralPath $manifestPath) {
  [IO.File]::ReadAllText((Resolve-Path -LiteralPath $manifestPath))
} else { '' }
$exp227Manifest = @"

DARKWOLF_EXP22_7_STATIC_DYNAMIC_HIT_TABLE
EXP22_7_PatchSHA256=04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444
EXP22_7_SourceDiffSHA256=$sourceDiffSha
EXP22_7_StaticSlotLimit=32768
EXP22_7_MaxHitSlots=131072
EXP22_7_StableHitSlots=1
EXP22_7_IncrementalPrepare=1
EXP22_7_IncrementalShaderRecords=1
EXP22_7_PersistentMappedHitTable=1
EXP22_7_SlotReuse=1
EXP22_7_CompactionMinimumStale=256
EXP22_7_CompactionPercent=5
EXP22_7_TelemetryPrefix=EXP22_7_PERF
WolfSP_SHA256=$exeSha
"@
[IO.File]::WriteAllText(
  $manifestPath,
  ($existingManifest.TrimEnd() + $exp227Manifest + "`r`n"),
  $utf8NoBom)

# Recreate integrity files after EXP22.7 post-processing.
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
  throw "EXP22.7 full runtime size is outside the validated range: $totalMiB MiB"
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
  'RUN_DARKWOLF_EXP22_7_PRODUCTION.bat',
  'RUN_EXP22_7_TEST_AND_AUTO_COLLECT.bat',
  'EXP22_7_TEST_AND_AUTO_COLLECT.ps1',
  'main/cgamex64.dll',
  'main/qagamex64.dll',
  'main/uix64.dll',
  'main/darkwolf_exp22_7_production.cfg',
  'README_EXP22_7_STATIC_DYNAMIC_HIT_TABLE_RU.txt',
  'BUILD_MANIFEST.txt',
  'SHA256SUMS.txt',
  'FULL_RELEASE_CONTENTS.txt'
)) {
  $path = Join-Path $release $required
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.7 packaged runtime file is missing: $required"
  }
}

Write-Host "EXP22_7_FULL_PRODUCTION_PACKAGE=PASS FILES=$($finalFiles.Count) TOTAL_MIB=$totalMiB WolfSP_SHA256=$exeSha"
