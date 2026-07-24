param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [string]$WorkDir = 'work'
)

$ErrorActionPreference = 'Stop'

$BaseCommit = '229cd5d93b4c24ba705c9821a871cccf31b34b96'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WorkPath = if ([IO.Path]::IsPathRooted($WorkDir)) {
    [IO.Path]::GetFullPath($WorkDir)
} else {
    [IO.Path]::GetFullPath((Join-Path $RepoRoot $WorkDir))
}
$PayloadRoot = Join-Path $PSScriptRoot 'payload'
$PayloadManifest = Join-Path $PSScriptRoot 'payload-sha256.txt'

function Write-Stage([string]$Name) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host $Name
    Write-Host ('=' * 78)
}

Set-Location $RepoRoot

Write-Stage 'Validate canonical checkout and external payload files'
if (-not (Test-Path -LiteralPath $WorkPath -PathType Container)) {
    throw "Canonical checkout directory was not found: $WorkPath"
}

$actualCommit = (& git -C $WorkPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $BaseCommit) {
    throw "Unexpected canonical checkout. Expected $BaseCommit, got $actualCommit"
}

if (-not (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
    throw "Payload directory was not found: $PayloadRoot"
}
if (-not (Test-Path -LiteralPath $PayloadManifest -PathType Leaf)) {
    throw "Payload hash manifest was not found: $PayloadManifest"
}

$manifestLines = Get-Content -LiteralPath $PayloadManifest | Where-Object { $_.Trim() }
foreach ($line in $manifestLines) {
    if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
        throw "Invalid payload manifest line: $line"
    }
    $expected = $Matches[1].ToUpperInvariant()
    $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $source = Join-Path $PayloadRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Payload file is missing: $relative"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    if ($actual -ne $expected) {
        # Git for Windows may convert repository text files from LF to CRLF.
        # The manifest stores hashes of the canonical LF payload. Normalize only
        # CRLF byte pairs and accept the file only when the normalized hash matches.
        $rawBytes = [IO.File]::ReadAllBytes($source)
        $normalizedStream = [IO.MemoryStream]::new()
        try {
            for ($i = 0; $i -lt $rawBytes.Length; $i++) {
                if (
                    $rawBytes[$i] -eq 13 -and
                    ($i + 1) -lt $rawBytes.Length -and
                    $rawBytes[$i + 1] -eq 10
                ) {
                    $normalizedStream.WriteByte(10)
                    $i++
                }
                else {
                    $normalizedStream.WriteByte($rawBytes[$i])
                }
            }
            $normalizedBytes = $normalizedStream.ToArray()
        }
        finally {
            $normalizedStream.Dispose()
        }

        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $normalizedHash = ([BitConverter]::ToString(
                $sha256.ComputeHash($normalizedBytes)
            )).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }

        if ($normalizedHash -eq $expected) {
            [IO.File]::WriteAllBytes($source, $normalizedBytes)
            Write-Host "Normalized CRLF to LF: $relative"
            $actual = $normalizedHash
        }
        else {
            throw "Payload hash mismatch: $relative (expected=$expected raw=$actual normalized=$normalizedHash)"
        }
    }
}
Write-Host "Verified $($manifestLines.Count) external payload files."

Write-Stage 'Copy external payload files into canonical checkout'
Get-ChildItem -LiteralPath $PayloadRoot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $WorkPath -Recurse -Force
}

