[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'WolfSP.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "WolfSP.exe not found: $exe" }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('MaterialSpecularExp16NativeKeys' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MaterialSpecularExp16NativeKeys
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resultRoot = Join-Path $root 'test_results'
$resultDir = Join-Path $resultRoot ("MATERIAL_SPECULAR_EXP16_{0}" -f $stamp)
$externalDir = Join-Path $resultDir 'external_png'
New-Item -ItemType Directory -Path $externalDir -Force | Out-Null

$consoleLog = Join-Path $root 'main\rtcwconsole.log'
if (Test-Path -LiteralPath $consoleLog) {
    Remove-Item -LiteralPath $consoleLog -Force -ErrorAction SilentlyContinue
}

$modeByVk = @{
    0x75 = [pscustomobject]@{ Key='F6';  Mode=0; Name='LEGACY_BASELINE' }
    0x76 = [pscustomobject]@{ Key='F7';  Mode=1; Name='ROUGHNESS_CHANNEL_ONLY' }
    0x77 = [pscustomobject]@{ Key='F8';  Mode=2; Name='MATERIAL_F0_NO_BRIGHTNESS_METAL_GUESS' }
    0x78 = [pscustomobject]@{ Key='F9';  Mode=3; Name='CHARACTERS_MATTE_ONLY' }
    0x79 = [pscustomobject]@{ Key='F10'; Mode=4; Name='WORLD_MATTE_ONLY' }
    0x7A = [pscustomobject]@{ Key='F11'; Mode=5; Name='BALANCED_MATERIALS' }
    0x7B = [pscustomobject]@{ Key='F12'; Mode=6; Name='STRICT_REALISTIC_MATERIALS' }
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
    '+exec', 'material_specular_exp16.cfg'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.Arguments = ($args -join ' ')

Write-Host 'Starting Material-Aware Specular / Roughness Visual Lab 16.'
Write-Host 'Keep the camera fixed, press F6-F12, and wait for three captures after every key.'
$started = Get-Date
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'WolfSP.exe failed to start.' }

while (-not $process.HasExited) {
    foreach ($vk in @($modeByVk.Keys | Sort-Object)) {
        $down = (([MaterialSpecularExp16NativeKeys]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0)
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
$modeRecords = @([regex]::Matches($consoleText, 'MATERIAL_SPECULAR_EXP16 mode=\d+') | ForEach-Object { $_.Value })
$modeSummary = if ($modeRecords.Count -gt 0) { $modeRecords -join [Environment]::NewLine } else { 'No MATERIAL_SPECULAR_EXP16 mode records found.' }
$imageCount = @(Get-ChildItem -LiteralPath $externalDir -Filter '*.png' -File -ErrorAction SilentlyContinue).Count
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
$gpuFailures = @([regex]::Matches($consoleText, 'DEVICE_REMOVED|DEVICE_HUNG|DXGI_ERROR|glRaytracing Fatal') | ForEach-Object { $_.Value })
$gpuSummary = if ($gpuFailures.Count -gt 0) { $gpuFailures -join [Environment]::NewLine } else { 'No DXR device-failure markers found.' }

$summary = @"
DarkWolf Material-Aware Specular / Roughness Visual Lab 16
Started=$($started.ToString('o'))
Ended=$($ended.ToString('o'))
ExitCode=$exitCode
WolfSP_SHA256=$exeHash
ProductionBase=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality + Atmospheric Fog 15.1
DynamicLightQualityMode=5 fixed for every material mode
AtmosphereMode=1 fixed for every material mode
FallbackLight=1
FallbackLightIntensity=6.0
CapturedExternalPNGs=$imageCount
ModeRecordsLogged=$($modeRecords.Count)

Modes:
F6=LEGACY_BASELINE fixed shininess plus albedo-brightness metal guess
F7=ROUGHNESS_CHANNEL_ONLY per-surface roughness with the old albedo metal guess
F8=MATERIAL_F0_NO_BRIGHTNESS_METAL_GUESS material classification with the old lobe shape
F9=CHARACTERS_MATTE_ONLY material-aware organic response while the world stays legacy
F10=WORLD_MATTE_ONLY material-aware world response while characters stay legacy
F11=BALANCED_MATERIALS full material-aware GGX candidate
F12=STRICT_REALISTIC_MATERIALS stronger suppression of non-metal highlights

Logged mode changes:
$modeSummary

DXR diagnostics:
$gpuSummary

Selection rules:
- Compare from the same camera position and the same light angle.
- Include a bright stone wall, a zombie or character, the first-person weapon, wood and known metal.
- A successful mode removes lacquered stone and plastic characters without making the weapon and true metal completely flat.
- Reject modes that create firefly highlights, darken diffuse lighting, erase all weapon response or make rough walls sparkle.
- Prefer F11 only if it is balanced across several maps; retain F6 as compatibility fallback.
"@
Set-Content -LiteralPath (Join-Path $resultDir 'MATERIAL_SPECULAR_EXP16_SUMMARY.txt') -Value $summary -Encoding UTF8

$zipPath = "$resultDir.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $resultDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Result package: $zipPath"
if ($exitCode -ne 0) { Write-Warning "WolfSP.exe returned exit code $exitCode" }
