param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$compiler = Join-Path $repo 'ci/exp22_6/compile_exp226.ps1'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw "Missing isolated compiler: $compiler" }
& $compiler -WorkRoot $work
if (-not $?) { throw 'EXP22.9 isolated compiler failed.' }

foreach ($relative in @(
  'WolfSP.exe','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll',
  'ci/exp22_6/BUILD_GRAPH_AUDIT.txt','ci/exp22_9/EXP22_9_SOURCE_DIFF.patch'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $work $relative) -PathType Leaf)) { throw "EXP22.9 output missing: $relative" }
}
$checks = @(
  @('src/opengl/gl_d3d12raylight.cpp','exp229BlasUpdateBudget = 24'),
  @('src/opengl/gl_d3d12raylight.cpp','D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD'),
  @('src/opengl/gl_d3d12raylight.cpp','glRaytracingExp229WaitForBlasGeometryWrite'),
  @('src/renderer/tr_backend.cpp','RF_FIRST_PERSON | RF_DEPTHHACK'),
  @('src/renderer/tr_cmds.cpp','EXP22_9_PERF'),
  @('src/opengl/opengl.h','viewWeaponSkipped')
)
foreach ($check in $checks) {
  $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath (Join-Path $work $check[0])))
  if (-not $body.Contains($check[1])) { throw "Compiled EXP22.9 marker missing: $($check[0]) :: $($check[1])" }
}
$graph = [IO.File]::ReadAllText((Resolve-Path -LiteralPath (Join-Path $work 'ci/exp22_6/BUILD_GRAPH_AUDIT.txt')))
foreach ($m in @('BuildProjectReferences=0','BuildInParallel=0','RadiantScheduledForBuild=0')) {
  if (-not $graph.Contains($m)) { throw "Build graph marker missing: $m" }
}
$manifest = [System.Collections.Generic.List[string]]::new()
$manifest.Add('DARKWOLF_EXP22_9_COMPILE_MANIFEST')
$manifest.Add('Configuration=Release')
$manifest.Add('Platform=x64')
$manifest.Add('BuildGraph=IsolatedExplicitNoRadiant')
$manifest.Add('EXP22_9_PatchSHA256=10B24C26D4A061AFD69EA307FCF369A5AFB92650A0B1141321EDF2AD0A092AC4')
$manifest.Add('BLASUpdateBudget=24')
$manifest.Add('ViewWeaponIsolation=RF_FIRST_PERSON|RF_DEPTHHACK')
$manifest.Add('DynamicBLASBuildPreference=PREFER_FAST_BUILD')
$manifest.Add('ResidentBLASRequestsTLASUpdate=1')
$manifest.Add('TelemetryPrefix=EXP22_9_PERF')
foreach ($relative in @('WolfSP.exe','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll')) {
  $path = Join-Path $work $relative
  $item = Get-Item -LiteralPath $path
  $key = $relative.Replace('/','_').Replace('.','_').ToUpperInvariant()
  $manifest.Add("${key}_SHA256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash)")
  $manifest.Add("${key}_BYTES=$($item.Length)")
}
[IO.File]::WriteAllLines((Join-Path $work 'ci/exp22_9/EXP22_9_COMPILE_MANIFEST.txt'),$manifest,[Text.UTF8Encoding]::new($false))
Write-Host 'EXP22_9_COMPILE=PASS RELEASE_X64=1 RADIANT_BUILT=0 BLAS_BUDGET=24'
