[CmdletBinding()]
param(
    [string]$Profile = 'darkwolf_exp22_7_production.cfg',
    [switch]$KeepUnpacked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$Exe = Join-Path $Root 'WolfSP.exe'
$MainDir = Join-Path $Root 'main'
$ProfilePath = Join-Path $MainDir $Profile
$ResultsRoot = Join-Path $Root 'EXP22_7_RESULTS'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunName = "DarkWolf-EXP22.7-AutoTest-$Stamp"
$RunDir = Join-Path $ResultsRoot ("_working_" + $RunName)
$ZipPath = Join-Path $ResultsRoot ($RunName + '.zip')
$StartTime = Get-Date
$GameExitCode = $null
$LaunchError = $null

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Copy-IfPresent {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $parent = Split-Path -Parent $Destination
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    }
    return $false
}

function Get-NumericValue {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    try { return [double]$property.Value } catch { return $null }
}

function Get-FieldStats {
    param(
        [Parameter(Mandatory=$true)][object[]]$Rows,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $values = New-Object System.Collections.Generic.List[double]
    foreach ($row in $Rows) {
        $value = Get-NumericValue -Object $row -Name $Name
        if ($null -ne $value) { $values.Add($value) }
    }
    if ($values.Count -eq 0) { return $null }

    $measure = $values | Measure-Object -Minimum -Maximum -Average
    [pscustomobject]@{
        Name  = $Name
        Count = $values.Count
        First = $values[0]
        Last  = $values[$values.Count - 1]
        Min   = [double]$measure.Minimum
        Max   = [double]$measure.Maximum
        Avg   = [double]$measure.Average
        Delta = $values[$values.Count - 1] - $values[0]
    }
}

function Format-Number {
    param($Value, [int]$Decimals = 3)
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString("F$Decimals", $Invariant)
}

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "WolfSP.exe was not found next to this script: $Exe"
}
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "Production profile was not found: $ProfilePath"
}

New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $RunDir 'logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $RunDir 'config') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $RunDir 'screenshots') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $RunDir 'crash') -Force | Out-Null

# Preserve the previous local console log, then start this run with a clean log.
$PrimaryLog = Join-Path $MainDir 'qconsole.log'
if (Test-Path -LiteralPath $PrimaryLog -PathType Leaf) {
    Copy-Item -LiteralPath $PrimaryLog -Destination (Join-Path $RunDir 'logs/qconsole_before_run.log') -Force
    Remove-Item -LiteralPath $PrimaryLog -Force
}

$KeyFiles = @(
    'WolfSP.exe',
    'OpenAL32.dll',
    'dxcompiler.dll',
    'dxil.dll',
    'sl.interposer.dll',
    'main/cgamex64.dll',
    'main/qagamex64.dll',
    'main/uix64.dll',
    ('main/' + $Profile)
)

$HashLines = New-Object System.Collections.Generic.List[string]
foreach ($relative in $KeyFiles) {
    $path = Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $item = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        $HashLines.Add("$hash  $($item.Length)  $relative")
    }
    else {
        $HashLines.Add("MISSING  0  $relative")
    }
}
Write-Utf8NoBom -Path (Join-Path $RunDir 'BINARY_SHA256_AND_SIZE.txt') -Text (($HashLines -join "`r`n") + "`r`n")

