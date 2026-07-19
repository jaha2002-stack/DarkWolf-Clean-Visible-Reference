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

    # Copy versioned runtime profiles into the packaged main folder.
    foreach ($cfg in @(
        'dxr_clean_v2_balanced.cfg',
        'dxr_clean_v2_quality.cfg',
        'dxr_clean_v2_performance.cfg',
        'dxr_clean_v2_real_lights.cfg',
        'dxr_clean_v2_safe_sync.cfg',
        'dxr_clean_v2_shadow_mask.cfg'
    )) {
        $sourceCfg = Join-Path $RepoRoot (Join-Path 'main' $cfg)
        if (!(Test-Path -LiteralPath $sourceCfg)) {
            throw "Required runtime profile is missing: main/$cfg"
        }
        Copy-Item -LiteralPath $sourceCfg -Destination (Join-Path $dist 'main') -Force
        Write-Host "Copied main/$cfg"
    }

    $launchers = [ordered]@{
        'RUN_RT_CLEAN_V2_BALANCED.bat'    = 'dxr_clean_v2_balanced.cfg'
        'RUN_RT_CLEAN_V2_QUALITY.bat'     = 'dxr_clean_v2_quality.cfg'
        'RUN_RT_CLEAN_V2_PERFORMANCE.bat' = 'dxr_clean_v2_performance.cfg'
        'RUN_RT_CLEAN_V2_REAL_LIGHTS.bat' = 'dxr_clean_v2_real_lights.cfg'
        'RUN_RT_CLEAN_V2_SAFE_SYNC.bat'   = 'dxr_clean_v2_safe_sync.cfg'
        'RUN_RT_CLEAN_V2_SHADOW_MASK.bat' = 'dxr_clean_v2_shadow_mask.cfg'
    }

    foreach ($entry in $launchers.GetEnumerator()) {
        $launcher = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`necho Starting DarkWolf RTCW DXR Clean Stable Visible v2: $($entry.Value)`r`nWolfSP.exe +exec $($entry.Value)`r`n"
        Set-Content -LiteralPath (Join-Path $dist $entry.Key) -Value $launcher -Encoding ASCII
    }

    $readme = @'
DarkWolf RTCW DXR Clean Stable Visible v2
=========================================

This artifact contains runtime files built from:
  clean imported DarkWolf source
  + proven Clean Visible Reference patch 10
  + incremental stability/performance/shadow patch 20

It does NOT contain original Return to Castle Wolfenstein pk3 game data.
Copy the artifact over a separate RTCW/DarkWolf test folder.

Start in this order:

  1. RUN_RT_CLEAN_V2_BALANCED.bat
     Main recommended profile. Preserves the Clean Reference look, limits the
     light/ray cost, enables stronger legacy shadow modulation and moving-door
     geometry caching.

  2. RUN_RT_CLEAN_V2_PERFORMANCE.bat
     Use if Balanced is still too slow. It uses fewer lights/rays and updates
     BLAS/TLAS every second eligible frame.

  3. RUN_RT_CLEAN_V2_QUALITY.bat
     Use only after Balanced is stable. More lights and samples, lower FPS.

  4. RUN_RT_CLEAN_V2_REAL_LIGHTS.bat
     Disables the camera fallback light. Use this to verify shadows from the
     actual map torches and other authored map lights.

  5. RUN_RT_CLEAN_V2_SAFE_SYNC.bat
     Slow diagnostic fallback. Restores explicit CPU/GPU waits if async mode is
     unstable on a particular driver/GPU.

  6. RUN_RT_CLEAN_V2_SHADOW_MASK.bat
     Grayscale diagnostic: white = visible, dark = ray-traced occlusion.

Important new cvars:
  r_dxrAsyncSubmit
  r_dxrCpuSync
  r_dxrBuildInterval
  r_dxrDispatchInterval
  r_dxrMaxLights
  r_dxrShadowSamples
  r_dxrRectShadowSamples
  r_dxrAOSamples
  r_dxrSkySamples
  r_dxrShadowStrength
  r_dxrLegacyShadowStrength
  r_dxrShadowMinVisibility
  r_dxrContactShadows
  r_dxrContactShadowLength
  r_dxrAlphaShadowGeometry
  r_dxrSafeMode
  r_dxrFenceWaitMs

For a useful log, enter separately in the console:
  developer 1
  logfile 2
  r_dxrDebug 1

The log should contain a line beginning with:
  DXR v2:
'@
    Set-Content -LiteralPath (Join-Path $dist 'README_RUN_RT_CLEAN_V2.txt') -Value $readme -Encoding UTF8

    Write-Host 'Clean Stable Visible v2 runtime package prepared in dist:'
    Get-ChildItem -Path $dist -Recurse | ForEach-Object { Write-Host $_.FullName }
}
finally {
    Pop-Location
}
