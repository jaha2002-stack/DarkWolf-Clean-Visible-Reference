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

    # Copy the proven v2.2 base profile plus the effects-only profiles.
    foreach ($cfg in @(
        'dxr_stable_clear_v22.cfg',
        'dxr_v22_fx_l3_specular.cfg',
        'dxr_v22_fx_l4_ao.cfg',
        'dxr_v22_fx_l5_sky.cfg',
        'dxr_v22_fx_l6_indirect.cfg',
        'dxr_v22_fx_all_balanced.cfg',
        'dxr_v22_fx_all_quality.cfg',
        'dxr_v22_fx_all_performance.cfg',
        'dxr_v22_fx_debug_ao.cfg',
        'dxr_v22_fx_debug_contact.cfg',
        'dxr_v22_fx_debug_sky.cfg',
        'dxr_v22_fx_debug_gi.cfg',
        'dxr_v22_fx_debug_reflections.cfg',
        'dxr_v22_fx_debug_specular.cfg',
        'dxr_v22_fx_ab_no_gi.cfg',
        'dxr_v22_fx_ab_no_reflections.cfg'
    )) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required runtime profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_FX_L3_SPECULAR.bat'          = 'dxr_v22_fx_l3_specular.cfg'
        'RUN_DXR_V22_FX_L4_AO.bat'                = 'dxr_v22_fx_l4_ao.cfg'
        'RUN_DXR_V22_FX_L5_SKY.bat'               = 'dxr_v22_fx_l5_sky.cfg'
        'RUN_DXR_V22_FX_L6_INDIRECT.bat'          = 'dxr_v22_fx_l6_indirect.cfg'
        'RUN_DXR_V22_FX_ALL_BALANCED.bat'         = 'dxr_v22_fx_all_balanced.cfg'
        'RUN_DXR_V22_FX_ALL_QUALITY.bat'          = 'dxr_v22_fx_all_quality.cfg'
        'RUN_DXR_V22_FX_ALL_PERFORMANCE.bat'      = 'dxr_v22_fx_all_performance.cfg'
        'RUN_DXR_V22_FX_DEBUG_AO.bat'             = 'dxr_v22_fx_debug_ao.cfg'
        'RUN_DXR_V22_FX_DEBUG_CONTACT.bat'        = 'dxr_v22_fx_debug_contact.cfg'
        'RUN_DXR_V22_FX_DEBUG_SKY.bat'            = 'dxr_v22_fx_debug_sky.cfg'
        'RUN_DXR_V22_FX_DEBUG_GI.bat'             = 'dxr_v22_fx_debug_gi.cfg'
        'RUN_DXR_V22_FX_DEBUG_REFLECTIONS.bat'    = 'dxr_v22_fx_debug_reflections.cfg'
        'RUN_DXR_V22_FX_DEBUG_SPECULAR.bat'       = 'dxr_v22_fx_debug_specular.cfg'
        'RUN_DXR_V22_FX_AB_NO_GI.bat'             = 'dxr_v22_fx_ab_no_gi.cfg'
        'RUN_DXR_V22_FX_AB_NO_REFLECTIONS.bat'    = 'dxr_v22_fx_ab_no_reflections.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Effects Labs 3-6 Safe: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
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
DarkWolf RTCW DXR v2.2 Effects Labs 3-6 Safe
================================================

This release is based directly on the proven Stable Clear v2.2 chain:
  patch 10 -> patch 20 -> patch 30 -> patch 70

It deliberately does not apply Quality Lab 1/2/3/3.1 patches.
It does not create temporal history textures, new UAVs, new descriptor tables,
or a hybrid BLAS path. The D3D12 resource model remains the proven v2.2 model.

Direct cast shadows are disabled in every gameplay profile:
  r_dxrCastShadows 0

Start with:
  RUN_DXR_V22_FX_ALL_BALANCED.bat

Individual stages:
  RUN_DXR_V22_FX_L3_SPECULAR.bat
  RUN_DXR_V22_FX_L4_AO.bat
  RUN_DXR_V22_FX_L5_SKY.bat
  RUN_DXR_V22_FX_L6_INDIRECT.bat

The Lab 6 GI and reflections are conservative visibility-based approximations.
RT reflections show environment visibility/Fresnel response; they do not reflect
the full scene color because RTCW has no modern material/color hit buffer.

For a useful log, all launchers automatically enable:
  developer 1
  logfile 2

Expected marker:
  DXR v2.2 Effects L3-L6 Safe:
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_EFFECTS_LABS3_6_SAFE.txt') -Value $readme -Encoding UTF8

    Write-Host 'Effects Labs 3-6 Safe runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
