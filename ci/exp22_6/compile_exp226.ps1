param(
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$msbuild = (Get-Command msbuild.exe -ErrorAction Stop).Source
$logDir = Join-Path $work 'ci/exp22_6/build_logs'
if (Test-Path -LiteralPath $logDir) {
  Remove-Item -LiteralPath $logDir -Recurse -Force
}
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$env:MSBUILDDISABLENODEREUSE = '1'
$env:CL_MPCount = '1'

function Write-BuildFailureSummary {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][int]$ExitCode,
    [Parameter(Mandatory=$true)][string[]]$Logs
  )

  $patterns = @(
    '\bfatal error\b',
    '\berror C[0-9]{4}\b',
    '\berror LNK[0-9]{4}\b',
    '\berror MSB[0-9]{4}\b',
    ':\s*error\s+[A-Z]+[0-9]+',
    ':\s*error\s*:'
  )

  $matched = @()
  foreach ($log in $Logs) {
    if (Test-Path -LiteralPath $log -PathType Leaf) {
      $matched += Select-String -LiteralPath $log -Pattern $patterns -CaseSensitive:$false -ErrorAction SilentlyContinue
    }
  }

  $summaryPath = Join-Path $logDir 'BUILD_FAILURE_SUMMARY.txt'
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("PROJECT_NAME=$Name")
  $lines.Add("PROJECT_PATH=$Project")
  $lines.Add("EXIT_CODE=$ExitCode")
  $lines.Add('')
  $lines.Add('COMPILER_AND_LINKER_ERRORS:')
  if ($matched.Count -eq 0) {
    $lines.Add('No canonical compiler/linker error line was extracted. Inspect the diagnostic and binary logs.')
  }
  else {
    foreach ($match in ($matched | Select-Object -Last 200)) {
      $lines.Add($match.Line)
    }
  }
  $lines.Add('')
  $lines.Add('LAST_250_CONSOLE_LINES:')
  $console = $Logs | Where-Object { $_ -like '*.console.log' } | Select-Object -First 1
  if ($console -and (Test-Path -LiteralPath $console -PathType Leaf)) {
    foreach ($line in (Get-Content -LiteralPath $console -Tail 250)) {
      $lines.Add($line)
    }
  }
  [IO.File]::WriteAllLines($summaryPath, $lines, [Text.UTF8Encoding]::new($false))

  Write-Host '================ EXP22.6 BUILD FAILURE SUMMARY ================'
  foreach ($line in $lines) { Write-Host $line }
  Write-Host '==============================================================='
}

function Invoke-LoggedMSBuild {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Project,
    [ValidateSet('Build','Rebuild')][string]$Target = 'Build',
    [int]$Retries = 0
  )

  $projectPath = Join-Path $work $Project
  if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Required MSBuild project is missing: $projectPath"
  }

  for ($attempt = 1; $attempt -le ($Retries + 1); ++$attempt) {
    $stem = '{0}_attempt{1}' -f $Name, $attempt
    $consoleLog = Join-Path $logDir ($stem + '.console.log')
    $diagnosticLog = Join-Path $logDir ($stem + '.diagnostic.log')
    $binaryLog = Join-Path $logDir ($stem + '.binlog')

    $arguments = @(
      $projectPath,
      "/t:$Target",
      '/p:Configuration=Release',
      '/p:Platform=x64',
      '/p:BuildProjectReferences=false',
      '/p:BuildInParallel=false',
      '/p:PreferredToolArchitecture=x64',
      '/p:UseMultiToolTask=false',
      '/m:1',
      '/nr:false',
      '/nologo',
      '/verbosity:minimal',
      "/bl:$binaryLog",
      '/fl',
      "/flp:logfile=$diagnosticLog;verbosity=diagnostic;encoding=UTF-8"
    )

    Write-Host "EXP22_6_MSBUILD_BEGIN NAME=$Name ATTEMPT=$attempt TARGET=$Target PROJECT=$Project BUILD_PROJECT_REFERENCES=0"
    & $msbuild @arguments 2>&1 | Tee-Object -FilePath $consoleLog
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
      Write-Host "EXP22_6_MSBUILD_PASS NAME=$Name ATTEMPT=$attempt PROJECT=$Project"
      return
    }

    if ($attempt -le $Retries) {
      Write-Warning "MSBuild failed for $Project on attempt $attempt. Retrying once because this project is known to regenerate source tables during its first pass."
      continue
    }

    Write-BuildFailureSummary -Name $Name -Project $Project -ExitCode $exitCode -Logs @($consoleLog, $diagnosticLog)
    throw "EXP22.6 project build failed: Name=$Name Project=$Project ExitCode=$exitCode. See ci/exp22_6/build_logs."
  }
}