# Record PK3 configuration so the result shows whether 4K packs were active.
$Pk3Lines = New-Object System.Collections.Generic.List[string]
$Pk3Files = @(Get-ChildItem -LiteralPath $MainDir -File -Filter '*.pk3' -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($pk3 in $Pk3Files) {
    $is4k = [int]($pk3.Name -match '(?i)(4k|remaster|hd|uhd)')
    $Pk3Lines.Add(("{0}`t{1}`tIs4KLike={2}" -f $pk3.Name, $pk3.Length, $is4k))
}
if ($Pk3Lines.Count -eq 0) { $Pk3Lines.Add('NO_PK3_FILES_FOUND') }
Write-Utf8NoBom -Path (Join-Path $RunDir 'PK3_FILES.txt') -Text (($Pk3Lines -join "`r`n") + "`r`n")

# Basic machine information. Failures here must never block the game test.
$HardwareLines = New-Object System.Collections.Generic.List[string]
$HardwareLines.Add("TestStart=$($StartTime.ToString('o'))")
$HardwareLines.Add("ComputerName=$env:COMPUTERNAME")
$HardwareLines.Add("UserName=$env:USERNAME")
$HardwareLines.Add("PowerShell=$($PSVersionTable.PSVersion)")
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $HardwareLines.Add("OS=$($os.Caption) $($os.Version) Build=$($os.BuildNumber)")
    $HardwareLines.Add("PhysicalMemoryGB=$([math]::Round($os.TotalVisibleMemorySize / 1MB, 2))")
} catch { $HardwareLines.Add("OS_QUERY_ERROR=$($_.Exception.Message)") }
try {
    foreach ($cpu in @(Get-CimInstance Win32_Processor)) {
        $HardwareLines.Add("CPU=$($cpu.Name) Cores=$($cpu.NumberOfCores) Threads=$($cpu.NumberOfLogicalProcessors)")
    }
} catch { $HardwareLines.Add("CPU_QUERY_ERROR=$($_.Exception.Message)") }
try {
    foreach ($gpu in @(Get-CimInstance Win32_VideoController)) {
        $HardwareLines.Add("GPU=$($gpu.Name) Driver=$($gpu.DriverVersion) VRAMBytes=$($gpu.AdapterRAM)")
    }
} catch { $HardwareLines.Add("GPU_QUERY_ERROR=$($_.Exception.Message)") }
Write-Utf8NoBom -Path (Join-Path $RunDir 'SYSTEM_INFO.txt') -Text (($HardwareLines -join "`r`n") + "`r`n")

try {
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        & $nvidiaSmi.Source '-q' 2>&1 | Out-File -LiteralPath (Join-Path $RunDir 'NVIDIA_SMI_BEFORE.txt') -Encoding utf8
    }
} catch {}

Copy-IfPresent -Source $ProfilePath -Destination (Join-Path $RunDir ('config/' + $Profile)) | Out-Null
foreach ($name in @('BUILD_MANIFEST.txt','SHA256SUMS.txt','FULL_RELEASE_CONTENTS.txt','README_EXP22_7_STATIC_DYNAMIC_HIT_TABLE_RU.txt')) {
    Copy-IfPresent -Source (Join-Path $Root $name) -Destination (Join-Path $RunDir ('config/' + $name)) | Out-Null
}

