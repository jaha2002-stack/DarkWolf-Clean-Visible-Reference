[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('GameDlightExp19NativeKeys' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class GameDlightExp19NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("GAME_DYNAMIC_LIGHTS_EXP19_{0}" -f $stamp)
$externalDir = Join-Path $resultDir 'external_png'
New-Item -ItemType Directory -Path $externalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) {
    Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue
}

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Mode=6;  Name='PRODUCTION_REFERENCE' }
    0x76 = [pscustomobject]@{ Key='F7';  Mode=7;  Name='GAME_LIGHTS_OFF' }
    0x77 = [pscustomobject]@{ Key='F8';  Mode=8;  Name='ISOLATED_BASELINE_SHADOWS_ON' }
    0x78 = [pscustomobject]@{ Key='F9';  Mode=9;  Name='ISOLATED_SHADOWS_OFF' }
    0x79 = [pscustomobject]@{ Key='F10'; Mode=10; Name='BALANCED_NO_FALLBACK' }
    0x7A = [pscustomobject]@{ Key='F11'; Mode=11; Name='ENHANCED_NO_FALLBACK' }
    0x7B = [pscustomobject]@{ Key='F12'; Mode=12; Name='PRODUCTION_CANDIDATE' }
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

function Schedule-ModeBurst {
    param([Parameter(Mandatory=$true)]$Mode)
    $now = Get-Date
    # Fast frames catch muzzle flash; later frames show light/shadow recovery.
    $delaysMs = @(180, 320, 480, 650, 850, 1100, 1400, 1800, 2400, 3200, 4300, 5600)
    $frame = 0
    foreach ($delay in $delaysMs) {
        $frame++
        [void]$captureQueue.Add([pscustomobject]@{
            Due = $now.AddMilliseconds($delay)
            Mode = $Mode
            Frame = $frame
        })
    }
    Write-Host ("Scheduled 12-frame burst for {0} {1}. Fire repeatedly now." -f $Mode.Key, $Mode.Name)
}

function Process-CaptureQueue {
    $now = Get-Date
    $dueItems = @($captureQueue | Where-Object { $_.Due -le $now } | Sort-Object Due)
    foreach ($item in $dueItems) {
        $script:captureSequence++
        $time = Get-Date -Format 'HHmmss_fff'
        $name = ('{0:D3}_{1}_{2}_FRAME{3:D2}_{4}.png' -f $script:captureSequence, $item.Mode.Key, $item.Mode.Name, $item.Frame, $time)
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
    '+exec', 'game_dynamic_lights_exp19.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting Experiment 19 on the full Bloom 18.2 production stack.'
Write-Host 'Press a mode key, then fire repeatedly for 4-6 seconds while the automatic burst is captured.'
$started = Get-Date
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([GameDlightExp19NativeKeys]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
        if ($down -and -not $keyWasDown[$vk]) {
            Schedule-ModeBurst -Mode $modeByVk[$vk]
        }
        $keyWasDown[$vk] = $down
    }
    Process-CaptureQueue
    Start-Sleep -Milliseconds 35
    $process.Refresh()
}
$process.WaitForExit()
$exitCode = $process.ExitCode
$ended = Get-Date

$queueDeadline = (Get-Date).AddSeconds(7)
while ($captureQueue.Count -gt 0 -and (Get-Date) -lt $queueDeadline) {
    Process-CaptureQueue
    Start-Sleep -Milliseconds 35
}

if (Test-Path -LiteralPath $consoleLog) {
    Copy-Item -LiteralPath $consoleLog -Destination $resultDir -Force
}
$consoleText = if (Test-Path -LiteralPath $consoleLog) { Get-Content -LiteralPath $consoleLog -Raw } else { '' }
$modeRecords = @([regex]::Matches($consoleText, 'GAME_DLIGHT_EXP19 F(?:6|7|8|9|10|11|12)[^\r\n]*') | ForEach-Object { $_.Value })
$bridgeRecords = @([regex]::Matches($consoleText, 'GAME_DYNAMIC_LIGHTS_EXP19 enabled=\d+[^\r\n]*') | ForEach-Object { $_.Value })
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal|QD3D12 Fatal') | ForEach-Object { $_.Value })
$imageCount = @(Get-ChildItem -LiteralPath $externalDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash

$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No mode echo records found.' }
$bridgeSummary = if ($bridgeRecords.Count -gt 0) { $bridgeRecords -join [Environment]::NewLine } else { 'No GAME_DYNAMIC_LIGHTS_EXP19 diagnostics found. Fire the weapon while r_dxrGameDynamicLightDebug=1.' }
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No D3D12/DXR device-failure markers found.' }

$summary = @"
DarkWolf Game Dynamic Lights Bridge Experiment 19
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
CapturedExternalPNGs=$imageCount
ModeRecordsLogged=$($modeRecords.Count)
BridgeDiagnosticRecords=$($bridgeRecords.Count)

PreservedBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality 14 + Atmospheric Fog 15.1 + Material Specular 16 R3 + HDR Tone Mapping 17 + Bloom 18.2
ExperimentScope=RTCW game-authored point-light bridge only

Modes:
F6=PRODUCTION_REFERENCE, fallback on, game light 1.00x radius 1.00x shadows on
F7=GAME_LIGHTS_OFF, causal control
F8=ISOLATED_BASELINE_SHADOWS_ON, fallback off
F9=ISOLATED_SHADOWS_OFF, fallback off
F10=BALANCED_NO_FALLBACK, strength 1.50 radius 1.10 shadows on
F11=ENHANCED_NO_FALLBACK, strength 2.25 radius 1.20 shadows on
F12=PRODUCTION_CANDIDATE, fallback on, strength 1.50 radius 1.10 shadows on

Logged mode changes:
$modeSummary

Bridge diagnostics:
$bridgeSummary

D3D12 diagnostics:
$gpuSummary

Acceptance checks:
- F7 must remove or strongly reduce the transient light compared with F6/F8.
- F8 must show whether the original game-light bridge is visible without the camera fallback.
- F9 versus F8 isolates shadow-ray contribution without changing light strength/radius.
- F10/F11 must visibly illuminate the nearby wall during muzzle flash or explosion.
- F12 is accepted only if it is visible but does not wash out walls, characters or Bloom.
- Reject persistent light after the flash, camera-tied lighting, new grid/white spots, crashes or severe FPS loss.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'GAME_DYNAMIC_LIGHTS_EXP19_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
