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

    # Copy Quality Lab 2 profiles into the packaged main folder.
    foreach ($cfg in @(
        'dxr_v22_ql2_balanced.cfg',
        'dxr_v22_ql2_quality.cfg',
        'dxr_v22_ql2_real_lights.cfg',
        'dxr_v22_ql2_debug_shadowed.cfg',
        'dxr_v22_ql2_debug_physical_visibility.cfg',
        'dxr_v22_ql2_debug_evidence.cfg',
        'dxr_v22_ql2_debug_retained_visibility.cfg',
        'dxr_v22_ql2_debug_support_shadow.cfg',
        'dxr_v22_ql2_dump_lights.cfg',
        'dxr_v22_ql2_ab_refit.cfg'
    )) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required Quality Lab 2 profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_DXR_V22_QL2_BALANCED.bat'                  = 'dxr_v22_ql2_balanced.cfg'
        'RUN_DXR_V22_QL2_QUALITY.bat'                   = 'dxr_v22_ql2_quality.cfg'
        'RUN_DXR_V22_QL2_REAL_LIGHTS.bat'               = 'dxr_v22_ql2_real_lights.cfg'
        'RUN_DXR_V22_QL2_DEBUG_SHADOWED.bat'            = 'dxr_v22_ql2_debug_shadowed.cfg'
        'RUN_DXR_V22_QL2_DEBUG_PHYSICAL_VISIBILITY.bat' = 'dxr_v22_ql2_debug_physical_visibility.cfg'
        'RUN_DXR_V22_QL2_DEBUG_EVIDENCE.bat'            = 'dxr_v22_ql2_debug_evidence.cfg'
        'RUN_DXR_V22_QL2_DEBUG_RETAINED_VISIBILITY.bat' = 'dxr_v22_ql2_debug_retained_visibility.cfg'
        'RUN_DXR_V22_QL2_DEBUG_SUPPORT_SHADOW.bat'      = 'dxr_v22_ql2_debug_support_shadow.cfg'
        'RUN_DXR_V22_QL2_DUMP_LIGHTS.bat'               = 'dxr_v22_ql2_dump_lights.cfg'
        'RUN_DXR_V22_QL2_AB_REFIT.bat'                  = 'dxr_v22_ql2_ab_refit.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR v2.2 Quality Lab 2: $($entry.Value)`r`nWolfSP.exe +set developer 1 +set logfile 2 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec $($entry.Value)`r`n"
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
DarkWolf RTCW DXR Stable Clear v2.2 Quality Lab 2
=================================================

Built from the confirmed stable chain:
  patch 10 -> patch 20 -> patch 30 v2.2 -> patch 40 QL1 -> patch 50 QL2

Start with:
  RUN_DXR_V22_QL2_BALANCED.bat

QL2 fixes two independently proven defects:
1. Valid shadows existed in SHADOWED/VISIBILITY but vanished in BALANCED.
   QL2 retains ray-confirmed local silhouettes through ambient, legacy lightmaps
   and the non-shadowing camera fill without reintroducing white radius circles.
2. The swinging torture cage had a frozen DXR shadow.
   QL2 performs a full BLAS rebuild for changed animated vertices, while rigid
   doors continue to use inexpensive transform updates.

The stable execution path remains unchanged:
  r_dxrAsyncSubmit 0
  r_dxrCpuSync 1
  r_dxrBuildInterval 1
  r_dxrDispatchInterval 1
  r_dxrFallbackCastsShadows 0

Profiles:
  RUN_DXR_V22_QL2_BALANCED.bat
    Primary release-candidate profile, 4 shadow samples.

  RUN_DXR_V22_QL2_QUALITY.bat
    8-sample quality profile. Test only after BALANCED is stable.

  RUN_DXR_V22_QL2_REAL_LIGHTS.bat
    Disables the camera fill for authored-light verification.

  RUN_DXR_V22_QL2_DEBUG_SHADOWED.bat
    Authored direct light after ray shadows.

  RUN_DXR_V22_QL2_DEBUG_PHYSICAL_VISIBILITY.bat
    Pure energy-weighted multi-light visibility.

  RUN_DXR_V22_QL2_DEBUG_EVIDENCE.bat
    Local shadow evidence that preserves grille/character/cage silhouettes.

  RUN_DXR_V22_QL2_DEBUG_RETAINED_VISIBILITY.bat
    Final visibility used by the corrected composite.

  RUN_DXR_V22_QL2_DEBUG_SUPPORT_SHADOW.bat
    Remaining ambient/fill support inside a valid shadow.

  RUN_DXR_V22_QL2_DUMP_LIGHTS.bat
    Normal image plus selected lights and dynamic BLAS counters in the log.

  RUN_DXR_V22_QL2_AB_REFIT.bat
    Diagnostic only. Restores old BLAS refit mode. A frozen cage shadow here,
    but a moving shadow in BALANCED, proves the dynamic BLAS fix.

Expected log marker:
  DXR v2.2 Quality Lab 2:

Important dynamic fields:
  dynFull=1
  dynUpdates=...
  dynRebuilds=...
  dynRefits=0

This package was statically validated, but MSVC/DXC compilation and GPU runtime
behavior still require the GitHub Actions build and the user's hardware test.
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_DXR_V22_QUALITY_LAB2.txt') -Value $readme -Encoding UTF8

    Write-Host 'v2.2 Quality Lab 2 runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