Push-Location $work
try {
  $wolfProject = 'src/wolf.vcxproj'
  $wolfText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $wolfProject))
  if (-not $wolfText.Contains('<OutputFile>../WolfSP.exe</OutputFile>')) {
    throw 'Release x64 WolfSP output contract changed; expected ../WolfSP.exe.'
  }

  $radiantReferencePresent = $wolfText.Contains('tools\radiant\Radiant.vcxproj')
  $audit = @(
    'DARKWOLF_EXP22_6_EXPLICIT_BUILD_GRAPH',
    'Configuration=Release',
    'Platform=x64',
    'BuildProjectReferences=0',
    'BuildInParallel=0',
    'MSBuildNodeReuse=0',
    "WolfContainsRadiantProjectReference=$([int]$radiantReferencePresent)",
    'RadiantScheduledForBuild=0',
    'BuildOrder=Splines,Botlib,OpenGL,Renderer,CGame,UI,Game,WolfSP',
    'ChangedProjects=OpenGL,Renderer',
    'FinalRelink=WolfSP'
  )
  [IO.File]::WriteAllLines(
    (Join-Path $work 'ci/exp22_6/BUILD_GRAPH_AUDIT.txt'),
    $audit,
    [Text.UTF8Encoding]::new($false)
  )

  # This is the same project-by-project architecture used by the proven Stable
  # Clear build scripts. The Wolf project is never allowed to recursively build
  # its ProjectReference graph, which contains the unrelated Radiant editor.
  Invoke-LoggedMSBuild -Name '01_splines' -Project 'src/splines/Splines.vcxproj' -Target Build
  Invoke-LoggedMSBuild -Name '02_botlib' -Project 'src/botlib/botlib.vcxproj' -Target Build

  # EXP22.6 changes only OpenGL/D3D12 and renderer source owners. Rebuild these
  # static libraries from scratch, then explicitly relink WolfSP.
  Invoke-LoggedMSBuild -Name '03_opengl' -Project 'src/opengl/opengl.vcxproj' -Target Rebuild
  Invoke-LoggedMSBuild -Name '04_renderer' -Project 'src/renderer/renderer.vcxproj' -Target Rebuild

  $releaseOutputs = [ordered]@{
    'src/cgame/cgame.vcxproj' = 'main/cgamex64.dll'
    'src/ui/ui.vcxproj'       = 'main/uix64.dll'
    'src/game/game.vcxproj'   = 'main/qagamex64.dll'
  }
  foreach ($output in $releaseOutputs.Values) {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
  }

  Invoke-LoggedMSBuild -Name '05_cgame' -Project 'src/cgame/cgame.vcxproj' -Target Build
  Invoke-LoggedMSBuild -Name '06_ui' -Project 'src/ui/ui.vcxproj' -Target Build
  Invoke-LoggedMSBuild -Name '07_game' -Project 'src/game/game.vcxproj' -Target Build -Retries 1

  $rebuiltPath = Join-Path $work 'WolfSP.exe'
  if (Test-Path -LiteralPath $rebuiltPath) {
    Remove-Item -LiteralPath $rebuiltPath -Force
  }
  Invoke-LoggedMSBuild -Name '08_wolfsp' -Project $wolfProject -Target Rebuild

  if (-not (Test-Path -LiteralPath $rebuiltPath -PathType Leaf)) {
    throw "EXP22.6 build completed without the exact Release x64 output: $rebuiltPath"
  }
  $rebuilt = Get-Item -LiteralPath $rebuiltPath
  if ($rebuilt.Name -ne 'WolfSP.exe' -or $rebuilt.Length -lt 1MB) {
    throw "Invalid WolfSP Release output: $($rebuilt.FullName) Size=$($rebuilt.Length)"
  }

  foreach ($entry in $releaseOutputs.GetEnumerator()) {
    $output = Join-Path $work $entry.Value
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
      throw "Exact Release x64 VM output is missing: $output"
    }
    $item = Get-Item -LiteralPath $output
    if ($item.Name -match '_d\.dll$' -or $item.Length -lt 524288) {
      throw "Invalid Release VM module: $($item.FullName) Size=$($item.Length)"
    }
  }

  $sourceRelease = Join-Path $work 'release-rt-reflection-native-composite-exp22_4'
  if (-not (Test-Path -LiteralPath $sourceRelease -PathType Container)) {
    throw "EXP22.4 release directory is missing: $sourceRelease"
  }
  Copy-Item -LiteralPath $rebuiltPath -Destination (Join-Path $sourceRelease 'WolfSP.exe') -Force

  $manifestLines = [System.Collections.Generic.List[string]]::new()
  $manifestLines.Add('DARKWOLF_EXP22_6_COMPILE_MANIFEST')
  $manifestLines.Add('Configuration=Release')
  $manifestLines.Add('Platform=x64')
  $manifestLines.Add('BuildProjectReferences=0')
  $manifestLines.Add('RadiantBuilt=0')
  foreach ($relative in @('WolfSP.exe','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll')) {
    $path = Join-Path $work $relative
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    $size = (Get-Item -LiteralPath $path).Length
    $key = $relative.Replace('/','_').Replace('.','_').ToUpperInvariant()
    $manifestLines.Add("${key}_SHA256=$hash")
    $manifestLines.Add("${key}_BYTES=$size")
  }
  [IO.File]::WriteAllLines(
    (Join-Path $work 'ci/exp22_6/EXP22_6_COMPILE_MANIFEST.txt'),
    $manifestLines,
    [Text.UTF8Encoding]::new($false)
  )

  Write-Host "EXP22_6_WOLFSP_BUILD=PASS SHA256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $rebuiltPath).Hash)"
  Write-Host 'EXP22_6_RELEASE_VM_BUILD=PASS'
  Write-Host 'EXP22_6_EXPLICIT_BUILD_GRAPH=PASS RADIANT_BUILT=0'
}
finally {
  Pop-Location
}
