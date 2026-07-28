param(
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$work = (Resolve-Path -LiteralPath $WorkRoot).Path
Push-Location $work
try {
  $rebuiltPath = Join-Path $work 'WolfSP.exe'
  foreach ($required in @(
    $rebuiltPath,
    (Join-Path $work 'main/cgamex64.dll'),
    (Join-Path $work 'main/qagamex64.dll'),
    (Join-Path $work 'main/uix64.dll'),
    (Join-Path $work 'ci/exp22_6/EXP22_6_COMPILE_MANIFEST.txt'),
    (Join-Path $work 'ci/exp22_6/BUILD_GRAPH_AUDIT.txt')
  )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Required verified compile output is missing: $required"
    }
  }

  $exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $rebuiltPath).Hash
  $kit = Join-Path $work 'ci/exp22_6'
  $sourceDiff = Join-Path $kit 'EXP22_6_SOURCE_DIFF.patch'
  if (-not (Test-Path -LiteralPath $sourceDiff -PathType Leaf)) {
    throw "EXP22.6 source diff is missing: $sourceDiff"
  }
  $sourceDiffSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceDiff).Hash

  $release = Join-Path $work 'release-darkwolf-exp22_6-performance-lifecycle'
  if (Test-Path -LiteralPath $release) {
    Remove-Item -LiteralPath $release -Recurse -Force
  }
  $mainDir = Join-Path $release 'main'
  $testDir = Join-Path $release 'exp22_6_tests'
  $mainTestDir = Join-Path $mainDir 'exp22_6_tests'
  New-Item -ItemType Directory -Path $mainDir, $testDir, $mainTestDir -Force | Out-Null

  Copy-Item -LiteralPath $rebuiltPath -Destination (Join-Path $release 'WolfSP.exe') -Force

  $vmNameRegex = '^(cgamex64|qagamex64|uix64).*\.dll$'
  $rootRuntimeDlls = @(
    Get-ChildItem -LiteralPath $work -File -Filter '*.dll' |
      Where-Object { $_.Name -notmatch $vmNameRegex } |
      Sort-Object Name
  )
  if ($rootRuntimeDlls.Count -eq 0) {
    throw 'No root runtime DLLs were found in the exact source checkout.'
  }
  foreach ($dll in $rootRuntimeDlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $release $dll.Name) -Force
  }

  foreach ($requiredName in @('OpenAL32.dll','dxcompiler.dll','dxil.dll','sl.interposer.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $requiredName) -PathType Leaf)) {
      throw "Required production runtime file was not packaged: $requiredName"
    }
  }

  foreach ($vmName in @('cgamex64.dll','qagamex64.dll','uix64.dll')) {
    Copy-Item -LiteralPath (Join-Path $work (Join-Path 'main' $vmName)) -Destination (Join-Path $mainDir $vmName) -Force
  }

  $productionCfg = Join-Path $kit 'darkwolf_exp22_6_production.cfg'
  if (-not (Test-Path -LiteralPath $productionCfg -PathType Leaf)) {
    throw "EXP22.6 production CFG is missing: $productionCfg"
  }
  Copy-Item -LiteralPath $productionCfg -Destination (Join-Path $mainDir 'darkwolf_exp22_6_production.cfg') -Force

  foreach ($cfg in @('01_compression_off.cfg','02_compression_on.cfg','03_reflections_off.cfg','04_dxr_off.cfg')) {
    $source = Join-Path $kit $cfg
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Test CFG missing: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $mainTestDir $cfg) -Force
  }
  foreach ($tool in @('RUN_EXP22_6_PRODUCTION.bat','RUN_EXP22_6_TESTS.bat','RUN_WITHOUT_4K_PACKS.ps1','EXP22_6_COLLECT_RESULTS.ps1')) {
    $source = Join-Path $kit $tool
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Test tool missing: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $testDir $tool) -Force
  }

  $launcher = @(
    '@echo off',
    'setlocal',
    'cd /d "%~dp0"',
    'echo Starting DarkWolf EXP22.6 Performance and Lifecycle...',
    'WolfSP.exe +set r_dxr 1 +exec darkwolf_exp22_6_production.cfg',
    'endlocal'
  )
  [IO.File]::WriteAllText(
    (Join-Path $release 'RUN_DARKWOLF_EXP22_6_PRODUCTION.bat'),
    (($launcher -join "`r`n") + "`r`n"),
    [Text.Encoding]::ASCII
  )

  $utf8NoBom = [Text.UTF8Encoding]::new($false)
  $readme = @"
DarkWolf Experiment 22.6 - Performance and Lifecycle Release
============================================================

Built from the validated EXP22.5 production chain with the audited EXP22.6 patch.
The build graph is explicit and excludes the unrelated Radiant editor.

Production synchronization:
- r_finish 0
- r_dxrCpuSync 0

