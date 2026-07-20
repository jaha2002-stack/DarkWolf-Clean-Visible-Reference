[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [ValidateSet('x64')]
    [string]$Platform = 'x64',

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-ToolsetToVs2022 {
    Get-ChildItem -Path $RepoRoot -Recurse -Filter *.vcxproj | ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw
        $updated = $content -replace 'v145', 'v143'
        if ($updated -ne $content) {
            Set-Content -LiteralPath $_.FullName -Value $updated -Encoding UTF8
            Write-Host "Converted toolset in $($_.FullName)"
        }
    }
}

function Find-MSBuild {
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $path = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
        if ($path) { return $path }
    }

    throw 'msbuild.exe was not found.'
}

function Invoke-MSBuildProject {
    param(
        [string]$Project,
        [bool]$BuildProjectReferences = $true
    )

    $msbuild = Find-MSBuild
    $args = @(
        $Project,
        "/p:Configuration=$Configuration",
        "/p:Platform=$Platform",
        '/m',
        '/verbosity:minimal'
    )
    if (-not $BuildProjectReferences) {
        $args += '/p:BuildProjectReferences=false'
    }

    Write-Host "Building $Project"
    & $msbuild @args
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed for $Project with exit code $LASTEXITCODE"
    }
}

function Copy-IfExists {
    param([string]$Path, [string]$Destination)
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination $Destination -Force
        Write-Host "Copied $Path"
    }
}

Push-Location $RepoRoot
try {
    Convert-ToolsetToVs2022

    Invoke-MSBuildProject 'src\splines\Splines.vcxproj'
    Invoke-MSBuildProject 'src\botlib\botlib.vcxproj'
    Invoke-MSBuildProject 'src\opengl\opengl.vcxproj'
    Invoke-MSBuildProject 'src\renderer\renderer.vcxproj'
    Invoke-MSBuildProject 'src\cgame\cgame.vcxproj'
    Invoke-MSBuildProject 'src\ui\ui.vcxproj'

    # RTCW game.vcxproj regenerates the game function table during a clean CI build.
    # The first pass can update that table and then stop at link time because an
    # object such as .\Release\g_save.obj has not yet been rebuilt. A second
    # invocation uses the regenerated table and completes the normal build.
    # Only one retry is allowed; a failure on the second pass remains fatal.
    try {
        Invoke-MSBuildProject 'src\game\game.vcxproj'
    }
    catch {
        Write-Warning 'game.vcxproj failed on the first pass. Retrying once after the game function table was regenerated.'
        Invoke-MSBuildProject 'src\game\game.vcxproj'
    }

    Invoke-MSBuildProject 'src\wolf.vcxproj' $false

    $dist = Join-Path $RepoRoot 'dist'
    if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
    New-Item -ItemType Directory -Path $dist | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dist 'main') | Out-Null

    # Main executable. The x64 Release target usually writes to repo root/WolfSP.exe.
    foreach ($candidate in @(
        'WolfSP.exe',
        'WolfSP_d.exe',
        'src\Release\WolfSP.exe',
        'src\Debug\WolfSP_d.exe',
        'src\x64\Release\WolfSP.exe',
        'src\x64\Debug\WolfSP_d.exe'
    )) {
        Copy-IfExists (Join-Path $RepoRoot $candidate) $dist
    }

    # Game VM DLLs produced by the x64 projects.
    foreach ($pattern in @('cgamex64*.dll', 'qagamex64*.dll', 'uix64*.dll')) {
        Get-ChildItem -Path (Join-Path $RepoRoot 'main') -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dist 'main') -Force
            Write-Host "Copied main/$($_.Name)"
        }
    }

    # Optional runtime DLLs if present in the repository.
    foreach ($pattern in @(
        'OpenAL32.dll',
        'dxcompiler.dll',
        'dxil.dll',
        'D3D12Core.dll',
        'd3d12SDKLayers.dll',
        'NvLowLatencyVk.dll',
        'nvngx_*.dll',
        'sl.*.dll'
    )) {
        Get-ChildItem -Path $RepoRoot -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $dist -Force
            Write-Host "Copied $($_.Name)"
        }
    }

    # Copy Quality Lab 3 profiles into the packaged main folder.
    $qualityLab3Profiles = @(
        'dxr_v22_ql3_balanced.cfg',
        'dxr_v22_ql3_quality.cfg',
        'dxr_v22_ql3_performance.cfg',
        'dxr_v22_ql3_real_lights.cfg',
        'dxr_v22_ql3_debug_raw_visibility.cfg',
        'dxr_v22_ql3_debug_filtered_visibility.cfg',
        'dxr_v22_ql3_debug_temporal_confidence.cfg',
        'dxr_v22_ql3_no_temporal.cfg',
        'dxr_v22_ql3_sharp_ab.cfg',
        'dxr_v22_ql3_blas_refit.cfg',
        'dxr_v22_ql3_blas_full.cfg',
        'dxr_v22_ql3_dump_lights.cfg'
    )
    foreach ($cfg in $qualityLab3Profiles) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required Quality Lab 3 profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_QL3_BALANCED.bat'                  = 'dxr_v22_ql3_balanced.cfg'
        'RUN_DXR_V22_QL3_QUALITY.bat'                   = 'dxr_v22_ql3_quality.cfg'
        'RUN_DXR_V22_QL3_PERFORMANCE.bat'               = 'dxr_v22_ql3_performance.cfg'
        'RUN_DXR_V22_QL3_REAL_LIGHTS.bat'               = 'dxr_v22_ql3_real_lights.cfg'
        'RUN_DXR_V22_QL3_DEBUG_RAW_VISIBILITY.bat'      = 'dxr_v22_ql3_debug_raw_visibility.cfg'
        'RUN_DXR_V22_QL3_DEBUG_FILTERED_VISIBILITY.bat' = 'dxr_v22_ql3_debug_filtered_visibility.cfg'
        'RUN_DXR_V22_QL3_DEBUG_TEMPORAL_CONFIDENCE.bat' = 'dxr_v22_ql3_debug_temporal_confidence.cfg'
        'RUN_DXR_V22_QL3_NO_TEMPORAL.bat'               = 'dxr_v22_ql3_no_temporal.cfg'
        'RUN_DXR_V22_QL3_SHARP_AB.bat'                  = 'dxr_v22_ql3_sharp_ab.cfg'
        'RUN_DXR_V22_QL3_BLAS_REFIT.bat'                = 'dxr_v22_ql3_blas_refit.cfg'
        'RUN_DXR_V22_QL3_BLAS_FULL.bat'                 = 'dxr_v22_ql3_blas_full.cfg'
        'RUN_DXR_V22_QL3_DUMP_LIGHTS.bat'               = 'dxr_v22_ql3_dump_lights.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Quality Lab 3: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
        Set-Content -LiteralPath (Join-Path $dist $entry.Key) -Value $launcher -Encoding ASCII
    }

    $requiredRuntimeFiles = @(
        'WolfSP.exe',
        'OpenAL32.dll',
        'dxcompiler.dll',
        'dxil.dll',
        'sl.interposer.dll'
    )
    foreach ($required in $requiredRuntimeFiles) {
        if (!(Test-Path -LiteralPath (Join-Path $dist $required))) {
            throw "Required runtime file was not packaged: $required"
        }
    }

    $readme = @'