$ArgumentString = ('+set fs_basepath "{0}" +set fs_homepath "{0}" +set r_dxr 1 +set developer 1 +set logfile 2 +exec "{1}"' -f $Root, $Profile)
$LaunchCommand = "`"$Exe`" $ArgumentString"
Write-Utf8NoBom -Path (Join-Path $RunDir 'LAUNCH_COMMAND.txt') -Text ($LaunchCommand + "`r`n")

Write-Host ''
Write-Host '=============================================================='
Write-Host ' DarkWolf EXP22.7 automatic test and result collector'
Write-Host ' The game will start now. Play normally, then close the game.'
Write-Host ' The ZIP archive will be created automatically after exit.'
Write-Host '=============================================================='
Write-Host ''

try {
    $process = Start-Process -FilePath $Exe -WorkingDirectory $Root -ArgumentList $ArgumentString -PassThru -Wait
    $GameExitCode = $process.ExitCode
}
catch {
    $LaunchError = $_.Exception.ToString()
}
finally {
    $EndTime = Get-Date
    $DurationSeconds = [math]::Round(($EndTime - $StartTime).TotalSeconds, 2)
    Start-Sleep -Seconds 2

    # Main qconsole generated by fs_homepath. Also collect any other recently
    # modified qconsole files in the release directory.
    $CollectedLogs = New-Object System.Collections.Generic.List[string]
    $logCandidates = @(
        $PrimaryLog,
        (Join-Path $Root 'qconsole.log')
    )
    $logCandidates += @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'qconsole*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$ResultsRoot*" -and $_.LastWriteTime -ge $StartTime.AddMinutes(-1) } |
        Select-Object -ExpandProperty FullName)

    $seen = @{}
    $logIndex = 0
    foreach ($candidate in $logCandidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            ++$logIndex
            $destination = Join-Path $RunDir ("logs/qconsole_{0:D2}.log" -f $logIndex)
            Copy-Item -LiteralPath $candidate -Destination $destination -Force
            $CollectedLogs.Add($destination)
        }
    }

    # Copy screenshots and crash artifacts produced during this run.
    $screenshotExtensions = @('.png','.jpg','.jpeg','.tga')
    $shotIndex = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike "$ResultsRoot*" -and
            $_.LastWriteTime -ge $StartTime.AddSeconds(-5) -and
            $_.Extension.ToLowerInvariant() -in $screenshotExtensions -and
            $_.Length -lt 50MB
        })) {
        ++$shotIndex
        $safeName = ($file.FullName.Substring($Root.Length).TrimStart('\','/') -replace '[\\/:*?"<>|]', '_')
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $RunDir ("screenshots/{0:D3}_{1}" -f $shotIndex, $safeName)) -Force
    }

    $crashPatterns = @('*.dmp','*.mdmp','crash*.log','crash*.txt')
    $crashIndex = 0
    foreach ($pattern in $crashPatterns) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "$ResultsRoot*" -and $_.LastWriteTime -ge $StartTime.AddSeconds(-5) })) {
            ++$crashIndex
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $RunDir ("crash/{0:D3}_{1}" -f $crashIndex, $file.Name)) -Force
        }
    }

    $AllLogLines = New-Object System.Collections.Generic.List[string]
    foreach ($log in $CollectedLogs) {
        foreach ($line in @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)) {
            $AllLogLines.Add([string]$line)
        }
    }

    $PerfLines = @($AllLogLines | Where-Object { $_ -match 'EXP22_7_PERF\s+' })
    Write-Utf8NoBom -Path (Join-Path $RunDir 'EXP22_7_PERF_RAW.txt') -Text ((($PerfLines -join "`r`n") + "`r`n"))

    $PerfRows = New-Object System.Collections.Generic.List[object]
    $sample = 0
    foreach ($line in $PerfLines) {
        ++$sample
        $record = [ordered]@{ Sample = $sample }
        foreach ($match in [regex]::Matches($line, '(?<key>[A-Za-z][A-Za-z0-9_]*)=(?<value>-?[0-9]+(?:\.[0-9]+)?)')) {
            $key = $match.Groups['key'].Value
            $raw = $match.Groups['value'].Value
            $number = 0.0
            if ([double]::TryParse($raw, [Globalization.NumberStyles]::Float, $Invariant, [ref]$number)) {
                $record[$key] = $number
            }
        }
        $PerfRows.Add([pscustomobject]$record)
    }

    if ($PerfRows.Count -gt 0) {
        $PerfRows | Export-Csv -LiteralPath (Join-Path $RunDir 'EXP22_7_PERF.csv') -NoTypeInformation -Encoding UTF8
    }
    else {
        Write-Utf8NoBom -Path (Join-Path $RunDir 'EXP22_7_PERF.csv') -Text "Sample`r`n"
    }

    $Fields = @(
        'avgFps','low1Fps','cpuMs','gpuMs','prepareMs','prepareAvgMs',
        'hitTableMs','hitTableAvgMs','preparedNow','updatedNow','tableBuilt',
        'staticActive','dynamicActive','dirtyPrep','dirtyTable','dispatchSlots',
        'fullRebuilds','partialUpdates','updatedRecords','preparedRecords','reusedSlots',
        'staticFallbacks','dynamicFallbacks','allocated','live','stale','active','built',
        'meshAllocated','meshLive','meshStale','creates','updates','deletes','clears',
        'compactions','prunedDynamic','sceneRev','bindingRev','mapGen','prepCacheHit',
        'prepCacheMiss','tableCacheHit','tableCacheMiss','disabledSkips','vramUsedMB','vramBudgetMB'
    )

    $Stats = New-Object System.Collections.Generic.List[object]
    foreach ($field in $Fields) {
        $stat = Get-FieldStats -Rows @($PerfRows) -Name $field
        if ($null -ne $stat) { $Stats.Add($stat) }
    }

    $StatsLines = New-Object System.Collections.Generic.List[string]
    $StatsLines.Add('Field,Count,First,Last,Min,Max,Average,Delta')
    foreach ($stat in $Stats) {
        $StatsLines.Add(("{0},{1},{2},{3},{4},{5},{6},{7}" -f
            $stat.Name,
            $stat.Count,
            (Format-Number $stat.First),
            (Format-Number $stat.Last),
            (Format-Number $stat.Min),
            (Format-Number $stat.Max),
            (Format-Number $stat.Avg),
            (Format-Number $stat.Delta)))
    }
    Write-Utf8NoBom -Path (Join-Path $RunDir 'EXP22_7_PERF_SUMMARY.csv') -Text (($StatsLines -join "`r`n") + "`r`n")

    $IssueLines = @($AllLogLines | Where-Object {
        $_ -match '(?i)(R_AddMDCSurfaces|DXGI_ERROR|device removed|device hung|fatal error|D3D12.*(error|failed)|^ERROR:|\berror\b)'
    })
    Write-Utf8NoBom -Path (Join-Path $RunDir 'ERRORS_AND_WARNINGS_EXTRACT.txt') -Text ((($IssueLines -join "`r`n") + "`r`n"))

    $Bj2Count = @($AllLogLines | Where-Object { $_ -match '(?i)(R_AddMDCSurfaces.*bj2|EXP22_6_MODEL_FRAME_WRAP)' }).Count
    $DeviceErrorCount = @($AllLogLines | Where-Object { $_ -match '(?i)(DXGI_ERROR|device removed|device hung|D3D12.*(error|failed))' }).Count

    $Summary = New-Object System.Collections.Generic.List[string]
    $Summary.Add('DARKWOLF EXP22.7 AUTOMATIC TEST RESULT')
    $Summary.Add('=======================================')
    $Summary.Add("RunName=$RunName")
    $Summary.Add("Start=$($StartTime.ToString('o'))")
    $Summary.Add("End=$($EndTime.ToString('o'))")
    $Summary.Add("DurationSeconds=$DurationSeconds")
    $Summary.Add("GameExitCode=$(if ($null -eq $GameExitCode) { 'n/a' } else { $GameExitCode })")
    $Summary.Add("Profile=$Profile")
    $Summary.Add("TelemetrySamples=$($PerfRows.Count)")
    $Summary.Add("CollectedLogs=$($CollectedLogs.Count)")
    $Summary.Add("Screenshots=$shotIndex")
    $Summary.Add("CrashArtifacts=$crashIndex")
    $Summary.Add("BJ2OrFrameWrapLines=$Bj2Count")
    $Summary.Add("D3D12OrDeviceErrorLines=$DeviceErrorCount")
    if ($LaunchError) {
        $Summary.Add('')
        $Summary.Add('LAUNCH_ERROR:')
        $Summary.Add($LaunchError)
    }

    $Summary.Add('')
    $Summary.Add('KEY PERFORMANCE STATISTICS:')
    foreach ($name in @('avgFps','low1Fps','cpuMs','gpuMs','prepareMs','hitTableMs','preparedNow','updatedNow','tableBuilt','staticActive','dynamicActive','dirtyPrep','dirtyTable','fullRebuilds','partialUpdates','updatedRecords','reusedSlots','active','live','stale','compactions','prepCacheHit','prepCacheMiss','tableCacheHit','tableCacheMiss','disabledSkips','vramUsedMB')) {
        $stat = $Stats | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($stat) {
            $Summary.Add(("{0}: first={1} last={2} min={3} max={4} avg={5} delta={6}" -f
                $name,
                (Format-Number $stat.First),
                (Format-Number $stat.Last),
                (Format-Number $stat.Min),
                (Format-Number $stat.Max),
                (Format-Number $stat.Avg),
                (Format-Number $stat.Delta)))
        }
    }

    $LastRow = if ($PerfRows.Count -gt 0) { $PerfRows[$PerfRows.Count - 1] } else { $null }
    if ($LastRow) {
        $prepHit = Get-NumericValue $LastRow 'prepCacheHit'
        $prepMiss = Get-NumericValue $LastRow 'prepCacheMiss'
        $tableHit = Get-NumericValue $LastRow 'tableCacheHit'
        $tableMiss = Get-NumericValue $LastRow 'tableCacheMiss'
        if ($null -ne $prepHit -and $null -ne $prepMiss -and ($prepHit + $prepMiss) -gt 0) {
            $Summary.Add("PrepCacheHitRatio=$((100.0 * $prepHit / ($prepHit + $prepMiss)).ToString('F2', $Invariant))%")
        }
        if ($null -ne $tableHit -and $null -ne $tableMiss -and ($tableHit + $tableMiss) -gt 0) {
            $Summary.Add("TableCacheHitRatio=$((100.0 * $tableHit / ($tableHit + $tableMiss)).ToString('F2', $Invariant))%")
        }
    }

    $Summary.Add('')
    $Summary.Add('AUTOMATIC FLAGS:')
    if ($PerfRows.Count -lt 10) {
        $Summary.Add('ATTENTION: fewer than 10 EXP22_7_PERF samples were captured. Run the game longer than 15 seconds and confirm logfile 2 is active.')
    }
    else {
        $Summary.Add('PASS: EXP22_7_PERF telemetry was captured.')
    }
    if ($DeviceErrorCount -gt 0) {
        $Summary.Add('ATTENTION: D3D12/DXGI device error lines were detected. Inspect ERRORS_AND_WARNINGS_EXTRACT.txt.')
    }
    else {
        $Summary.Add('PASS: no D3D12/DXGI device-removal error line was detected in collected logs.')
    }
    $activeStat = $Stats | Where-Object { $_.Name -eq 'active' } | Select-Object -First 1
    if ($activeStat -and $activeStat.Delta -gt 500 -and $activeStat.Last -gt ($activeStat.First * 1.5)) {
        $Summary.Add('ATTENTION: active RT instances grew strongly from first to last sample. Review lifecycle behavior.')
    }
    elseif ($activeStat) {
        $Summary.Add('INFO: active RT instance first/last values are recorded above; map changes can legitimately reset them.')
    }
    $vramStat = $Stats | Where-Object { $_.Name -eq 'vramUsedMB' } | Select-Object -First 1
    if ($vramStat -and $vramStat.Delta -gt 1024) {
        $Summary.Add('ATTENTION: VRAM usage increased by more than 1024 MB during the captured window.')
    }

    Write-Utf8NoBom -Path (Join-Path $RunDir 'RESULT_OVERVIEW.txt') -Text (($Summary -join "`r`n") + "`r`n")

    try {
        $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if ($nvidiaSmi) {
            & $nvidiaSmi.Source '-q' 2>&1 | Out-File -LiteralPath (Join-Path $RunDir 'NVIDIA_SMI_AFTER.txt') -Encoding utf8
        }
    } catch {}

    $LaunchErrorFlat = if ($LaunchError) { ($LaunchError -replace '[\r\n]+', ' ') } else { 'none' }
    $CollectorStatus = @(
        "RunName=$RunName",
        "GameExitCode=$(if ($null -eq $GameExitCode) { 'n/a' } else { $GameExitCode })",
        "LaunchError=$LaunchErrorFlat",
        "TelemetrySamples=$($PerfRows.Count)",
        "CollectedLogs=$($CollectedLogs.Count)",
        "ZipPath=$ZipPath"
    ) -join "`r`n"
    Write-Utf8NoBom -Path (Join-Path $RunDir 'AUTO_COLLECTOR_STATUS.txt') -Text ($CollectorStatus + "`r`n")

    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal -Force

    if (-not $KeepUnpacked) {
        Remove-Item -LiteralPath $RunDir -Recurse -Force
    }

    Write-Host ''
    Write-Host '=============================================================='
    Write-Host ' Test completed. Result archive:'
    Write-Host " $ZipPath"
    Write-Host '=============================================================='
    Write-Host ''

    try {
        Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`""
    } catch {}
}

if ($LaunchError) { exit 2 }
if ($null -ne $GameExitCode) { exit $GameExitCode }
exit 0
