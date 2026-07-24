[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
if (-not ('Exp191Native' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Exp191Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("GAME_DYNAMIC_LIGHTS_EXP19_1_{0}" -f $stamp)
$windowDir = Join-Path $resultDir 'window_png'
$internalDir = Join-Path $resultDir 'internal_screenshots'
New-Item -ItemType Directory -Path $windowDir -Force | Out-Null
New-Item -ItemType Directory -Path $internalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) { Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue }
$started = Get-Date

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Name='PRODUCTION_REFERENCE' }
    0x76 = [pscustomobject]@{ Key='F7';  Name='GAME_LIGHTS_OFF' }
    0x77 = [pscustomobject]@{ Key='F8';  Name='PERSISTENT_ONLY' }
    0x78 = [pscustomobject]@{ Key='F9';  Name='TRANSIENT_ONLY_NO_SHADOWS' }
    0x79 = [pscustomobject]@{ Key='F10'; Name='TRANSIENT_LIGHTING_ONLY' }
    0x7A = [pscustomobject]@{ Key='F11'; Name='TRANSIENT_STRONG_NO_SHADOWS' }
    0x7B = [pscustomobject]@{ Key='F12'; Name='ALL_PLUS_PRIORITIZED_TRANSIENT' }
}
$keyState = @{}
foreach ($vk in $modeByVk.Keys) { $keyState[$vk] = $false }
$keyState[0x74] = $false # F5
$currentMode = [pscustomobject]@{ Key='UNSET'; Name='UNSET' }
$captureQueue = New-Object System.Collections.ArrayList
$captureSequence = 0

function Save-GameWindowPng {
    param(
        [Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $Process.Refresh()
    $handle = $Process.MainWindowHandle
    if ($handle -eq [IntPtr]::Zero) { return $false }
    $rect = New-Object Exp191Native+RECT
    if (-not [Exp191Native]::GetWindowRect($handle, [ref]$rect)) { return $false }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 64 -or $height -lt 64) { return $false }
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $true
}

function Schedule-CaptureBurst {
    param([Parameter(Mandatory=$true)]$Mode)
    $now = Get-Date
    # F5 waits four engine frames before +attack. These captures cover pre-shot,
    # muzzle flash, held attack, release and recovery.
    $delaysMs = @(30, 75, 115, 165, 240, 360, 560, 900, 1450)
    $frame = 0
    foreach ($delay in $delaysMs) {
        $frame++
        [void]$captureQueue.Add([pscustomobject]@{
            Due = $now.AddMilliseconds($delay)
            Mode = $Mode
            Frame = $frame
        })
    }
    Write-Host ("Scheduled synchronized burst for {0} {1}." -f $Mode.Key, $Mode.Name)
}

function Process-CaptureQueue {
    param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process)
    $now = Get-Date
    $dueItems = @($captureQueue | Where-Object { $_.Due -le $now } | Sort-Object Due)
    foreach ($item in $dueItems) {
        $script:captureSequence++
        $time = Get-Date -Format 'HHmmss_fff'
        $name = ('{0:D3}_{1}_{2}_FRAME{3:D2}_{4}.png' -f $script:captureSequence, $item.Mode.Key, $item.Mode.Name, $item.Frame, $time)
        $path = Join-Path $windowDir $name
        if (Save-GameWindowPng -Process $Process -Path $path) {
            Write-Host ("Captured {0} frame {1}." -f $item.Mode.Key, $item.Frame)
        } else {
            Write-Warning ("Could not capture game window for {0} frame {1}." -f $item.Mode.Key, $item.Frame)
        }
        [void]$captureQueue.Remove($item)
    }
}

$args = @(
    '+set', 'developer', '1',
    '+set', 'logfile', '2',
    '+set', 'r_dxr', '1',
    '+set', 'r_picmip', '0',
    '+set', 'r_picmip2', '0',
    '+set', 'r_roundImagesDown', '0',
    '+set', 'r_simpleMipMaps', '0',
    '+set', 'r_texturebits', '32',
    '+set', 'r_textureMode', 'GL_LINEAR_MIPMAP_LINEAR',
    '+exec', 'game_dynamic_lights_exp19_1.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting Experiment 19.1 on the preserved Bloom 18.2 stack.'
Write-Host 'Wait 3 seconds, choose F6-F12, then press F5 once for each mode.'
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([Exp191Native]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
        if ($down -and -not $keyState[$vk]) {
            $currentMode = $modeByVk[$vk]
            Write-Host ("Active mode: {0} {1}" -f $currentMode.Key, $currentMode.Name)
        }
        $keyState[$vk] = $down
    }

    $f5Down = (([Exp191Native]::GetAsyncKeyState(0x74) -band 0x8000) -ne 0)
    if ($f5Down -and -not $keyState[0x74]) {
        Schedule-CaptureBurst -Mode $currentMode
    }
    $keyState[0x74] = $f5Down

    Process-CaptureQueue -Process $process
    Start-Sleep -Milliseconds 15
    $process.Refresh()
}
$process.WaitForExit()
$exitCode = $process.ExitCode
$ended = Get-Date

