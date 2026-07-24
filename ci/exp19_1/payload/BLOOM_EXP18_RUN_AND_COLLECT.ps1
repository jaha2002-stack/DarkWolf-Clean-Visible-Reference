[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('BloomExp18NativeKeys' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BloomExp18NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("BLOOM_EXP18_{0}" -f $stamp)
$externalDir = Join-Path $resultDir 'external_png'
New-Item -ItemType Directory -Path $externalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) {
    Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue
}

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Mode=0; Name='OFF' }
    0x76 = [pscustomobject]@{ Key='F7';  Mode=1; Name='SUBTLE' }
    0x77 = [pscustomobject]@{ Key='F8';  Mode=2; Name='SOFT_TORCH' }
    0x78 = [pscustomobject]@{ Key='F9';  Mode=3; Name='HIGH_THRESHOLD_HIGHLIGHTS' }
    0x79 = [pscustomobject]@{ Key='F10'; Mode=4; Name='WIDE_ATMOSPHERIC' }
    0x7A = [pscustomobject]@{ Key='F11'; Mode=5; Name='BALANCED_CANDIDATE' }
    0x7B = [pscustomobject]@{ Key='F12'; Mode=6; Name='CINEMATIC_STRONG' }
}
$keyWasDown = @{}
foreach ($vk in $modeByVk.Keys) { $keyWasDown[$vk] = $false }
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

function Capture-ModeFrames {
    param([Parameter(Mandatory=$true)]$Mode)
    $delaysMs = @(900, 1400, 1900)
    $frame = 0
    foreach ($delay in $delaysMs) {
        Start-Sleep -Milliseconds $delay
        $frame++
        $script:captureSequence++
        $time = Get-Date -Format 'HHmmss_fff'
        $name = ('{0:D3}_{1}_{2}_FRAME{3}_{4}.png' -f $script:captureSequence, $Mode.Key, $Mode.Name, $frame, $time)
        $path = Join-Path $externalDir $name
        Save-PrimaryScreenPng -Path $path
        Write-Host ("Captured {0} frame {1}: {2}" -f $Mode.Key, $frame, $path)
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
    '+exec', 'bloom_exp18.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting Bloom Visual Lab 18.'
Write-Host 'Keep the camera fixed, press F6-F12, and wait for three captures after every key.'
$started = Get-Date
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([BloomExp18NativeKeys]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
        if ($down -and -not $keyWasDown[$vk]) {
            Capture-ModeFrames -Mode $modeByVk[$vk]
        }
        $keyWasDown[$vk] = $down
    }
    Start-Sleep -Milliseconds 60
    $process.Refresh()
}
$process.WaitForExit()
$exitCode = $process.ExitCode
$ended = Get-Date
Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath $consoleLog) {
    Copy-Item -LiteralPath $consoleLog -Destination $resultDir -Force
}

$consoleText = if (Test-Path -LiteralPath $consoleLog) {
    Get-Content -LiteralPath $consoleLog -Raw
} else {
    ''
}
$modeRecords = @([regex]::Matches($consoleText, 'BLOOM_EXP18 mode=\d+') | ForEach-Object { $_.Value })
$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No BLOOM_EXP18 mode records found.' }
$imageCount = @(Get-ChildItem -LiteralPath $externalDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal') | ForEach-Object { $_.Value })
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No DXR device-failure markers found.' }

$summary = @"
DarkWolf Bloom Visual Lab 18
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
ProductionBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality 14 + Atmospheric Fog 15.1 + Material-Aware Specular 16 R3 + HDR-Like Tone Mapping 17
DynamicLightQualityMode=5 fixed
MaterialSpecularMode=5 fixed
AtmosphereMode=1 fixed
ToneMappingMode=4 fixed
FallbackLight=1
FallbackLightIntensity=6.0
Exposure=1.15
BloomThreshold=1.20
BloomStrength=0.22
BloomRadius=6.0
BloomSoftKnee=0.50
CapturedExternalPNGs=$imageCount
ModeRecordsLogged=$($modeRecords.Count)

Modes:
F6=OFF exact Experiment 17 presentation without Bloom
F7=SUBTLE conservative high-threshold narrow glow
F8=SOFT_TORCH moderate glow for torches and lamps
F9=HIGH_THRESHOLD_HIGHLIGHTS isolates only the brightest fire/specular pixels
F10=WIDE_ATMOSPHERIC wider low-intensity halo
F11=BALANCED_CANDIDATE production-oriented bloom
F12=CINEMATIC_STRONG deliberately obvious stress-test mode

Logged mode changes:
$modeSummary

DXR diagnostics:
$gpuSummary

Selection rules:
- Compare from the exact same camera position.
- Test a torch or lamp against a dark wall, true metal, muzzle flash and an explosion if available.
- Prefer a mode where the source gains a soft halo but nearby stone remains sharp and dark areas stay dark.
- Reject modes that create a white veil, brighten every wall, obscure texture detail, produce square halos or flicker while moving.
- F6 is the no-Bloom compatibility reference. F11 is the initial balanced candidate, not a preselected winner.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'BLOOM_EXP18_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
