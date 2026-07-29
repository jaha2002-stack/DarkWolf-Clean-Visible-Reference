param(
  [Parameter(Mandatory=$true)][string]$RepositoryRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$compiler = Join-Path $repo 'ci/exp22_6/compile_exp226.ps1'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
  throw "Proven isolated EXP22.6 compiler is missing: $compiler"
}

& $compiler -WorkRoot $work

$required = @(
  'WolfSP.exe',
  'main/cgamex64.dll',
  'main/qagamex64.dll',
  'main/uix64.dll',
  'ci/exp22_6/BUILD_GRAPH_AUDIT.txt',
  'ci/exp22_6/EXP22_6_COMPILE_MANIFEST.txt',
  'ci/exp22_7/EXP22_7_SOURCE_DIFF.patch',
  'ci/exp22_7/PATCH_TRANSPORT_AUDIT.txt'
)
foreach ($relative in $required) {
  $path = Join-Path $work $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "EXP22.7 compile output is missing: $relative"
  }
}

$sourceMarkers = @(
  @('src/opengl/gl_d3d12raylight.cpp','GL_RAYTRACING_EXP227_STATIC_SLOT_LIMIT'),
  @('src/opengl/gl_d3d12raylight.cpp','glRaytracingExp227AllocateHitSlot'),
  @('src/opengl/gl_d3d12raylight.cpp','hitTableCpuShadow'),
  @('src/opengl/gl_d3d12raylight.cpp','exp227PartialTableUpdates'),
  @('src/opengl/gl_d3d12raylight.cpp','(std::max)('),
  @('src/renderer/tr_cmds.cpp','EXP22_7_PERF')
)
foreach ($marker in $sourceMarkers) {
  $path = Join-Path $work $marker[0]
  $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path))
  if (-not $body.Contains($marker[1])) {
    throw "Compiled EXP22.7 source marker missing: $($marker[0]) :: $($marker[1])"
  }
}
$rayBody = [IO.File]::ReadAllText((Resolve-Path -LiteralPath (Join-Path $work 'src/opengl/gl_d3d12raylight.cpp')))
if ($rayBody.Contains('std::max(')) {
  throw 'Compiled EXP22.7 source contains an unprotected std::max call.'
}

$manifest = [System.Collections.Generic.List[string]]::new()
$manifest.Add('DARKWOLF_EXP22_7_COMPILE_MANIFEST')
$manifest.Add('Configuration=Release')
$manifest.Add('Platform=x64')
$manifest.Add('BuildGraph=IsolatedExplicitNoRadiant')
$manifest.Add('EXP22_6_BasePatchSHA256=176969B90B50366E33F22D18AA3636292390A561E5262DDFF994B2B4C4F1E170')
$manifest.Add('EXP22_7_SourcePatchSHA256=04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444')
$manifest.Add('EXP22_7_EffectivePatchSHA256=6495B878E8E35E51080020236AE5075BDA5B0BC4482AE157BF3D6531D632F61E')
$manifest.Add('EXP22_7_MSVCMaxMacroSafe=1')
foreach ($relative in @('WolfSP.exe','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll')) {
  $path = Join-Path $work $relative
  $item = Get-Item -LiteralPath $path
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  $key = $relative.Replace('/','_').Replace('.','_').ToUpperInvariant()
  $manifest.Add("${key}_SHA256=$hash")
  $manifest.Add("${key}_BYTES=$($item.Length)")
}
[IO.File]::WriteAllLines(
  (Join-Path $work 'ci/exp22_7/EXP22_7_COMPILE_MANIFEST.txt'),
  $manifest,
  [Text.UTF8Encoding]::new($false))

Write-Host 'EXP22_7_COMPILE=PASS RELEASE_X64=1 RADIANT_BUILT=0 MSVC_MAX_MACRO_SAFE=1'