$deadline = (Get-Date).AddSeconds(3)
while ($captureQueue.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Process-CaptureQueue -Process $process
    Start-Sleep -Milliseconds 20
}

if (Test-Path -LiteralPath $consoleLog) { Copy-Item -LiteralPath $consoleLog -Destination $resultDir -Force }

# Collect internal screenshotJPEG output created by the F5 command sequence.
$shotRoots = @(
    (Join-Path $root 'main\screenshots'),
    (Join-Path $root 'screenshots'),
    (Join-Path $root 'main')
) | Select-Object -Unique
$internalCount = 0
foreach ($shotRoot in $shotRoots) {
    if (-not (Test-Path -LiteralPath $shotRoot)) { continue }
    $shots = Get-ChildItem -LiteralPath $shotRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -ge $started.AddSeconds(-2) -and
            $_.Extension.ToLowerInvariant() -in @('.jpg','.jpeg','.png','.tga') -and
            ($_.DirectoryName -match 'screenshots' -or $_.BaseName -match '^(shot|screenshot)')
        }
    foreach ($shot in $shots) {
        $internalCount++
        $destName = ('{0:D3}_{1}' -f $internalCount, $shot.Name)
        Copy-Item -LiteralPath $shot.FullName -Destination (Join-Path $internalDir $destName) -Force
    }
}

$consoleText = if (Test-Path -LiteralPath $consoleLog) { Get-Content -LiteralPath $consoleLog -Raw } else { '' }
$modeRecords = @([regex]::Matches($consoleText, 'GAME_DLIGHT_EXP19_1 F(?:6|7|8|9|10|11|12)[^\r\n]*') | ForEach-Object { $_.Value })
$diagRecords = @([regex]::Matches($consoleText, 'GAME_DYNAMIC_LIGHTS_EXP19_1 filter=\d+[^\r\n]*') | ForEach-Object { $_.Value })
$captureRecords = @([regex]::Matches($consoleText, 'EXP19_1 CAPTURE_SEQUENCE_COMPLETE[^\r\n]*') | ForEach-Object { $_.Value })
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal|QD3D12 Fatal') | ForEach-Object { $_.Value })
$windowCount = @(Get-ChildItem -LiteralPath $windowDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash

$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No mode records found.' }
$diagSummary = if ($diagRecords.Count -gt 0) { $diagRecords -join [Environment]::NewLine } else { 'No Experiment 19.1 diagnostics found.' }
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No D3D12/DXR device-failure markers found.' }

$summary = @"
DarkWolf Game Dynamic Lights Experiment 19.1
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
CapturedWindowPNGs=$windowCount
CapturedInternalScreenshots=$internalCount
ModeRecordsLogged=$($modeRecords.Count)
CaptureSequencesLogged=$($captureRecords.Count)
DiagnosticRecords=$($diagRecords.Count)

PreservedBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality 14 + Fog 15.1 + Materials 16 R3 + Tone Mapping 17 + Bloom 18.2
ExperimentScope=Near-camera newly appearing game dlights, reserved DXR slots and synchronized muzzle capture

Modes:
F6=PRODUCTION_REFERENCE
F7=GAME_LIGHTS_OFF
F8=PERSISTENT_ONLY
F9=TRANSIENT_ONLY_NO_SHADOWS
F10=TRANSIENT_LIGHTING_ONLY
F11=TRANSIENT_STRONG_NO_SHADOWS
F12=ALL_PLUS_PRIORITIZED_TRANSIENT

Logged mode changes:
$modeSummary

Transient diagnostics:
$diagSummary

D3D12 diagnostics:
$gpuSummary

Acceptance checks:
- During F9-F12 firing, diagnostics must show candidates > 0, submittedTransient > 0 and selectedTransient > 0.
- F9/F11 must show a local wall response absent in F7 and different from F8.
- F10 should isolate the transient direct-light signal from legacy/fallback lighting.
- F11 versus F12 tests transient shadow contribution and integration with the full light list.
- Reject a persistent post-shot light, global scene washout, camera-tied light, new artifacts, crash or severe FPS loss.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'GAME_DYNAMIC_LIGHTS_EXP19_1_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