Push-Location $WorkPath
try {

    Write-Stage 'Validate Bloom 18.2 collector PowerShell syntax'
    $ErrorActionPreference = 'Stop'
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path (Get-Location) 'BLOOM_EXP18_2_RUN_AND_COLLECT.ps1'),
      [ref]$tokens,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
      $parseErrors | ForEach-Object { Write-Error $_.Message }
      throw "BLOOM_EXP18_2_RUN_AND_COLLECT.ps1 contains $($parseErrors.Count) PowerShell parse error(s)."
    }
    Write-Host 'Bloom 18.2 collector PowerShell syntax: PASSED'

    Write-Stage 'Apply Stable Clear v2.2 chain'
    $ErrorActionPreference = 'Stop'
    ./scripts/apply-dxr-clean-reference-rebase.ps1
    ./scripts/apply-dxr-stable-clear-v2.1.ps1
    ./scripts/apply-dxr-stable-clear-v2.2.ps1

    Write-Stage 'Apply approved production patches through Fog 15.1'
    $ErrorActionPreference = 'Stop'
    $patches = @(
      'patches/200-d3d12-graphics-artifact-fix-v1-production.patch',
      'patches/220-d3d12-dynamic-light-quality-exp14.patch',
      'patches/230-d3d12-atmospheric-fog-exp15.patch',
      'patches/231-d3d12-atmospheric-fog-refinement-15_1.patch'
    )
    foreach ($patch in $patches) {
      Write-Host "Applying $patch"
      git apply --check $patch
      if ($LASTEXITCODE -ne 0) { throw "Patch does not apply: $patch" }
      git apply $patch
      if ($LASTEXITCODE -ne 0) { throw "Patch application failed: $patch" }
      git diff --check
      if ($LASTEXITCODE -ne 0) { throw "git diff --check failed after $patch" }
    }

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    foreach ($marker in @(
      'DynamicLightPointFalloff',
      'ApplyDXRAtmosphere',
      'gAtmosphereControls',
      'ComputeWorldLowFog',
      'extraMipLevels',
      'polygonOffsetFill'
    )) {
      if (-not ($ray.Contains($marker) -or $shim.Contains($marker))) {
        throw "Approved production marker missing: $marker"
      }
    }

    Write-Stage 'Apply Material-Aware Specular Roughness Experiment 16'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/240-d3d12-material-aware-specular-roughness-exp16.patch'
    $expected = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/gl_d3d12shim.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_backend.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h'
    ) | Sort-Object
    $headers = @(Select-String -LiteralPath $patch -Pattern '^diff --git a/(.+) b/(.+)$')
    $actual = @($headers | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object)
    if ($headers.Count -ne 6 -or (($actual -join '|') -ne ($expected -join '|'))) {
      throw "Experiment 16 patch scope mismatch: $($actual -join ', ')"
    }

    git apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 16 patch does not apply.' }
    git apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 16 patch application failed.' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 16 git diff --check failed.' }
    git apply --check -R $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 16 reverse-check failed.' }

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    $backend = Get-Content -LiteralPath 'src/renderer/tr_backend.cpp' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    $local = Get-Content -LiteralPath 'src/renderer/tr_local.h' -Raw
    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    foreach ($marker in @(
      'gMaterialSpecularMode',
      'ComputeMaterialGGXSpecular',
      'ComputeRoughnessOnlyGGXSpecular',
      'DXR_MATERIAL_STONE',
      'DXR_MATERIAL_ORGANIC',
      'RB_DXRSelectSurfaceMaterial',
      'MATERIAL_SPECULAR_EXP16 mode=',
      'r_dxrMaterialSpecularMode',
      'glRaytracingLightingSetMaterialSpecularMode',
      'material id into the fractional part',
      'static_assert(sizeof(glRaytracingLightingConstants_t) == 336'
    )) {
      if (-not ($ray.Contains($marker) -or $shim.Contains($marker) -or $backend.Contains($marker) -or $init.Contains($marker) -or $local.Contains($marker) -or $header.Contains($marker))) {
        throw "Missing Experiment 16 marker: $marker"
      }
    }
    foreach ($forbidden in @(
      'TEMPORAL_EXP13',
      'SHADOW_SELF_INTERSECTION_EXP10',
      'DYNAMIC_LIGHT_PROJECTION_EXP11',
      'DXR_DIRECT_EXP12'
    )) {
      if ($ray.Contains($forbidden) -or $backend.Contains($forbidden)) {
        throw "Rejected experiment leaked into build: $forbidden"
      }
    }

    Write-Stage 'Apply MSVC-safe HLSL runtime join fix R2'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/241-d3d12-msvc-hlsl-runtime-join-exp16-r2.patch'
    $headers = @(Select-String -LiteralPath $patch -Pattern '^\+\+\+ b/(.+)$')
    $targets = @($headers | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
    if ($targets.Count -ne 1 -or $targets[0] -ne 'src/opengl/gl_d3d12raylight.cpp') {
      throw "R2 patch scope mismatch: $($targets -join ', ')"
    }

    git apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'R2 HLSL runtime-join patch does not apply.' }
    git apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'R2 HLSL runtime-join patch application failed.' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'R2 git diff --check failed.' }
    git apply --check -R $patch
    if ($LASTEXITCODE -ne 0) { throw 'R2 reverse-check failed.' }

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    foreach ($marker in @(
      '#include <string>',
      'g_glRaytracingLightingHlslPart0',
      'g_glRaytracingLightingHlslPart5',
      'glRaytracingLightingBuildHlsl',
      'hlslSource.c_str()'
    )) {
      if (-not $ray.Contains($marker)) { throw "Missing R2 marker: $marker" }
    }
    if ($ray.Contains('static const char* g_glRaytracingLightingHlsl =')) {
      throw 'Compile-time concatenated DXR HLSL string is still present.'
    }

    Write-Stage 'Apply renderer material API declarations fix R3'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/242-d3d12-renderer-material-api-declarations-exp16-r3.patch'
    $headers = @(Select-String -LiteralPath $patch -Pattern '^\+\+\+ b/(.+)$')
    $targets = @($headers | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
    if ($targets.Count -ne 1 -or $targets[0] -ne 'src/opengl/opengl.h') {
      throw "R3 patch scope mismatch: $($targets -join ', ')"
    }

    git apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'R3 renderer API declaration patch does not apply.' }
    git apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'R3 renderer API declaration patch application failed.' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'R3 git diff --check failed.' }
    git apply --check -R $patch
    if ($LASTEXITCODE -ne 0) { throw 'R3 reverse-check failed.' }

    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    foreach ($declaration in @(
      'void APIENTRY glSurfaceRoughnessf(GLfloat roughness);',
      'void APIENTRY glMaterialTypef(GLfloat materialType);'
    )) {
      if (-not $header.Contains($declaration)) {
        throw "Missing renderer-visible declaration: $declaration"
      }
    }
    foreach ($definition in @(
      'void APIENTRY glSurfaceRoughnessf(GLfloat roughness)',
      'void APIENTRY glMaterialTypef(GLfloat materialType)'
    )) {
      if (-not $shim.Contains($definition)) {
        throw "Missing D3D12 shim definition: $definition"
      }
    }

    Write-Stage 'Apply HDR-Like Lighting Tone Mapping Experiment 17'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/250-d3d12-hdr-like-tonemapping-exp17.patch'
    $expected = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_backend.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h'
    ) | Sort-Object
    $headers = @(Select-String -LiteralPath $patch -Pattern '^diff --git a/(.+) b/(.+)$')
    $actual = @($headers | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object)
    if ($headers.Count -ne 5 -or (($actual -join '|') -ne ($expected -join '|'))) {
      throw "Experiment 17 patch scope mismatch: $($actual -join ', ')"
    }

    git apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 17 patch does not apply.' }
    git apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 17 patch application failed.' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 17 git diff --check failed.' }
    git apply --check -R $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 17 reverse-check failed.' }

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $backend = Get-Content -LiteralPath 'src/renderer/tr_backend.cpp' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    $local = Get-Content -LiteralPath 'src/renderer/tr_local.h' -Raw
    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    foreach ($marker in @(
      'gToneMappingMode',
      'ApplyHDRLikeToneMapping',
      'ToneMapACESFitted',
      'ToneMapHable',
      'HDR_TONEMAP_EXP17 mode=',
      'r_dxrToneMappingMode',
      'r_dxrToneMapWhitePoint',
      'r_dxrToneMapSaturation',
      'r_dxrToneMapContrast',
      'glRaytracingLightingSetToneMappingOptions',
      'static_assert(sizeof(glRaytracingLightingConstants_t) == 352',
      'g_glRaytracingLightingHlslPart6'
    )) {
      if (-not ($ray.Contains($marker) -or $backend.Contains($marker) -or $init.Contains($marker) -or $local.Contains($marker) -or $header.Contains($marker))) {
        throw "Missing Experiment 17 marker: $marker"
      }
    }

    Write-Stage 'Validate embedded DXR HLSL with native x64 DXC'
    $ErrorActionPreference = 'Stop'
    $source = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $pattern = 'static const char g_glRaytracingLightingHlslPart(?<index>\d+)\[\] = R"\((?<body>[\s\S]*?)\)";'
    $matches = [regex]::Matches($source, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matches.Count -ne 7) {
      throw "Expected exactly seven independent DXR HLSL arrays, found $($matches.Count)."
    }

    $parts = @($matches | ForEach-Object {
      [pscustomobject]@{
        Index = [int]$_.Groups['index'].Value
        Body = $_.Groups['body'].Value
      }
    } | Sort-Object Index)

    for ($i = 0; $i -lt $parts.Count; $i++) {
      if ($parts[$i].Index -ne $i) {
        throw "DXR HLSL part numbering is not contiguous at position $i."
      }
    }

    $segmentLengths = @($parts | ForEach-Object { $_.Body.Length })
    $maxSegmentLength = ($segmentLengths | Measure-Object -Maximum).Maximum
    Write-Host "Independent DXR HLSL array lengths: $($segmentLengths -join ', '); maximum=$maxSegmentLength"
    if ($maxSegmentLength -gt 15000) {
      throw "Independent DXR HLSL array is too large for MSVC: $maxSegmentLength characters."
    }

    $shaderSource = [string]::Concat(@($parts | ForEach-Object { $_.Body }))
    if ($shaderSource.Length -lt 40000) {
      throw "Reconstructed DXR HLSL is unexpectedly short: $($shaderSource.Length) characters."
    }
    foreach ($marker in @(
      '[shader("raygeneration")]',
      '[shader("miss")]',
      '[shader("closesthit")]',
      'gDynamicLightQualityMode',
      'gAtmosphereMode',
      'gMaterialSpecularMode',
      'ComputeLegacySpecular',
      'ComputeMaterialGGXSpecular',
      'MaterialSpecularScale',
      'ApplyDXRAtmosphere',
      'gToneMappingMode',
      'ApplyHDRLikeToneMapping',
      'ToneMapACESFitted',
      'ToneMapHable'
    )) {
      if (-not $shaderSource.Contains($marker)) { throw "Missing DXR HLSL marker: $marker" }
    }
    $hlsl = Join-Path $env:RUNNER_TEMP 'hdr-tonemap-exp17.hlsl'
    [IO.File]::WriteAllText($hlsl, $shaderSource, [Text.UTF8Encoding]::new($false))
    Write-Host "Extracted DXR HLSL: $($shaderSource.Length) characters from $($parts.Count) raw-string arrays."

    $searchRoots = @(
      "$env:ProgramFiles\Windows Kits\10\bin",
      "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $dxc = $null
    $x64PathSegment = [IO.Path]::DirectorySeparatorChar + 'x64' + [IO.Path]::DirectorySeparatorChar
    foreach ($root in $searchRoots) {
      $candidate = Get-ChildItem -LiteralPath $root -Filter dxc.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.IndexOf($x64PathSegment, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) { $dxc = $candidate.FullName; break }
    }
    if (-not $dxc) {
      Write-Warning 'Native x64 dxc.exe was not found; MSBuild remains the final shader check.'
      exit 0
    }

    Write-Host "Using native x64 DXC: $dxc"
    $out = Join-Path $env:RUNNER_TEMP 'hdr-tonemap-exp17.dxil'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $dxc
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = "-T lib_6_3 -Fo `"$out`" `"$hlsl`""
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw 'DXC failed to start.' }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }
    if ($proc.ExitCode -ne 0) { throw "DXC failed with exit code $($proc.ExitCode)." }
    if (-not (Test-Path -LiteralPath $out)) { throw 'DXC did not produce the DXIL library.' }

    Write-Stage 'Apply Bloom Visual Lab 18'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/260-d3d12-bloom-visual-lab-exp18.patch'
    $expected = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_backend.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h'
    )
    $actual = @(git apply --numstat $patch | ForEach-Object { ($_ -split "`t")[-1] } | Sort-Object -Unique)
    $expectedSorted = @($expected | Sort-Object -Unique)
    if (($actual -join "`n") -ne ($expectedSorted -join "`n")) {
      throw "Unexpected Experiment 18 patch scope.`nExpected:`n$($expectedSorted -join "`n")`nActual:`n$($actual -join "`n")"
    }
    git apply --check $patch
    git apply $patch
    git diff --check
    git apply --check --reverse $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 18 reverse-check failed.' }

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $backend = Get-Content -LiteralPath 'src/renderer/tr_backend.cpp' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    $local = Get-Content -LiteralPath 'src/renderer/tr_local.h' -Raw
    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    foreach ($marker in @(
      'gBloomMode',
      'g_glRaytracingBloomPostHlsl',
      'BloomCS',
      'glRaytracingLightingEnsureBloomHdrTexture',
      'CreateComputePipelineState',
      'DXGI_FORMAT_R16G16B16A16_FLOAT',
      'r_dxrBloomMode',
      'r_dxrBloomThreshold',
      'r_dxrBloomStrength',
      'r_dxrBloomRadius',
      'r_dxrBloomSoftKnee',
      'BLOOM_EXP18 mode=',
      'static_assert(sizeof(glRaytracingLightingConstants_t) == 384'
    )) {
      if (-not ($ray.Contains($marker) -or $backend.Contains($marker) -or $init.Contains($marker) -or $local.Contains($marker) -or $header.Contains($marker))) {
        throw "Missing Experiment 18 marker: $marker"
      }
    }
    if (-not $ray.Contains('hd.NumDescriptors = 9;')) {
      throw 'Bloom descriptor heap was not expanded to nine descriptors.'
    }

    $postMatch = [regex]::Match($ray, 'static const char g_glRaytracingBloomPostHlsl\[\] = R"\((?<body>[\s\S]*?)\)";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $postMatch.Success) { throw 'Bloom post HLSL raw string not found.' }
    $postBody = $postMatch.Groups['body'].Value
    Write-Host "Bloom post HLSL length: $($postBody.Length) characters"
    if ($postBody.Length -lt 5000 -or $postBody.Length -gt 15000) {
      throw "Bloom post HLSL length is outside the validated MSVC-safe range: $($postBody.Length)."
    }
    foreach ($marker in @('RWTexture2D<float4> gFinalOut', 'Texture2D<float4>   gHdrScene', '[numthreads(8, 8, 1)]', 'void BloomCS', 'ApplyHDRLikeToneMapping')) {
      if (-not $postBody.Contains($marker)) { throw "Missing bloom compute HLSL marker: $marker" }
    }

    Write-Stage 'Validate Bloom compute HLSL with native x64 DXC'
    $ErrorActionPreference = 'Stop'
    $source = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $match = [regex]::Match($source, 'static const char g_glRaytracingBloomPostHlsl\[\] = R"\((?<body>[\s\S]*?)\)";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'Bloom compute HLSL source was not found.' }
    $shaderSource = $match.Groups['body'].Value
    $hlsl = Join-Path $env:RUNNER_TEMP 'bloom-exp18.hlsl'
    [IO.File]::WriteAllText($hlsl, $shaderSource, [Text.UTF8Encoding]::new($false))

    $searchRoots = @(
      "$env:ProgramFiles\Windows Kits\10\bin",
      "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $dxc = $null
    $x64PathSegment = [IO.Path]::DirectorySeparatorChar + 'x64' + [IO.Path]::DirectorySeparatorChar
    foreach ($root in $searchRoots) {
      $candidate = Get-ChildItem -LiteralPath $root -Filter dxc.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.IndexOf($x64PathSegment, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) { $dxc = $candidate.FullName; break }
    }
    if (-not $dxc) {
      Write-Warning 'Native x64 dxc.exe was not found; MSBuild remains the final bloom shader check.'
      exit 0
    }

    Write-Host "Using native x64 DXC: $dxc"
    $out = Join-Path $env:RUNNER_TEMP 'bloom-exp18.dxil'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $dxc
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = "-T cs_6_0 -E BloomCS -Fo `"$out`" `"$hlsl`""
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw 'Bloom DXC failed to start.' }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }
    if ($proc.ExitCode -ne 0) { throw "Bloom DXC failed with exit code $($proc.ExitCode)." }
    if (-not (Test-Path -LiteralPath $out)) { throw 'Bloom DXC did not produce the compute DXIL.' }

    Write-Stage 'Apply Bloom Visual Lab 18.1 final-scene patch'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/261-d3d12-final-scene-bloom-exp18_1.patch'
    $expected = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/gl_d3d12shim.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_backend.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h'
    ) | Sort-Object
    $actual = @(git apply --numstat $patch | ForEach-Object { ($_ -split "`t")[-1] } | Sort-Object -Unique)
    if (($actual -join "`n") -ne ($expected -join "`n")) {
      throw "Unexpected Experiment 18.1 patch scope.`nExpected:`n$($expected -join "`n")`nActual:`n$($actual -join "`n")"
    }
    git apply --check $patch
    git apply $patch
    git diff --check
    git apply --check --reverse $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 18.1 reverse-check failed.' }

    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $backend = Get-Content -LiteralPath 'src/renderer/tr_backend.cpp' -Raw
    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    foreach ($marker in @(
      'kQD3D12FinalBloomHLSL',
      'PSBright',
      'PSBlur',
      'finalBloomSceneCopy',
      'finalBloomBright',
      'finalBloomBlurA',
      'finalBloomBlurB',
      'glFinalSceneBloomSetOptions',
      'glFinalSceneBloomApply',
      'BLOOM_EXP18_1 mode=',
      'stage=FINAL_SCENE',
      'QD3D12_FRAME_NATIVE_POST_UPSCALE',
      'r_dxrBloomThreshold", "0.72"'
    )) {
      if (-not ($shim.Contains($marker) -or $ray.Contains($marker) -or $backend.Contains($marker) -or $header.Contains($marker) -or (Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw).Contains($marker))) {
        throw "Missing Experiment 18.1 marker: $marker"
      }
    }
    if ($ray.Contains('else if (gBloomMode == 0u)')) {
      throw 'Old conditional tone-map path is still active.'
    }
    if (([regex]::Matches($ray, 'const bool useBloom = false;')).Count -ne 2) {
      throw 'Old pre-transparent Bloom path was not disabled in both locations.'
    }
    $rb = [regex]::Match($backend, 'void\s+RB_SetGL2D\s*\(\s*void\s*\)\s*\{(?<body>[\s\S]*?)backEnd\.projection2D\s*=\s*qtrue;', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $rb.Success -or -not $rb.Groups['body'].Value.Contains('glFinalSceneBloomApply')) {
      throw 'Final Bloom is not called before the first 2D projection.'
    }
    $hlslMatch = [regex]::Match($shim, 'static const char\* kQD3D12FinalBloomHLSL = R"HLSL\((?<body>[\s\S]*?)\)HLSL";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $hlslMatch.Success) { throw 'Final Bloom HLSL was not found.' }
    $hlslBody = $hlslMatch.Groups['body'].Value
    Write-Host "Final Bloom HLSL length: $($hlslBody.Length) characters"
    if ($hlslBody.Length -lt 1500 -or $hlslBody.Length -gt 8000) {
      throw "Final Bloom HLSL size is outside the validated range: $($hlslBody.Length)."
    }
    foreach ($marker in @('Texture2D<float4> gInput', 'float3 ExtractBloom', 'float4 PSBright', 'float4 PSBlur')) {
      if (-not $hlslBody.Contains($marker)) { throw "Missing final Bloom HLSL marker: $marker" }
    }

    Write-Stage 'Validate Bloom 18.1 pixel shaders with native x64 DXC'
    $ErrorActionPreference = 'Stop'
    $source = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    $match = [regex]::Match($source, 'static const char\* kQD3D12FinalBloomHLSL = R"HLSL\((?<body>[\s\S]*?)\)HLSL";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'Final Bloom HLSL source was not found.' }
    $hlsl = Join-Path $env:RUNNER_TEMP 'bloom-exp18_1.hlsl'
    [IO.File]::WriteAllText($hlsl, $match.Groups['body'].Value, [Text.UTF8Encoding]::new($false))

    $searchRoots = @(
      "$env:ProgramFiles\Windows Kits\10\bin",
      "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $dxc = $null
    $x64PathSegment = [IO.Path]::DirectorySeparatorChar + 'x64' + [IO.Path]::DirectorySeparatorChar
    foreach ($root in $searchRoots) {
      $candidate = Get-ChildItem -LiteralPath $root -Filter dxc.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.IndexOf($x64PathSegment, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) { $dxc = $candidate.FullName; break }
    }
    if (-not $dxc) {
      Write-Warning 'Native x64 dxc.exe was not found; runtime D3DCompile remains the final shader check.'
      exit 0
    }
    Write-Host "Using native x64 DXC: $dxc"
    foreach ($entry in @('PSBright', 'PSBlur')) {
      $out = Join-Path $env:RUNNER_TEMP ("bloom-exp18_1-{0}.dxil" -f $entry)
      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = $dxc
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.Arguments = "-T ps_6_0 -E $entry -Fo `"$out`" `"$hlsl`""
      $proc = [System.Diagnostics.Process]::new()
      $proc.StartInfo = $psi
      if (-not $proc.Start()) { throw "DXC failed to start for $entry." }
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()
      if ($stdout) { Write-Host $stdout }
      if ($stderr) { Write-Host $stderr }
      if ($proc.ExitCode -ne 0) { throw "DXC failed for $entry with exit code $($proc.ExitCode)." }
      if (-not (Test-Path -LiteralPath $out)) { throw "DXC did not produce $entry DXIL." }
    }

    Write-Stage 'Apply Bloom 18.2 dual-source multi-scale patch'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/262-d3d12-dual-source-multiscale-bloom-exp18_2.patch'
    $expected = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/gl_d3d12shim.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_backend.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h'
    ) | Sort-Object
    $actual = @(git apply --numstat $patch | ForEach-Object { ($_ -split "`t")[-1] } | Sort-Object -Unique)
    if (($actual -join "`n") -ne ($expected -join "`n")) {
      throw "Unexpected Experiment 18.2 patch scope.`nExpected:`n$($expected -join "`n")`nActual:`n$($actual -join "`n")"
    }
    git apply --check $patch
    git apply $patch
    git diff --check
    git apply --check --reverse $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 18.2 reverse-check failed.' }

    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $backend = Get-Content -LiteralPath 'src/renderer/tr_backend.cpp' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    $local = Get-Content -LiteralPath 'src/renderer/tr_local.h' -Raw
    $header = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    foreach ($marker in @(
      'QD3D12_FinalBloomLevelCount = 4',
      'finalBloomPyramid',
      'finalBloomSceneBright',
      'finalBloomHdrSource',
      'finalBloomBrightAddPSO',
      'finalBloomDownsamplePSO',
      'PSDownsample',
      'glRaytracingLightingGetBloomHdrTexture',
      'BLOOM_EXP18_2 mode=',
      'stage=DUAL_SOURCE_MULTI_SCALE',
      'r_dxrBloomTransparentThreshold',
      'r_dxrBloomSourceGain',
      'r_dxrBloomScatter',
      'r_dxrBloomHdrWeight',
      'r_dxrBloomTransparentWeight',
      'static_assert(sizeof(glRaytracingLightingConstants_t) == 384'
    )) {
      if (-not ($shim.Contains($marker) -or $ray.Contains($marker) -or $backend.Contains($marker) -or $init.Contains($marker) -or $local.Contains($marker) -or $header.Contains($marker))) {
        throw "Missing Experiment 18.2 marker: $marker"
      }
    }
    if (([regex]::Matches($ray, 'const bool useBloom = g_glRaytracingLighting\.constants\.bloomMode != 0u;')).Count -ne 2) {
      throw 'FP16 HDR source staging is not active in both DXR descriptor and execute paths.'
    }
    if ($ray.Contains('const bool useBloom = false;')) {
      throw 'Bloom 18.1 disabled-HDR marker remains after Experiment 18.2.'
    }
    if (-not $ray.Contains('else if (gBloomMode == 0u)')) {
      throw 'RayGen does not preserve unclipped HDR values while Bloom is active.'
    }
    if ($ray.Contains('float3 combinedHdr = hdrColor + bloom * strength;')) {
      throw 'Rejected pre-transparent blur is still active in BloomCS.'
    }
    if (-not $ray.Contains('only converts the stored FP16 opaque scene')) {
      throw 'BloomCS tone-map-only marker is missing.'
    }
    $rb = [regex]::Match($backend, 'void\s+RB_SetGL2D\s*\(\s*void\s*\)\s*\{(?<body>[\s\S]*?)backEnd\.projection2D\s*=\s*qtrue;', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $rb.Success -or -not $rb.Groups['body'].Value.Contains('glFinalSceneBloomApply')) {
      throw 'Final dual-source Bloom is not called before 2D UI.'
    }
    $hlslMatch = [regex]::Match($shim, 'static const char\* kQD3D12FinalBloomHLSL = R"HLSL\((?<body>[\s\S]*?)\)HLSL";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $hlslMatch.Success) { throw 'Bloom 18.2 final HLSL was not found.' }
    $hlslBody = $hlslMatch.Groups['body'].Value
    Write-Host "Bloom 18.2 final HLSL length: $($hlslBody.Length) characters"
    if ($hlslBody.Length -lt 1800 -or $hlslBody.Length -gt 8000) {
      throw "Bloom 18.2 final HLSL size is outside the validated range: $($hlslBody.Length)."
    }
    foreach ($marker in @('Texture2D<float4> gInput', 'float3 ExtractBloom', 'float3 Box4', 'float4 PSBright', 'float4 PSDownsample', 'float4 PSBlur')) {
      if (-not $hlslBody.Contains($marker)) { throw "Missing Bloom 18.2 HLSL marker: $marker" }
    }
    if (([regex]::Matches($shim, 'finalBloomPyramid\[QD3D12_FinalBloomLevelCount\]')).Count -lt 1) {
      throw 'Four-level pyramid storage is missing.'
    }

    Write-Stage 'Apply Game Dynamic Lights Bridge Experiment 19'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/270-d3d12-game-dynamic-lights-bridge-exp19.patch'
    if (-not (Test-Path -LiteralPath $patch)) { throw "Missing Experiment 19 patch: $patch" }

    $patchText = Get-Content -LiteralPath $patch -Raw
    $actualPaths = @([regex]::Matches($patchText, '(?m)^diff --git a/(?<path>\S+) b/\S+$') |
      ForEach-Object { $_.Groups['path'].Value } | Sort-Object -Unique)
    $expectedPaths = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h',
      'src/renderer/tr_scene.cpp'
    ) | Sort-Object
    if (($actualPaths -join '|') -ne ($expectedPaths -join '|')) {
      throw "Unexpected Experiment 19 patch scope: $($actualPaths -join ', ')"
    }
    $addedText = (($patchText -split "`r?`n") | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }) -join "`n"
    foreach ($forbidden in @(
      'glRaytracingLightingConstants_t',
      'D3D12_ROOT_PARAMETER',
      'D3D12_DESCRIPTOR_RANGE',
      'r_dxrBloomMode = ri.Cvar_Get',
      'r_dxrAtmosphereMode = ri.Cvar_Get',
      'r_dxrMaterialSpecularMode = ri.Cvar_Get',
      'r_dxrToneMappingMode = ri.Cvar_Get'
    )) {
      if ($addedText.Contains($forbidden)) { throw "Experiment 19 added forbidden subsystem marker: $forbidden" }
    }

    git apply --ignore-space-change --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19 patch check failed.' }
    git apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19 patch apply failed.' }
    git apply --reverse --ignore-space-change --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19 reverse-check failed.' }

    $scene = Get-Content -LiteralPath 'src/renderer/tr_scene.cpp' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    $local = Get-Content -LiteralPath 'src/renderer/tr_local.h' -Raw
    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    foreach ($marker in @(
      'GAME_DYNAMIC_LIGHTS_EXP19',
      'glRaytracingLightingMakePointLight(',
      'r_dxrGameDynamicLights',
      'r_dxrGameDynamicLightStrength',
      'r_dxrGameDynamicLightRadiusScale',
      'r_dxrGameDynamicLightShadows',
      'r_dxrGameDynamicLightDebug',
      'castsPointShadows'
    )) {
      if (-not ($scene.Contains($marker) -or $init.Contains($marker) -or $local.Contains($marker) -or $ray.Contains($marker))) {
        throw "Missing Experiment 19 source marker: $marker"
      }
    }
    Write-Host 'Experiment 19 patch scope, apply and reverse-check: PASSED'

    Write-Stage 'Apply Game Dynamic Lights Transient Isolation Experiment 19.1'
    $ErrorActionPreference = 'Stop'
    $patch = 'patches/271-d3d12-transient-muzzle-light-isolation-exp19_1.patch'
    if (-not (Test-Path -LiteralPath $patch)) { throw "Missing Experiment 19.1 patch: $patch" }

    $patchText = Get-Content -LiteralPath $patch -Raw
    $actualPaths = @([regex]::Matches($patchText, '(?m)^diff --git a/(?<path>\S+) b/\S+$') |
      ForEach-Object { $_.Groups['path'].Value } | Sort-Object -Unique)
    $expectedPaths = @(
      'src/opengl/gl_d3d12raylight.cpp',
      'src/opengl/opengl.h',
      'src/renderer/tr_init.cpp',
      'src/renderer/tr_local.h',
      'src/renderer/tr_scene.cpp'
    ) | Sort-Object
    if (($actualPaths -join '|') -ne ($expectedPaths -join '|')) {
      throw "Unexpected Experiment 19.1 patch scope: $($actualPaths -join ', ')"
    }

    git apply --ignore-space-change --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19.1 patch check failed.' }
    git apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19.1 patch apply failed.' }
    git apply --reverse --ignore-space-change --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Experiment 19.1 reverse-check failed.' }

    $scene = Get-Content -LiteralPath 'src/renderer/tr_scene.cpp' -Raw
    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $api = Get-Content -LiteralPath 'src/opengl/opengl.h' -Raw
    $init = Get-Content -LiteralPath 'src/renderer/tr_init.cpp' -Raw
    foreach ($marker in @(
      'GAME_DYNAMIC_LIGHTS_EXP19_1',
      'EXP191_FindTrackedLight',
      'r_dxrGameLightFilterMode',
      'r_dxrTransientLightReservedSlots',
      'GL_RAYTRACING_LIGHT_FLAG_TRANSIENT',
      'glRaytracingLightingSetTransientReservedSlots',
      'glRaytracingLightingGetSelectedTransientLightCount'
    )) {
      if (-not ($scene.Contains($marker) -or $ray.Contains($marker) -or $api.Contains($marker) -or $init.Contains($marker))) {
        throw "Missing Experiment 19.1 marker: $marker"
      }
    }
    if ($ray.Contains('D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS') -and -not $patchText.Contains('D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS')) {
      Write-Host 'Existing Bloom UAV resources preserved; Experiment 19.1 adds no resource model changes.'
    }
    Write-Host 'Experiment 19.1 patch scope, apply and reverse-check: PASSED'

    Write-Stage 'Validate Bloom 18.2 shaders with native x64 DXC'
    $ErrorActionPreference = 'Stop'
    $shim = Get-Content -LiteralPath 'src/opengl/gl_d3d12shim.cpp' -Raw
    $finalMatch = [regex]::Match($shim, 'static const char\* kQD3D12FinalBloomHLSL = R"HLSL\((?<body>[\s\S]*?)\)HLSL";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $finalMatch.Success) { throw 'Bloom 18.2 final HLSL source was not found.' }
    $finalHlsl = Join-Path $env:RUNNER_TEMP 'bloom-exp18_2-final.hlsl'
    [IO.File]::WriteAllText($finalHlsl, $finalMatch.Groups['body'].Value, [Text.UTF8Encoding]::new($false))

    $ray = Get-Content -LiteralPath 'src/opengl/gl_d3d12raylight.cpp' -Raw
    $postMatch = [regex]::Match($ray, 'static const char g_glRaytracingBloomPostHlsl\[\] = R"\((?<body>[\s\S]*?)\)";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $postMatch.Success) { throw 'Bloom 18.2 tone-map compute HLSL source was not found.' }
    $postHlsl = Join-Path $env:RUNNER_TEMP 'bloom-exp18_2-tonemap.hlsl'
    [IO.File]::WriteAllText($postHlsl, $postMatch.Groups['body'].Value, [Text.UTF8Encoding]::new($false))

    $parts = [regex]::Matches($ray, 'static const char g_glRaytracingLightingHlslPart(?<index>\d+)\[\] = R"\((?<body>[\s\S]*?)\)";', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($parts.Count -ne 7) { throw "Expected seven MSVC-safe DXR HLSL parts, found $($parts.Count)." }
    $librarySource = ($parts | Sort-Object { [int]$_.Groups['index'].Value } | ForEach-Object { $_.Groups['body'].Value }) -join ''
    $libraryHlsl = Join-Path $env:RUNNER_TEMP 'bloom-exp18_2-library.hlsl'
    [IO.File]::WriteAllText($libraryHlsl, $librarySource, [Text.UTF8Encoding]::new($false))

    $searchRoots = @(
      "$env:ProgramFiles\Windows Kits\10\bin",
      "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $dxc = $null
    $x64PathSegment = [IO.Path]::DirectorySeparatorChar + 'x64' + [IO.Path]::DirectorySeparatorChar
    foreach ($root in $searchRoots) {
      $candidate = Get-ChildItem -LiteralPath $root -Filter dxc.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.IndexOf($x64PathSegment, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) { $dxc = $candidate.FullName; break }
    }
    if (-not $dxc) {
      Write-Warning 'Native x64 dxc.exe was not found; runtime compilation remains the final shader check.'
      exit 0
    }
    Write-Host "Using native x64 DXC: $dxc"

    $jobs = @(
      [pscustomobject]@{ File=$finalHlsl; Target='ps_6_0'; Entry='PSBright'; Name='final-bright' },
      [pscustomobject]@{ File=$finalHlsl; Target='ps_6_0'; Entry='PSDownsample'; Name='final-downsample' },
      [pscustomobject]@{ File=$finalHlsl; Target='ps_6_0'; Entry='PSBlur'; Name='final-blur' },
      [pscustomobject]@{ File=$postHlsl; Target='cs_6_0'; Entry='BloomCS'; Name='tonemap-compute' },
      [pscustomobject]@{ File=$libraryHlsl; Target='lib_6_3'; Entry=''; Name='ray-library' }
    )
    foreach ($job in $jobs) {
      $out = Join-Path $env:RUNNER_TEMP ("bloom-exp18_2-{0}.dxil" -f $job.Name)
      $entryArg = if ($job.Entry) { "-E $($job.Entry)" } else { '' }
      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = $dxc
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.Arguments = "-T $($job.Target) $entryArg -Fo `"$out`" `"$($job.File)`""
      $proc = [System.Diagnostics.Process]::new()
      $proc.StartInfo = $psi
      if (-not $proc.Start()) { throw "DXC failed to start for $($job.Name)." }
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()
      if ($stdout) { Write-Host $stdout }
      if ($stderr) { Write-Host $stderr }
      if ($proc.ExitCode -ne 0) { throw "DXC failed for $($job.Name) with exit code $($proc.ExitCode)." }
      if (-not (Test-Path -LiteralPath $out)) { throw "DXC did not produce $($job.Name) DXIL." }
    }

    Write-Stage 'Install production runtime profiles'
    $ErrorActionPreference = 'Stop'

    $defaultCfg = @'
    // DarkWolf DXR Enhanced Production v1.1 - Full System Runtime
    // Load the complete proven Stable Clear v2.2 baseline first.
    exec dxr_stable_clear_v22.cfg

    // Explicitly enable DXR even if the user's previous config disabled it.
    seta r_dxr "1"

    // Verified production stack: Stable Clear v2.2 + Real Mipmaps + Polygon Offset
    // + Dynamic Light Quality 14 + Atmospheric Fog 15.1
    // + Material-Aware Specular/Roughness 16 R3 + HDR-Like Tone Mapping 17
    // + Dual-Source Multi-Scale Bloom 18.2

    // Stable runtime synchronization
    seta r_dxrAsyncSubmit "0"
    seta r_dxrCpuSync "1"
    seta r_dxrBuildInterval "1"
    seta r_dxrDispatchInterval "1"
    seta r_dxrFallbackCastsShadows "0"

    // Fallback lighting required for visible specular response
    seta r_dxrFallbackLight "1"
    seta r_dxrFallbackLightIntensity "6.0"

    // Approved lighting and materials
    seta r_dxrDynamicLightQualityMode "5"
    seta r_dxrMaterialSpecularMode "5"

    // Approved authored map fog
    seta r_dxrAtmosphereMode "1"
    seta r_dxrAtmosphereStrength "1.0"
    seta r_dxrAtmosphereDistanceScale "1.0"
    seta r_dxrAtmosphereMaxOpacity "0.80"
    seta r_dxrFogBaseHeight "0.0"
    seta r_dxrFogHeightFalloff "320.0"

    // Approved Neutral Luminance HDR-like tone mapping
    seta r_dxrToneMappingMode "4"
    seta r_dxrExposure "1.15"
    seta r_dxrToneMapWhitePoint "4.0"
    seta r_dxrToneMapSaturation "1.0"
    seta r_dxrToneMapContrast "1.0"

    // Approved Balanced Bloom 18.2 profile (tested F11)
    seta r_dxrBloomMode "5"
    seta r_dxrBloomThreshold "1.00"
    seta r_dxrBloomTransparentThreshold "0.65"
    seta r_dxrBloomStrength "0.38"
    seta r_dxrBloomRadius "18.0"
    seta r_dxrBloomSoftKnee "0.50"
    seta r_dxrBloomSourceGain "2.50"
    seta r_dxrBloomScatter "0.72"
    seta r_dxrBloomHdrWeight "1.00"
    seta r_dxrBloomTransparentWeight "1.20"
'@
    Set-Content -LiteralPath 'main/darkwolf_dxr_enhanced.cfg' -Value $defaultCfg -Encoding ASCII

    $bloomOff = @'
    // Bloom disabled; all other production effects remain active.
    seta r_dxrBloomMode "0"
'@
    Set-Content -LiteralPath 'main/dxr_profile_bloom_off.cfg' -Value $bloomOff -Encoding ASCII

    $bloomSubtle = @'
    // Tested F10 Subtle Gameplay Bloom.
    seta r_dxrBloomMode "4"
    seta r_dxrBloomThreshold "1.40"
    seta r_dxrBloomTransparentThreshold "0.78"
    seta r_dxrBloomStrength "0.18"
    seta r_dxrBloomRadius "12.0"
    seta r_dxrBloomSoftKnee "0.35"
    seta r_dxrBloomSourceGain "1.60"
    seta r_dxrBloomScatter "0.55"
    seta r_dxrBloomHdrWeight "0.75"
    seta r_dxrBloomTransparentWeight "0.80"
'@
    Set-Content -LiteralPath 'main/dxr_profile_bloom_subtle.cfg' -Value $bloomSubtle -Encoding ASCII

    $bloomBalanced = @'
    // Tested F11 Balanced Production Bloom. Recommended default.
    seta r_dxrBloomMode "5"
    seta r_dxrBloomThreshold "1.00"
    seta r_dxrBloomTransparentThreshold "0.65"
    seta r_dxrBloomStrength "0.38"
    seta r_dxrBloomRadius "18.0"
    seta r_dxrBloomSoftKnee "0.50"
    seta r_dxrBloomSourceGain "2.50"
    seta r_dxrBloomScatter "0.72"
    seta r_dxrBloomHdrWeight "1.00"
    seta r_dxrBloomTransparentWeight "1.20"
'@
    Set-Content -LiteralPath 'main/dxr_profile_bloom_balanced.cfg' -Value $bloomBalanced -Encoding ASCII

    $bloomStrong = @'
    // Tested F12 stress profile. Very strong and intentionally overexposed in bright scenes.
    seta r_dxrBloomMode "6"
    seta r_dxrBloomThreshold "0.65"
    seta r_dxrBloomTransparentThreshold "0.48"
    seta r_dxrBloomStrength "0.75"
    seta r_dxrBloomRadius "28.0"
    seta r_dxrBloomSoftKnee "0.65"
    seta r_dxrBloomSourceGain "4.00"
    seta r_dxrBloomScatter "0.88"
    seta r_dxrBloomHdrWeight "1.30"
    seta r_dxrBloomTransparentWeight "1.70"
'@
    Set-Content -LiteralPath 'main/dxr_profile_bloom_strong.cfg' -Value $bloomStrong -Encoding ASCII

    $materialBalanced = @'
    // Recommended material-aware response.
    seta r_dxrMaterialSpecularMode "5"
'@
    Set-Content -LiteralPath 'main/dxr_profile_material_balanced.cfg' -Value $materialBalanced -Encoding ASCII

    $materialStrict = @'
    // Stronger suppression of specular on stone, cloth and characters.
    seta r_dxrMaterialSpecularMode "6"
'@
    Set-Content -LiteralPath 'main/dxr_profile_material_strict.cfg' -Value $materialStrict -Encoding ASCII

    $materialWorldMatte = @'
    // Matte world surfaces while retaining the less modified character response.
    seta r_dxrMaterialSpecularMode "4"
'@
    Set-Content -LiteralPath 'main/dxr_profile_material_world_matte.cfg' -Value $materialWorldMatte -Encoding ASCII

    $toneNeutral = @'
    // Recommended production tone mapper.
    seta r_dxrToneMappingMode "4"
'@
    Set-Content -LiteralPath 'main/dxr_profile_tonemap_neutral.cfg' -Value $toneNeutral -Encoding ASCII

    $toneReinhard = @'
    // Softer highlight compression.
    seta r_dxrToneMappingMode "1"
'@
    Set-Content -LiteralPath 'main/dxr_profile_tonemap_reinhard.cfg' -Value $toneReinhard -Encoding ASCII

    $toneHable = @'
    // Darker cinematic contrast.
    seta r_dxrToneMappingMode "3"
'@
    Set-Content -LiteralPath 'main/dxr_profile_tonemap_hable.cfg' -Value $toneHable -Encoding ASCII

    $toneBright = @'
    // Brighter HDR-like presentation.
    seta r_dxrToneMappingMode "5"
'@
    Set-Content -LiteralPath 'main/dxr_profile_tonemap_bright.cfg' -Value $toneBright -Encoding ASCII

    $lightLegacy = @'
    // Original dynamic-light response for compatibility/A-B comparison.
    seta r_dxrDynamicLightQualityMode "0"
'@
    Set-Content -LiteralPath 'main/dxr_profile_lighting_legacy.cfg' -Value $lightLegacy -Encoding ASCII

    $lightBalanced = @'
    // Approved Dynamic Light Quality 14 production mode.
    seta r_dxrDynamicLightQualityMode "5"
'@
    Set-Content -LiteralPath 'main/dxr_profile_lighting_balanced.cfg' -Value $lightBalanced -Encoding ASCII

    $fogOff = @'
    // Disable the added atmospheric-fog pass only.
    seta r_dxrAtmosphereMode "0"
'@
    Set-Content -LiteralPath 'main/dxr_profile_fog_off.cfg' -Value $fogOff -Encoding ASCII

    $fogAuthored = @'
    // Approved Atmospheric Fog 15.1 authored-map mode.
    seta r_dxrAtmosphereMode "1"
    seta r_dxrAtmosphereStrength "1.0"
    seta r_dxrAtmosphereDistanceScale "1.0"
    seta r_dxrAtmosphereMaxOpacity "0.80"
    seta r_dxrFogBaseHeight "0.0"
    seta r_dxrFogHeightFalloff "320.0"
'@
    Set-Content -LiteralPath 'main/dxr_profile_fog_authored.cfg' -Value $fogAuthored -Encoding ASCII

    $launcher = @'
    @echo off
    setlocal
    cd /d "%~dp0"
    WolfSP.exe +set developer 1 +set logfile 2 +set r_dxr 1 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec darkwolf_dxr_enhanced.cfg
    endlocal
'@
    Set-Content -LiteralPath 'RUN_DARKWOLF_DXR_ENHANCED.bat' -Value $launcher -Encoding ASCII

    $launcherOff = @'
    @echo off
    setlocal
    cd /d "%~dp0"
    WolfSP.exe +set developer 1 +set logfile 2 +set r_dxr 1 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec darkwolf_dxr_enhanced.cfg +exec dxr_profile_bloom_off.cfg
    endlocal
'@
    Set-Content -LiteralPath 'RUN_DARKWOLF_DXR_ENHANCED_BLOOM_OFF.bat' -Value $launcherOff -Encoding ASCII

    $launcherSubtle = @'
    @echo off
    setlocal
    cd /d "%~dp0"
    WolfSP.exe +set developer 1 +set logfile 2 +set r_dxr 1 +set r_picmip 0 +set r_picmip2 0 +set r_roundImagesDown 0 +set r_simpleMipMaps 0 +set r_texturebits 32 +set r_textureMode GL_LINEAR_MIPMAP_LINEAR +exec darkwolf_dxr_enhanced.cfg +exec dxr_profile_bloom_subtle.cfg
    endlocal
'@
    Set-Content -LiteralPath 'RUN_DARKWOLF_DXR_ENHANCED_SUBTLE_BLOOM.bat' -Value $launcherSubtle -Encoding ASCII

    Write-Stage 'Build Enhanced Production runtime'
    ./scripts/build-windows-stable-clear-v2.2.ps1 -Configuration $Configuration

    Write-Stage 'Package compact Experiment 19.1 test overlay'
    $ErrorActionPreference = 'Stop'
    $release = 'release-game-dynamic-lights-exp19_1-compact'
    if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Recurse -Force }
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $release 'main') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $release 'SOURCE_PATCH') -Force | Out-Null

    $exeCandidates = @(
      'dist/WolfSP.exe',
      'bin_nt/WolfSP.exe',
      'build/bin/Release/WolfSP.exe',
      'build/bin/Debug/WolfSP.exe'
    )
    $exe = $null
    foreach ($candidate in $exeCandidates) {
      if (Test-Path -LiteralPath $candidate) { $exe = $candidate; break }
    }
    if (-not $exe) {
      $found = Get-ChildItem -Recurse -File -Filter 'WolfSP.exe' | Select-Object -First 1
      if ($found) { $exe = $found.FullName }
    }
    if (-not $exe) { throw 'Compiled WolfSP.exe was not found.' }
    Copy-Item -LiteralPath $exe -Destination (Join-Path $release 'WolfSP.exe') -Force

    Copy-Item -LiteralPath 'RUN_GAME_DYNAMIC_LIGHTS_EXP19_1.bat' -Destination $release -Force
    Copy-Item -LiteralPath 'GAME_DYNAMIC_LIGHTS_EXP19_1_RUN_AND_COLLECT.ps1' -Destination $release -Force
    Copy-Item -LiteralPath 'README_GAME_DYNAMIC_LIGHTS_EXP19_1.txt' -Destination (Join-Path $release 'README.txt') -Force
    Copy-Item -LiteralPath 'main/game_dynamic_lights_exp19_1.cfg' -Destination (Join-Path $release 'main') -Force
    Copy-Item -LiteralPath 'patches/270-d3d12-game-dynamic-lights-bridge-exp19.patch' -Destination (Join-Path $release 'SOURCE_PATCH') -Force
    Copy-Item -LiteralPath 'patches/271-d3d12-transient-muzzle-light-isolation-exp19_1.patch' -Destination (Join-Path $release 'SOURCE_PATCH') -Force

    $manifest = @(
      'DarkWolf Game Dynamic Lights Experiment 19.1 - Compact Test Overlay',
      'BaseCommit=229cd5d93b4c24ba705c9821a871cccf31b34b96',
      "Configuration=$Configuration",
      'PreservedStack=Stable Clear v2.2 + Real Mipmaps + Polygon Offset + Dynamic Light Quality 14 + Fog 15.1 + Materials 16 R3 + Tone Mapping 17 + Bloom 18.2',
      'Experiment=Transient/muzzle-light classification, two reserved DXR slots, transient-only filters and synchronized shot capture',
      'Packaging=WolfSP.exe plus test BAT/CFG/PowerShell, README, manifest and source patches only',
      'RuntimeDLLsIncluded=No',
      'MainGameDLLsIncluded=No',
      'InstallTarget=Existing working Bloom 18.2 release'
    )
    $manifest | Set-Content -LiteralPath (Join-Path $release 'BUILD_MANIFEST.txt') -Encoding UTF8

    foreach ($required in @(
      'WolfSP.exe',
      'RUN_GAME_DYNAMIC_LIGHTS_EXP19_1.bat',
      'GAME_DYNAMIC_LIGHTS_EXP19_1_RUN_AND_COLLECT.ps1',
      'README.txt',
      'main/game_dynamic_lights_exp19_1.cfg',
      'SOURCE_PATCH/270-d3d12-game-dynamic-lights-bridge-exp19.patch',
      'SOURCE_PATCH/271-d3d12-transient-muzzle-light-isolation-exp19_1.patch'
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $release $required))) {
        throw "Required compact test file is missing: $required"
      }
    }

    $unexpected = @(Get-ChildItem -LiteralPath $release -Recurse -File | Where-Object {
      $_.Extension.ToLowerInvariant() -eq '.dll'
    })
    if ($unexpected.Count -gt 0) { throw 'Compact test overlay unexpectedly contains DLL files.' }

    $resolved = (Resolve-Path $release).Path
    $hashes = Get-ChildItem -LiteralPath $release -Recurse -File |
      Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
      Sort-Object FullName | ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        $relative = [IO.Path]::GetRelativePath($resolved, $_.FullName)
        "$hash  $relative"
      }
    $hashes | Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS.txt') -Encoding ASCII

    $totalBytes = (Get-ChildItem -LiteralPath $release -Recurse -File | Measure-Object Length -Sum).Sum
    Write-Host ("Compact Experiment 19.1 package size: {0:N2} MiB" -f ($totalBytes / 1MB))
    Get-ChildItem -LiteralPath $release -Recurse | ForEach-Object { Write-Host $_.FullName }

}
finally {
    Pop-Location
}
