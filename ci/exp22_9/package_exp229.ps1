param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$basePackager = Join-Path $repo 'ci/exp22_6/package_exp226.ps1'
if (-not (Test-Path -LiteralPath $basePackager -PathType Leaf)) { throw "Missing proven packager: $basePackager" }
& $basePackager -WorkRoot $work
if (-not $?) { throw 'EXP22.6 base packager failed.' }
$baseRelease = Join-Path $work 'release-darkwolf-exp22_6-performance-lifecycle'
$release = Join-Path $work 'release-darkwolf-exp22_9-dynamic-blas-budget'
if (-not (Test-Path -LiteralPath $baseRelease -PathType Container)) { throw "Base runtime missing: $baseRelease" }
if (Test-Path -LiteralPath $release) { Remove-Item $release -Recurse -Force }
Move-Item $baseRelease $release
$main = Join-Path $release 'main'
$baseCfg = Join-Path $main 'darkwolf_exp22_6_production.cfg'
$cfg = Join-Path $main 'darkwolf_exp22_9_production.cfg'
Copy-Item $baseCfg $cfg -Force
Add-Content -LiteralPath $cfg -Encoding ASCII -Value @(
  '',
  '// EXP22.9 ordered asynchronous AS submission and update budget profile',
  'seta r_dxrAsyncSubmit "1"',
  'seta r_dxrBuildInterval "1"',
  'seta r_dxrDispatchInterval "1"'
)
foreach ($obsolete in @('RUN_DARKWOLF_EXP22_6_PRODUCTION.bat','README_EXP22_6_PERFORMANCE_LIFECYCLE_RU.txt')) {
  $p = Join-Path $release $obsolete; if (Test-Path $p) { Remove-Item $p -Force }
}
$launcher = @('@echo off','setlocal EnableExtensions','cd /d "%~dp0"','WolfSP.exe +set r_dxr 1 +exec darkwolf_exp22_9_production.cfg','endlocal')
[IO.File]::WriteAllText((Join-Path $release 'RUN_DARKWOLF_EXP22_9_PRODUCTION.bat'),($launcher -join "`r`n")+"`r`n",[Text.Encoding]::ASCII)
foreach ($name in @('RUN_EXP22_9_TEST_AND_AUTO_COLLECT.bat','EXP22_9_TEST_AND_AUTO_COLLECT.ps1')) {
  $src = Join-Path $repo "ci/exp22_9/runtime_tools/$name"
  if (-not (Test-Path $src -PathType Leaf)) { throw "Runtime tool missing: $src" }
  Copy-Item $src (Join-Path $release $name) -Force
}
$compileManifest = Join-Path $work 'ci/exp22_9/EXP22_9_COMPILE_MANIFEST.txt'
Copy-Item $compileManifest (Join-Path $release 'EXP22_9_COMPILE_MANIFEST.txt') -Force
$exe = Join-Path $release 'WolfSP.exe'
$exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$readme = @"
DarkWolf EXP22.9 - Dynamic BLAS Update Budgeting and View-Weapon Isolation
===========================================================================

Changes:
- first-person/depth-hack weapon geometry is excluded before DXR mesh/BLAS work;
- resident animated BLAS updates are limited to 24 per build tick;
- first-time BLAS builds remain mandatory and are never deferred;
- dynamic BLAS use PREFER_FAST_BUILD and ALLOW_UPDATE;
- resident BLAS changes request TLAS update rather than a full rebuild;
- ordered async submission uses one queue; mutation/reset points remain fence protected;
- telemetry prefix: EXP22_9_PERF.

Run: RUN_DARKWOLF_EXP22_9_PRODUCTION.bat
Test: RUN_EXP22_9_TEST_AND_AUTO_COLLECT.bat
WolfSP.exe SHA-256: $exeSha
Patch SHA-256: 10B24C26D4A061AFD69EA307FCF369A5AFB92650A0B1141321EDF2AD0A092AC4
"@
[IO.File]::WriteAllText((Join-Path $release 'README_EXP22_9_DYNAMIC_BLAS_BUDGET_RU.txt'),$readme.Trim()+"`r`n",[Text.UTF8Encoding]::new($false))
$manifestPath = Join-Path $release 'BUILD_MANIFEST.txt'
Add-Content -LiteralPath $manifestPath -Encoding UTF8 -Value @(
  '', 'DARKWOLF_EXP22_9_DYNAMIC_BLAS_BUDGET',
  'EXP22_9_PatchSHA256=10B24C26D4A061AFD69EA307FCF369A5AFB92650A0B1141321EDF2AD0A092AC4',
  'EXP22_9_BLASUpdateBudget=24','EXP22_9_ViewWeaponIsolation=1','EXP22_9_AsyncSubmit=1','EXP22_9_TelemetryPrefix=EXP22_9_PERF'
)
foreach ($name in @('SHA256SUMS.txt','FULL_RELEASE_CONTENTS.txt')) { $p=Join-Path $release $name; if(Test-Path $p){Remove-Item $p -Force} }
$files = @(Get-ChildItem $release -Recurse -File | Sort-Object FullName)
$sumLines = foreach($file in $files){$rel=$file.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/');"$((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant())  $rel"}
[IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS.txt'),($sumLines -join "`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
$files = @(Get-ChildItem $release -Recurse -File | Sort-Object FullName)
$total=[int64](($files|Measure-Object Length -Sum).Sum); $mib=[math]::Round($total/1MB,2)
$content=@("TOTAL_BYTES=$total","TOTAL_MIB=$mib",'')+@($files|ForEach-Object{('{0,12}  {1}' -f $_.Length,$_.FullName.Substring($release.Length).TrimStart('\','/').Replace('\','/'))})
[IO.File]::WriteAllText((Join-Path $release 'FULL_RELEASE_CONTENTS.txt'),($content -join "`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
foreach($required in @('WolfSP.exe','RUN_DARKWOLF_EXP22_9_PRODUCTION.bat','RUN_EXP22_9_TEST_AND_AUTO_COLLECT.bat','EXP22_9_TEST_AND_AUTO_COLLECT.ps1','main/darkwolf_exp22_9_production.cfg','EXP22_9_COMPILE_MANIFEST.txt')){if(-not(Test-Path (Join-Path $release $required)-PathType Leaf)){throw "Packaged file missing: $required"}}
if($total -lt 100MB -or $total -gt 165MB){throw "Runtime size outside range: $mib MiB"}
Write-Host "EXP22_9_FULL_PRODUCTION_PACKAGE=PASS FILES=$($files.Count) TOTAL_MIB=$mib WolfSP_SHA256=$exeSha"
