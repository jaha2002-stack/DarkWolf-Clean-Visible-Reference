param(
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$work = (Resolve-Path -LiteralPath $WorkRoot).Path
Push-Location $work
try {
  $msbuild = (Get-Command msbuild.exe -ErrorAction Stop).Source

  $project = Join-Path $work 'src/wolf.vcxproj'
  if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "WolfSP project is missing: $project"
  }
  $projectText = [IO.File]::ReadAllText((Resolve-Path $project))
  if (-not $projectText.Contains('<OutputFile>../WolfSP.exe</OutputFile>')) {
    throw 'Release x64 WolfSP output contract changed; expected ../WolfSP.exe.'
  }

  $rebuiltPath = Join-Path $work 'WolfSP.exe'
  if (Test-Path -LiteralPath $rebuiltPath) {
    Remove-Item -LiteralPath $rebuiltPath -Force
  }

  & $msbuild $project '/t:Rebuild' '/p:Configuration=Release' '/p:Platform=x64' '/m' '/verbosity:minimal'
  if ($LASTEXITCODE -ne 0) {
    throw "EXP22.6 WolfSP Release x64 build failed: $LASTEXITCODE"
  }
  if (-not (Test-Path -LiteralPath $rebuiltPath -PathType Leaf)) {
    throw "EXP22.6 build completed without the exact Release x64 output: $rebuiltPath"
  }
  $rebuilt = Get-Item -LiteralPath $rebuiltPath
  if ($rebuilt.Length -lt 1MB) {
    throw "Rebuilt WolfSP.exe is unexpectedly small: $($rebuilt.Length)"
  }

  $sourceRelease = Join-Path $work 'release-rt-reflection-native-composite-exp22_4'
  if (-not (Test-Path -LiteralPath $sourceRelease -PathType Container)) {
    throw "EXP22.4 release directory is missing: $sourceRelease"
  }
  Copy-Item -LiteralPath $rebuiltPath -Destination (Join-Path $sourceRelease 'WolfSP.exe') -Force
  $exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $rebuiltPath).Hash
  Write-Host "EXP22_6_WOLFSP_BUILD=PASS SHA256=$exeSha"

  $releaseOutputs = [ordered]@{
    'src/cgame/cgame.vcxproj' = 'main/cgamex64.dll'
    'src/game/game.vcxproj'   = 'main/qagamex64.dll'
    'src/ui/ui.vcxproj'       = 'main/uix64.dll'
  }
  foreach ($output in $releaseOutputs.Values) {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
  }

  function Invoke-ReleaseVmBuild {
    param(
      [Parameter(Mandatory=$true)][string]$Project,
      [switch]$AllowSingleRetry
    )
    $arguments = @(
      $Project,
      '/t:Build',
      '/p:Configuration=Release',
      '/p:Platform=x64',
      '/p:BuildProjectReferences=false',
      '/m',
      '/verbosity:minimal'
    )
    & $msbuild @arguments
    $firstExit = $LASTEXITCODE
    if ($firstExit -eq 0) { return }
    if (-not $AllowSingleRetry) {
      throw "Release x64 VM build failed: Project=$Project ExitCode=$firstExit"
    }
    & $msbuild @arguments
    if ($LASTEXITCODE -ne 0) {
      throw "Release x64 VM build failed after retry: Project=$Project ExitCode=$LASTEXITCODE"
    }
  }

  Invoke-ReleaseVmBuild -Project 'src/cgame/cgame.vcxproj'
  Invoke-ReleaseVmBuild -Project 'src/ui/ui.vcxproj'
  Invoke-ReleaseVmBuild -Project 'src/game/game.vcxproj' -AllowSingleRetry

  foreach ($entry in $releaseOutputs.GetEnumerator()) {
    $output = $entry.Value
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
      throw "Exact Release x64 VM output is missing: $output"
    }
    $item = Get-Item -LiteralPath $output
    if ($item.Name -match '_d\.dll$' -or $item.Length -lt 524288) {
      throw "Invalid Release VM module: $($item.FullName) Size=$($item.Length)"
    }
  }
  Write-Host 'EXP22_6_RELEASE_VM_BUILD=PASS'

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

  foreach ($required in @('OpenAL32.dll','dxcompiler.dll','dxil.dll','sl.interposer.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $required) -PathType Leaf)) {
      throw "Required production runtime file was not packaged: $required"
    }
  }

  foreach ($vmName in @('cgamex64.dll','qagamex64.dll','uix64.dll')) {
    $sourceVm = Join-Path $work (Join-Path 'main' $vmName)
    if (-not (Test-Path -LiteralPath $sourceVm -PathType Leaf)) {
      throw "Exact Release VM module is missing before packaging: $sourceVm"
    }
    Copy-Item -LiteralPath $sourceVm -Destination (Join-Path $mainDir $vmName) -Force
  }

  $kit = Join-Path $work 'ci/exp22_6'
  $productionCfg = Join-Path $kit 'darkwolf_exp22_6_production.cfg'
  if (-not (Test-Path -LiteralPath $productionCfg -PathType Leaf)) {
    throw "EXP22.6 production CFG is missing: $productionCfg"
  }
  Copy-Item -LiteralPath $productionCfg -Destination (Join-Path $mainDir 'darkwolf_exp22_6_production.cfg') -Force

  foreach ($cfg in @('01_compression_off.cfg','02_compression_on.cfg','03_reflections_off.cfg','04_dxr_off.cfg')) {
    Copy-Item -LiteralPath (Join-Path $kit $cfg) -Destination (Join-Path $mainTestDir $cfg) -Force
  }
  foreach ($tool in @('RUN_EXP22_6_PRODUCTION.bat','RUN_EXP22_6_TESTS.bat','RUN_WITHOUT_4K_PACKS.ps1','EXP22_6_COLLECT_RESULTS.ps1')) {
    Copy-Item -LiteralPath (Join-Path $kit $tool) -Destination (Join-Path $testDir $tool) -Force
  }

  $launcherLines = @(
    '@echo off',
    'setlocal',
    'cd /d "%~dp0"',
    'echo Starting DarkWolf EXP22.6 Performance and Lifecycle...',
    'WolfSP.exe +set r_dxr 1 +exec darkwolf_exp22_6_production.cfg',
    'endlocal'
  )
  [IO.File]::WriteAllText(
    (Join-Path $release 'RUN_DARKWOLF_EXP22_6_PRODUCTION.bat'),
    (($launcherLines -join "`r`n") + "`r`n"),
    [Text.Encoding]::ASCII
  )

  $sourceDiff = Join-Path $kit 'EXP22_6_SOURCE_DIFF.patch'
  if (-not (Test-Path -LiteralPath $sourceDiff -PathType Leaf)) {
    throw "EXP22.6 source diff is missing: $sourceDiff"
  }
  $sourceDiffSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceDiff).Hash
  $utf8NoBom = [Text.UTF8Encoding]::new($false)
  $readme = @"