Performance changes:
- reflection binding preparation is skipped when reflections are disabled;
- hit-surface descriptors and hit tables are cached when unchanged;
- stale RT instances are pruned and registries are compacted;
- map clear resets RT lifecycle state;
- BJ2 invalid model-frame logging is rate-limited and wrapped safely;
- EXP22_6_PERF telemetry reports FPS, 1% low, CPU/GPU time, preparation/table time, instance counts and VRAM.

Start:
  RUN_DARKWOLF_EXP22_6_PRODUCTION.bat

Original commercial RTCW PK3 files are not included.
WolfSP.exe SHA-256: $exeSha
EXP22.6 source diff SHA-256: $sourceDiffSha
Canonical base: 229cd5d93b4c24ba705c9821a871cccf31b34b96
"@
  [IO.File]::WriteAllText((Join-Path $release 'README_EXP22_6_PERFORMANCE_LIFECYCLE_RU.txt'), ($readme.Trim() + "`r`n"), $utf8NoBom)

  $manifest = @"
DARKWOLF_EXP22_6_PERFORMANCE_LIFECYCLE_RELEASE
Configuration=Release
Platform=x64
CanonicalBase=229cd5d93b4c24ba705c9821a871cccf31b34b96
EXP22_4_DonorWorkflowSHA256=DB30552F3B2663A41892CDD434370A58F468F82C1A5229358E14E09BE2425D0A
EXP22_4_PayloadSHA256=2B2A7C867CDA10D6324AC114F0F5F9AEE05D20FAA50341F417F7C87A6330D393
EXP22_6_PatchSHA256=176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170
BuildProjectReferences=0
RadiantBuilt=0
EXP20_SelectionMode=2
EXP20_Hysteresis=0.25
EXP20_HoldFrames=12
EXP22_4_BoundedProductionCompositeIncluded=1
EXP22_6_BindingCache=1
EXP22_6_LifecycleCompaction=1
EXP22_6_GpuTimestampQueries=1
EXP22_6_VramTelemetry=1
EXP22_6_ModelFrameWrap=1
PackageType=FULL_ENGINE_RUNTIME
OriginalCommercialPK3Included=0
WolfSP_SHA256=$exeSha
EXP22_6_SourceDiffSHA256=$sourceDiffSha
"@
  [IO.File]::WriteAllText((Join-Path $release 'BUILD_MANIFEST.txt'), ($manifest.Trim() + "`r`n"), $utf8NoBom)
  Copy-Item -LiteralPath (Join-Path $kit 'EXP22_6_COMPILE_MANIFEST.txt') -Destination (Join-Path $release 'EXP22_6_COMPILE_MANIFEST.txt') -Force
  Copy-Item -LiteralPath (Join-Path $kit 'BUILD_GRAPH_AUDIT.txt') -Destination (Join-Path $release 'BUILD_GRAPH_AUDIT.txt') -Force

  $forbiddenExtensions = @('.pdb','.obj','.lib','.exp','.ilk','.vcxproj','.sln','.patch','.py')
  $allowedPs1 = @('RUN_WITHOUT_4K_PACKS.ps1','EXP22_6_COLLECT_RESULTS.ps1')
  $forbidden = @(Get-ChildItem -LiteralPath $release -Recurse -File | Where-Object {
    $_.Extension.ToLowerInvariant() -in $forbiddenExtensions -or
    ($_.Extension.ToLowerInvariant() -eq '.ps1' -and $_.Name -notin $allowedPs1)
  })
  if ($forbidden.Count -ne 0) { throw "Forbidden non-runtime files found: $($forbidden.FullName -join ', ')" }

  $filesBeforeSums = @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)
  $sumLines = foreach ($file in $filesBeforeSums) {
    $relative = $file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    "$hash  $relative"
  }
  [IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS.txt'), (($sumLines -join "`r`n") + "`r`n"), $utf8NoBom)

  $finalFiles = @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)
  $totalBytes = [int64](($finalFiles | Measure-Object -Property Length -Sum).Sum)
  $totalMiB = [math]::Round($totalBytes / 1MB, 2)
  if ($totalBytes -lt 100MB -or $totalBytes -gt 160MB) {
    throw "Full production runtime size is outside the validated range: $totalMiB MiB"
  }
  $contents = foreach ($file in $finalFiles) {
    $relative = $file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/')
    '{0,12}  {1}' -f $file.Length, $relative
  }
  [IO.File]::WriteAllText(
    (Join-Path $release 'FULL_RELEASE_CONTENTS.txt'),
    ((@("TOTAL_BYTES=$totalBytes", "TOTAL_MIB=$totalMiB", '') + $contents) -join "`r`n") + "`r`n",
    $utf8NoBom
  )

  Write-Host "EXP22_6_FULL_PRODUCTION_PACKAGE=PASS FILES=$($finalFiles.Count) TOTAL_BYTES=$totalBytes TOTAL_MIB=$totalMiB WolfSP_SHA256=$exeSha"
}
finally {
  Pop-Location
}
