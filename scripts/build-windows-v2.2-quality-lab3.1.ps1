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

    # Copy startup-safe Quality Lab 3.1 profiles into the packaged main folder.
    $qualityLab31Profiles = @(
        'dxr_v22_ql31_balanced.cfg',
        'dxr_v22_ql31_quality.cfg',
        'dxr_v22_ql31_performance.cfg',
        'dxr_v22_ql31_real_lights.cfg',
        'dxr_v22_ql31_sharp_ab.cfg',
        'dxr_v22_ql31_blas_refit.cfg',
        'dxr_v22_ql31_blas_full.cfg',
        'dxr_v22_ql31_dump_lights.cfg'
    )
    foreach ($cfg in $qualityLab31Profiles) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required Quality Lab 3.1 profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_QL31_BALANCED.bat'    = 'dxr_v22_ql31_balanced.cfg'
        'RUN_DXR_V22_QL31_QUALITY.bat'     = 'dxr_v22_ql31_quality.cfg'
        'RUN_DXR_V22_QL31_PERFORMANCE.bat' = 'dxr_v22_ql31_performance.cfg'
        'RUN_DXR_V22_QL31_REAL_LIGHTS.bat' = 'dxr_v22_ql31_real_lights.cfg'
        'RUN_DXR_V22_QL31_SHARP_AB.bat'    = 'dxr_v22_ql31_sharp_ab.cfg'
        'RUN_DXR_V22_QL31_BLAS_REFIT.bat'  = 'dxr_v22_ql31_blas_refit.cfg'
        'RUN_DXR_V22_QL31_BLAS_FULL.bat'   = 'dxr_v22_ql31_blas_full.cfg'
        'RUN_DXR_V22_QL31_DUMP_LIGHTS.bat' = 'dxr_v22_ql31_dump_lights.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Quality Lab 3.1 Startup Safe: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
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
DarkWolf RTCW DXR Stable Clear v2.2 Quality Lab 3.1 Startup Safe
================================================================

Built from:
  patch 10 -> 20 -> 30 v2.2 -> 40 QL1 -> 50 QL2 -> 60 QL3 -> 61 QL3.1

Start with:
  RUN_DXR_V22_QL31_BALANCED.bat

Why QL3.1 exists:
  The first QL3 runtime compiled, but its always-bound cross-frame shadow-history
  UAV path caused DXGI_ERROR_DEVICE_REMOVED / removedReason 0x887A0006 even when
  r_dxrShadowTemporal was set to 0. QL3.1 removes that history SRV/UAV path and
  restores the proven QL2 descriptor layout (6 SRV + 1 UAV).

Retained QL3 improvements:
  - configurable point-light source size;
  - improved local-light reservation and ranking;
  - hybrid dynamic BLAS auto/refit/full policy;
  - generic MD3/MDC frame normalization;
  - QL2 multi-light composite and shadow retention;
  - v2.2 white-circle, camera-shadow and stability fixes.

Deliberately disabled in QL3.1:
  - temporal shadow accumulation;
  - edge-aware history filtering;
  - all shadow-history textures and the second UAV.

Stable execution remains:
  r_dxrAsyncSubmit 0
  r_dxrCpuSync 1
  r_dxrBuildInterval 1
  r_dxrDispatchInterval 1
  r_dxrFallbackCastsShadows 0

Profiles:
  RUN_DXR_V22_QL31_BALANCED.bat
    First startup and stability test: 4 rays, 80 lights, moderate source size.

  RUN_DXR_V22_QL31_QUALITY.bat
    After Balanced is stable: 8 rays, 96 lights, slightly softer source size.

  RUN_DXR_V22_QL31_PERFORMANCE.bat
    2 rays, 64 lights.

  RUN_DXR_V22_QL31_REAL_LIGHTS.bat
    Authored map lights only; camera fill disabled.

  RUN_DXR_V22_QL31_SHARP_AB.bat
    Compact point-like source for softness comparison.

  RUN_DXR_V22_QL31_BLAS_REFIT.bat
    Force dynamic BLAS refit.

  RUN_DXR_V22_QL31_BLAS_FULL.bat
    Force QL2-style full dynamic BLAS rebuild.

  RUN_DXR_V22_QL31_DUMP_LIGHTS.bat
    Selected-light and dynamic-BLAS diagnostics in rtcwconsole.log.

Expected log marker:
  DXR v2.2 Quality Lab 3.1 Startup Safe:

Expected safety fields:
  temporal=0
  spatial=0
  async=0
  cpuSync=1
  fallbackShadows=0

This package is statically validated. MSVC/DXC and GPU runtime still require the
GitHub Actions build and hardware test. Temporal filtering will only return in a
separate later experiment after the startup-safe QL3.1 path is confirmed.
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_QUALITY_LAB31.txt') -Value $readme -Encoding UTF8

    Write-Host 'v2.2 Quality Lab 3.1 startup-safe runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
