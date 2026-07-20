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

    foreach ($pattern in @('cgamex64*.dll', 'qagamex64*.dll', 'uix64*.dll')) {
        Get-ChildItem -Path (Join-Path $RepoRoot 'main') -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dist 'main') -Force
            Write-Host "Copied main/$($_.Name)"
        }
    }

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

    # Copy base dependencies from the proven effects-safe chain plus the new cleanup profiles.
    foreach ($cfg in @(
        'dxr_stable_clear_v22.cfg',
        'dxr_v22_fx_l3_specular.cfg',
        'dxr_v22_fx_l4_ao.cfg',
        'dxr_v22_fx_l5_sky.cfg',
        'dxr_v22_fx_l6_indirect.cfg',
        'dxr_v22_cleanup_safe_start.cfg',
        'dxr_v22_cleanup_soft.cfg',
        'dxr_v22_cleanup_balanced.cfg',
        'dxr_v22_cleanup_quality.cfg',
        'dxr_v22_cleanup_maxclean.cfg',
        'dxr_v22_cleanup_no_gi.cfg',
        'dxr_v22_cleanup_no_reflections.cfg',
        'dxr_v22_cleanup_debug_gi.cfg',
        'dxr_v22_cleanup_debug_reflections.cfg'
    )) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required runtime profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_CLEANUP_SAFE_START.bat'        = 'dxr_v22_cleanup_safe_start.cfg'
        'RUN_DXR_V22_CLEANUP_SOFT.bat'              = 'dxr_v22_cleanup_soft.cfg'
        'RUN_DXR_V22_CLEANUP_BALANCED.bat'          = 'dxr_v22_cleanup_balanced.cfg'
        'RUN_DXR_V22_CLEANUP_QUALITY.bat'           = 'dxr_v22_cleanup_quality.cfg'
        'RUN_DXR_V22_CLEANUP_MAXCLEAN.bat'          = 'dxr_v22_cleanup_maxclean.cfg'
        'RUN_DXR_V22_CLEANUP_NO_GI.bat'             = 'dxr_v22_cleanup_no_gi.cfg'
        'RUN_DXR_V22_CLEANUP_NO_REFLECTIONS.bat'    = 'dxr_v22_cleanup_no_reflections.cfg'
        'RUN_DXR_V22_CLEANUP_DEBUG_GI.bat'          = 'dxr_v22_cleanup_debug_gi.cfg'
        'RUN_DXR_V22_CLEANUP_DEBUG_REFLECTIONS.bat' = 'dxr_v22_cleanup_debug_reflections.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Image Cleanup / Quality Polish: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
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
DarkWolf RTCW DXR v2.2 Image Cleanup / Quality Polish Fix
=========================================================

This release builds directly on the proven stable chain:
  patch 10 -> patch 20 -> patch 30 -> patch 70 -> patch 71

Patch 71 focuses only on image cleanup / polish:
  * less structured sampling in AO / sky / contact AO / GI / reflections
  * softer reflection shaping and tighter contribution control
  * cleaner specular response to reduce glitter / crawling highlights
  * conservative runtime profiles for grain / banding / stripe reduction

It does NOT add temporal history, new UAV ping-pong buffers, hybrid BLAS,
or a new D3D12 resource model. Stability remains aligned with the v2.2 safe path.

Recommended first run:
  RUN_DXR_V22_CLEANUP_SAFE_START.bat

Then:
  RUN_DXR_V22_CLEANUP_BALANCED.bat

If you still see grain / stripes:
  RUN_DXR_V22_CLEANUP_MAXCLEAN.bat

For A/B testing:
  RUN_DXR_V22_CLEANUP_NO_GI.bat
  RUN_DXR_V22_CLEANUP_NO_REFLECTIONS.bat

For useful logs, all launchers enable:
  developer 1
  logfile 2

Expected marker:
  Image Cleanup / Quality Polish
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_IMAGE_CLEANUP_QUALITY_POLISH.txt') -Value $readme -Encoding UTF8

    Write-Host 'Image Cleanup / Quality Polish runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
