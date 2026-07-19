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

    # Copy Quality Lab 1 profiles into the packaged main folder.
    foreach ($cfg in @(
        'dxr_v22_ql1_balanced.cfg',
        'dxr_v22_ql1_real_lights.cfg',
        'dxr_v22_ql1_debug_unshadowed.cfg',
        'dxr_v22_ql1_debug_shadowed.cfg',
        'dxr_v22_ql1_debug_visibility.cfg',
        'dxr_v22_ql1_debug_fill.cfg',
        'dxr_v22_ql1_debug_direct_share.cfg',
        'dxr_v22_ql1_dump_lights.cfg',
        'dxr_v22_ql1_ab_uncompressed.cfg'
    )) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required Quality Lab 1 profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_QL1_BALANCED.bat'          = 'dxr_v22_ql1_balanced.cfg'
        'RUN_DXR_V22_QL1_REAL_LIGHTS.bat'        = 'dxr_v22_ql1_real_lights.cfg'
        'RUN_DXR_V22_QL1_DEBUG_UNSHADOWED.bat'   = 'dxr_v22_ql1_debug_unshadowed.cfg'
        'RUN_DXR_V22_QL1_DEBUG_SHADOWED.bat'     = 'dxr_v22_ql1_debug_shadowed.cfg'
        'RUN_DXR_V22_QL1_DEBUG_VISIBILITY.bat'   = 'dxr_v22_ql1_debug_visibility.cfg'
        'RUN_DXR_V22_QL1_DEBUG_FILL.bat'         = 'dxr_v22_ql1_debug_fill.cfg'
        'RUN_DXR_V22_QL1_DEBUG_DIRECT_SHARE.bat' = 'dxr_v22_ql1_debug_direct_share.cfg'
        'RUN_DXR_V22_QL1_DUMP_LIGHTS.bat'        = 'dxr_v22_ql1_dump_lights.cfg'
        'RUN_DXR_V22_QL1_AB_UNCOMPRESSED.bat'     = 'dxr_v22_ql1_ab_uncompressed.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Quality Lab 1: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
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
DarkWolf RTCW DXR Stable Clear v2.2 Quality Lab 1
=================================================

This artifact is built directly from the confirmed stable v2.2 source path:
  patch 10 -> patch 20 Stable Clear v2.1 -> patch 30 v2.2 -> patch 40 QL1
It does not include the experimental v2.3 winner-light composite.

Start with:
  RUN_DXR_V22_QL1_BALANCED.bat

Quality Lab 1 changes only lighting/composite diagnostics:
- all authored direct lights contribute to an energy-weighted shadow ratio;
- the camera fill is excluded from physical shadow visibility;
- broad fallback diffuse is limited and uses a tighter falloff;
- ACES highlight compression reduces clipped white light discs;
- selected point/rect/fill/dropped light counts are printed after current-frame selection.

A/B profiles:
  RUN_DXR_V22_QL1_REAL_LIGHTS.bat
    Disables the camera fill. White circles that remain here are authored lights.

  RUN_DXR_V22_QL1_DEBUG_UNSHADOWED.bat
    Authored direct contribution before shadow rays.

  RUN_DXR_V22_QL1_DEBUG_SHADOWED.bat
    Authored direct contribution after shadow rays.

  RUN_DXR_V22_QL1_DEBUG_VISIBILITY.bat
    Grayscale energy-weighted visibility of all authored lights.

  RUN_DXR_V22_QL1_DEBUG_FILL.bat
    Camera fill contribution only.

  RUN_DXR_V22_QL1_DEBUG_DIRECT_SHARE.bat
    Grayscale weight used to apply shadows to the preserved raster image.

  RUN_DXR_V22_QL1_DUMP_LIGHTS.bat
    Prints the first 12 selected lights with position, radius and intensity.

  RUN_DXR_V22_QL1_AB_UNCOMPRESSED.bat
    Disables only the new highlight shoulder. Use solely to prove whether a
    white circle is clipping or an actual light-volume shape.

Expected log marker:
  DXR v2.2 Quality Lab 1:

This stage does not yet fix missing BLAS updates or invalid animation frames for
characters, corpses and moving cage models. Those belong to Quality Lab 2 and
are intentionally kept out of this composite-only experiment.
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_QUALITY_LAB1.txt') -Value $readme -Encoding UTF8

    Write-Host 'v2.2 Quality Lab 1 runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
