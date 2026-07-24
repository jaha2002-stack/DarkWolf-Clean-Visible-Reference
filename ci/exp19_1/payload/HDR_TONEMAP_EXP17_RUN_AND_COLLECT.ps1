[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('HDRToneMapExp17NativeKeys' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HDRToneMapExp17NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("HDR_TONEMAP_EXP17_{0}" -f $stamp)
$externalDir = Join-Path $resultDir 'external_png'
New-Item -ItemType Directory -Path $externalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) {
    Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue
}

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Mode=0; Name='LEGACY_LINEAR_CLAMP' }
    0x76 = [pscustomobject]@{ Key='F7';  Mode=1; Name='EXTENDED_REINHARD' }
    0x77 = [pscustomobject]@{ Key='F8';  Mode=2; Name='ACES_FITTED' }
    0x78 = [pscustomobject]@{ Key='F9';  Mode=3; Name='HABLE_FILMIC' }
    0x79 = [pscustomobject]@{ Key='F10'; Mode=4; Name='NEUTRAL_LUMINANCE' }
    0x7A = [pscustomobject]@{ Key='F11'; Mode=5; Name='BALANCED_HDR_CANDIDATE' }
    0x7B = [pscustomobject]@{ Key='F12'; Mode=6; Name='CINEMATIC_HDR_CANDIDATE' }
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
    '+exec', 'hdr_tonemapping_exp17.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting HDR-Like Linear Lighting / Tone Mapping Visual Lab 17.'
Write-Host 'Keep the camera fixed, press F6-F12, and wait for three captures after every key.'
$started = Get-Date
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([HDRToneMapExp17NativeKeys]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
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
$modeRecords = @([regex]::Matches($consoleText, 'HDR_TONEMAP_EXP17 mode=\d+') | ForEach-Object { $_.Value })
$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No HDR_TONEMAP_EXP17 mode records found.' }
$imageCount = @(Get-ChildItem -LiteralPath $externalDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal') | ForEach-Object { $_.Value })
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No DXR device-failure markers found.' }

$summary = @"
DarkWolf HDR-Like Linear Lighting / Tone Mapping Visual Lab 17
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
ProductionBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality + Atmospheric Fog 15.1 + Material-Aware Specular 16 R3
DynamicLightQualityMode=5 fixed
MaterialSpecularMode=5 fixed
AtmosphereMode=1 fixed
FallbackLight=1
FallbackLightIntensity=6.0
Exposure=1.15
ToneMapWhitePoint=4.0
ToneMapSaturation=1.0
ToneMapContrast=1.0
CapturedExternalPNGs=$imageCount
ModeRecordsLogged=$($modeRecords.Count)

Modes:
F6=LEGACY_LINEAR_CLAMP original exposure multiply with output clamp
F7=EXTENDED_REINHARD soft white-point shoulder
F8=ACES_FITTED stronger filmic highlight roll-off
F9=HABLE_FILMIC wide shoulder and contrast-preserving response
F10=NEUTRAL_LUMINANCE hue-preserving luminance compression
F11=BALANCED_HDR_CANDIDATE ACES-like production candidate
F12=CINEMATIC_HDR_CANDIDATE stronger Hable contrast candidate

Logged mode changes:
$modeSummary

DXR diagnostics:
$gpuSummary

Selection rules:
- Compare from the exact same camera position.
- Include a bright torch or lamp, a white wall highlight, deep shadows, stone and true metal.
- Prefer modes that preserve highlight color and wall detail without turning dark areas gray.
- Reject modes that crush blacks, wash out the scene, oversaturate fire, clip specular to white or make the image visibly flatter.
- F11 is the balanced production candidate; F6 remains the compatibility fallback.
- This experiment is HDR-like linear lighting plus SDR tone mapping, not HDR10 monitor output.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'HDR_TONEMAP_EXP17_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
