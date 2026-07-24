[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('BloomExp182NativeKeys' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BloomExp182NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("BLOOM_EXP18_2_{0}" -f $stamp)
$externalDir = Join-Path $resultDir 'external_png'
New-Item -ItemType Directory -Path $externalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) {
    Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue
}

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Mode=0; Name='OFF' }
    0x76 = [pscustomobject]@{ Key='F7';  Mode=1; Name='HDR_SOURCE_MASK' }
    0x77 = [pscustomobject]@{ Key='F8';  Mode=2; Name='FINAL_SCENE_SOURCE_MASK' }
    0x78 = [pscustomobject]@{ Key='F9';  Mode=3; Name='COMBINED_BLOOM_ONLY' }
    0x79 = [pscustomobject]@{ Key='F10'; Mode=4; Name='SUBTLE_GAMEPLAY' }
    0x7A = [pscustomobject]@{ Key='F11'; Mode=5; Name='BALANCED_PRODUCTION' }
    0x7B = [pscustomobject]@{ Key='F12'; Mode=6; Name='STRONG_CINEMATIC' }
}
$keyWasDown = @{}
foreach ($vk in $modeByVk.Keys) { $keyWasDown[$vk] = $false }
$captureQueue = New-Object System.Collections.ArrayList
$captureSequence = 0

function Save-PrimaryScreenPng {
    param([Parameter(Mandatory=$true)][string]$Path)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Schedule-ModeFrames {
    param([Parameter(Mandatory=$true)]$Mode)
    $now = Get-Date
    $delaysMs = @(1100, 2500, 3900)
    $frame = 0
    foreach ($delay in $delaysMs) {
        $frame++
        [void]$captureQueue.Add([pscustomobject]@{
            Due = $now.AddMilliseconds($delay)
            Mode = $Mode
            Frame = $frame
        })
    }
    Write-Host ("Scheduled three captures for {0} {1}" -f $Mode.Key, $Mode.Name)
}

function Process-CaptureQueue {
    $now = Get-Date
    $dueItems = @($captureQueue | Where-Object { $_.Due -le $now } | Sort-Object Due)
    foreach ($item in $dueItems) {
        $script:captureSequence++
        $time = Get-Date -Format 'HHmmss_fff'
        $name = ('{0:D3}_{1}_{2}_FRAME{3}_{4}.png' -f $script:captureSequence, $item.Mode.Key, $item.Mode.Name, $item.Frame, $time)
        $path = Join-Path $externalDir $name
        Save-PrimaryScreenPng -Path $path
        Write-Host ("Captured {0} frame {1}: {2}" -f $item.Mode.Key, $item.Frame, $path)
        [void]$captureQueue.Remove($item)
    }
}

$args = @(
    '+set', 'developer', '1',
    '+set', 'logfile', '2',
    '+set', 'r_picmip', '0',
    '+set', 'r_picmip2', '0',
    '+set', 'r_roundImagesDown', '0',
    '+set', 'r_simpleMipMaps', '0',
    '+set', 'r_texturebits', '32',
    '+set', 'r_textureMode', 'GL_LINEAR_MIPMAP_LINEAR',
    '+exec', 'bloom_exp18_2.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting Bloom Visual Lab 18.2 DUAL-SOURCE MULTI-SCALE.'
Write-Host 'F7 HDR mask, F8 final-scene mask and F9 combined Bloom-only are mandatory diagnostics.'
$started = Get-Date
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([BloomExp182NativeKeys]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
        if ($down -and -not $keyWasDown[$vk]) {
            Schedule-ModeFrames -Mode $modeByVk[$vk]
        }
        $keyWasDown[$vk] = $down
    }
    Process-CaptureQueue
    Start-Sleep -Milliseconds 50
    $process.Refresh()
}
$process.WaitForExit()
$exitCode = $process.ExitCode
$ended = Get-Date

# Finish any screenshots already scheduled when the game was closed.
$queueDeadline = (Get-Date).AddSeconds(5)
while ($captureQueue.Count -gt 0 -and (Get-Date) -lt $queueDeadline) {
    Process-CaptureQueue
    Start-Sleep -Milliseconds 50
}

if (Test-Path -LiteralPath $consoleLog) {
    Copy-Item -LiteralPath $consoleLog -Destination $resultDir -Force
}

$consoleText = if (Test-Path -LiteralPath $consoleLog) {
    Get-Content -LiteralPath $consoleLog -Raw
} else {
    ''
}
$modeRecords = @([regex]::Matches($consoleText, 'BLOOM_EXP18_2 mode=\d+[^\r\n]*') | ForEach-Object { $_.Value })
$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No BLOOM_EXP18_2 mode records found.' }
$imageCount = @(Get-ChildItem -LiteralPath $externalDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal|QD3D12 Fatal') | ForEach-Object { $_.Value })
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No D3D12/DXR device-failure markers found.' }

$summary = @"
DarkWolf Bloom Visual Lab 18.2 - DUAL-SOURCE MULTI-SCALE BLOOM
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
ProductionBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality 14 + Atmospheric Fog 15.1 + Material-Aware Specular 16 R3 + HDR-Like Tone Mapping 17
BloomStage=Opaque FP16 HDR source plus final SDR scene after transparent 3D effects, before 2D HUD
BloomResolution=Four-level pyramid at 1/2, 1/4, 1/8 and 1/16 with separable Gaussian blur
ToneMappingMode=4 fixed
MaterialSpecularMode=5 fixed
DynamicLightQualityMode=5 fixed
AtmosphereMode=1 fixed
CapturedExternalPNGs=$imageCount
ModeRecordsLogged=$($modeRecords.Count)

Modes:
F6=OFF compatibility reference
F7=HDR_SOURCE_MASK; opaque FP16 lighting and specular sources
F8=FINAL_SCENE_SOURCE_MASK; fire, lamps, muzzle flashes and explosions after transparency
F9=COMBINED_BLOOM_ONLY; four blurred pyramid levels without the base scene
F10=SUBTLE_GAMEPLAY
F11=BALANCED_PRODUCTION candidate
F12=STRONG_CINEMATIC stress-test

Logged mode changes:
$modeSummary

D3D12 diagnostics:
$gpuSummary

Acceptance rules:
- F7 must show the unclipped opaque HDR lighting/specular source.
- F8 must contain transparent flame/flash pixels and should differ from F7.
- F9 must show a clear multi-scale blurred halo with no normal scene.
- F10-F12 must progressively change halo width and intensity, not merely total screen brightness.
- Reject square halos, full-screen haze, HUD glow, texture blur, flicker or severe FPS loss.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'BLOOM_EXP18_2_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