DarkWolf RTCW DXR Stable Clear v2.2 Quality Lab 3
=================================================

Built from the confirmed stable chain:
  patch 10 -> 20 -> 30 v2.2 -> 40 QL1 -> 50 QL2 -> 60 QL3

Start with:
  RUN_DXR_V22_QL3_BALANCED.bat

Quality Lab 3 keeps the proven v2.2/QL2 execution and composite fixes, then adds:
  - configurable point-light source size for natural penumbrae;
  - frame-rotated low-discrepancy shadow samples;
  - motion-vector temporal accumulation of shadow visibility;
  - depth/normal edge-aware history filtering;
  - a reserved nearby-authored-light budget plus irradiance ranking;
  - automatic dynamic BLAS refit/rebuild selection;
  - generic MD3/MDC frame normalization for component models.

The stable execution path remains unchanged:
  r_dxrAsyncSubmit 0
  r_dxrCpuSync 1
  r_dxrBuildInterval 1
  r_dxrDispatchInterval 1
  r_dxrFallbackCastsShadows 0

Profiles:
  RUN_DXR_V22_QL3_BALANCED.bat
    Primary release-candidate profile: 4 rays, 80 lights, 3x3 edge-aware history.

  RUN_DXR_V22_QL3_QUALITY.bat
    8 rays, 96 lights, wider source size and 5x5 edge-aware history.

  RUN_DXR_V22_QL3_PERFORMANCE.bat
    2 rays, 64 lights, temporal stabilization retained.

  RUN_DXR_V22_QL3_REAL_LIGHTS.bat
    Authored map lights only; camera fill disabled.

  RUN_DXR_V22_QL3_DEBUG_RAW_VISIBILITY.bat
    Current-frame visibility before temporal filtering.

  RUN_DXR_V22_QL3_DEBUG_FILTERED_VISIBILITY.bat
    Final visibility used by the QL3 composite.

  RUN_DXR_V22_QL3_DEBUG_TEMPORAL_CONFIDENCE.bat
    White means history was accepted; black means current data was used.

  RUN_DXR_V22_QL3_NO_TEMPORAL.bat
    Quality source-size shadows with history disabled for A/B testing.

  RUN_DXR_V22_QL3_SHARP_AB.bat
    Compact near-point source for source-size comparison.

  RUN_DXR_V22_QL3_BLAS_REFIT.bat
    Forces refit for update-capable dynamic BLAS.

  RUN_DXR_V22_QL3_BLAS_FULL.bat
    Forces QL2-style full dynamic BLAS rebuilds.

  RUN_DXR_V22_QL3_DUMP_LIGHTS.bat
    Normal image plus selected-light and BLAS counters in rtcwconsole.log.

Expected log marker:
  DXR v2.2 Quality Lab 3:

Important fields:
  source=scale/min/max
  temporal=enabled/weight
  spatial=radius
  local=reserved selected lights
  blasMode=0 (auto), 1 (refit), 2 (full)
  dynUpdates / dynRebuilds / dynRefits

This package is statically validated. MSVC/DXC compilation and GPU runtime
quality still require the GitHub Actions build and hardware test.
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_QUALITY_LAB3.txt') -Value $readme -Encoding UTF8

    Write-Host 'v2.2 Quality Lab 3 runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