DarkWolf Experiment 22.6 - Performance and Lifecycle Release
============================================================

This complete runtime is built from the same validated EXP22.5 production chain.
EXP22.6 adds only the audited performance and lifecycle patch.

Production synchronization:
- r_finish 0
- r_dxrCpuSync 0

Performance changes:
- reflection binding preparation is skipped when reflections are disabled;
- hit-surface descriptors and hit tables are cached when scene bindings are unchanged;
- stale dynamic RT instances are pruned and registries are compacted;
- map clear resets RT instance lifecycle state;
- BJ2 invalid model-frame logging is rate-limited and wrapped safely;
- EXP22_6_PERF telemetry reports FPS, 1% low, CPU/GPU frame time, preparation/table time, instance counts and VRAM.

Start:
  RUN_DARKWOLF_EXP22_6_PRODUCTION.bat

A/B tools are in exp22_6_tests and CFG files are in main/exp22_6_tests.
Original commercial RTCW PK3 files are not included.

WolfSP.exe SHA-256: $exeSha
EXP22.6 source diff SHA-256: $sourceDiffSha
Canonical base: 229cd5d93b4c24ba705c9821a871cccf31b34b96
"@
  [IO.File]::WriteAllText(
    (Join-Path $release 'README_EXP22_6_PERFORMANCE_LIFECYCLE_RU.txt'),
    ($readme.Trim() + "`r`n"),
    $utf8NoBom
  )

  $manifest = @"
DARKWOLF_EXP22_6_PERFORMANCE_LIFECYCLE_RELEASE
Configuration=Release
CanonicalBase=229cd5d93b4c24ba705c9821a871cccf31b34b96
EXP22_4_DonorWorkflowSHA256=DB30552F3B2663A41892CDD434370A58F468F82C1A5229358E14E09BE2425D0A
EXP22_4_PayloadSHA256=2B2A7C867CDA10D6324AC114F0F5F9AEE05D20FAA50341F417F7C87A6330D393
EXP22_6_PatchSHA256=176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170
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
  [IO.File]::WriteAllText(
    (Join-Path $release 'BUILD_MANIFEST.txt'),
    ($manifest.Trim() + "`r`n"),
    $utf8NoBom
  )

  $forbiddenExtensions = @('.pdb','.obj','.lib','.exp','.ilk','.vcxproj','.sln','.patch','.py')
  $allowedPs1 = @('RUN_WITHOUT_4K_PACKS.ps1','EXP22_6_COLLECT_RESULTS.ps1')
  $forbidden = @(
    Get-ChildItem -LiteralPath $release -Recurse -File |
      Where-Object {
        $_.Extension.ToLowerInvariant() -in $forbiddenExtensions -or
        ($_.Extension.ToLowerInvariant() -eq '.ps1' -and $_.Name -notin $allowedPs1)
      }
  )
  if ($forbidden.Count -ne 0) {
    throw "Forbidden non-runtime files found: $($forbidden.FullName -join ', ')"
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
    $utf8NoBom
  )

  $finalFiles = @(Get-ChildItem -LiteralPath $release -Recurse -File | Sort-Object FullName)
  $totalBytes = [int64](($finalFiles | Measure-Object -Property Length -Sum).Sum)
  $totalMiB = [math]::Round($totalBytes / 1MB, 2)
  if ($totalBytes -lt 100MB -or $totalBytes -gt 160MB) {
    throw "Full production runtime size is outside the validated range: $totalMiB MiB"
  }

  $contentsLines = foreach ($file in $finalFiles) {
    $relative = $file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/')
    '{0,12}  {1}' -f $file.Length, $relative
  }
  [IO.File]::WriteAllText(
    (Join-Path $release 'FULL_RELEASE_CONTENTS.txt'),
    ((@("TOTAL_BYTES=$totalBytes", "TOTAL_MIB=$totalMiB", '') + $contentsLines) -join "`r`n") + "`r`n",
    $utf8NoBom
  )

  Write-Host "EXP22_6_FULL_PRODUCTION_PACKAGE=PASS FILES=$($finalFiles.Count) TOTAL_BYTES=$totalBytes TOTAL_MIB=$totalMiB WolfSP_SHA256=$exeSha"
}
finally {
  Pop-Location
}
