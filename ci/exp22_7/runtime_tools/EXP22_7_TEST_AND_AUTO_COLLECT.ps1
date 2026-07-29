[CmdletBinding()]
param(
    [string]$Profile = 'darkwolf_exp22_7_production.cfg',
    [switch]$KeepUnpacked,
    [switch]$NoExplorer
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

function Write-Text {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Copy-Safe {
    param([string]$Source, [string]$Destination)
    try {
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            $parent = Split-Path -Parent $Destination
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            return $true
        }
    }
    catch {}
    return $false
}

function Get-ErrorText {
    param($ErrorRecord)
    try {
        return ($ErrorRecord | Out-String).Trim()
    }
    catch {
        try { return $ErrorRecord.Exception.ToString() } catch { return 'Unknown collector error.' }
    }
}

function Get-Value {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    try { return [double]$property.Value } catch { return $null }
}

function Get-Stats {
    param([object[]]$Rows, [string]$Name)
    $values = @()
    foreach ($row in $Rows) {
        $value = Get-Value -Object $row -Name $Name
        if ($null -ne $value) { $values += [double]$value }
    }
    if ($values.Count -eq 0) { return $null }
    $measure = $values | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{
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

function Fmt {
    param($Value, [int]$Decimals = 3)
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString("F$Decimals", $Invariant)
}

function Add-UniquePath {
    param(
        [hashtable]$Seen,
        [ref]$Paths,
        [string]$Candidate
    )
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    try { $full = [IO.Path]::GetFullPath($Candidate) } catch { return }
    $key = $full.ToLowerInvariant()
    if (-not $Seen.ContainsKey($key) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
        $Seen[$key] = $true
        $Paths.Value += $full
    }
}

$Root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ResultsRoot = Join-Path $Root 'EXP22_7_RESULTS'
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null

$LastErrorPath = Join-Path $ResultsRoot 'EXP22_7_COLLECTOR_LAST_ERROR.txt'
if (Test-Path -LiteralPath $LastErrorPath) {
    Remove-Item -LiteralPath $LastErrorPath -Force -ErrorAction SilentlyContinue
}

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunName = "DarkWolf-EXP22.7-AutoTest-$Stamp"
$RunDir = Join-Path $ResultsRoot ("_working_" + $RunName)
$ZipPath = Join-Path $ResultsRoot ($RunName + '.zip')
$Exe = Join-Path $Root 'WolfSP.exe'
$MainDir = Join-Path $Root 'main'
$ProfilePath = Join-Path $MainDir $Profile
$StartTime = Get-Date
$EndTime = $null
$GameExitCode = $null
$LaunchError = $null
$CollectorErrors = @()
$ZipCreated = $false

try {
    foreach ($directory in @(
        $RunDir,
        (Join-Path $RunDir 'logs'),
        (Join-Path $RunDir 'logs_before_run'),
        (Join-Path $RunDir 'config'),
        (Join-Path $RunDir 'screenshots'),
        (Join-Path $RunDir 'crash')
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "WolfSP.exe was not found: $Exe" }
    if (-not (Test-Path -LiteralPath $MainDir -PathType Container)) { throw "The main directory was not found: $MainDir" }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        $fallback = Get-ChildItem -LiteralPath $MainDir -File -Filter '*exp22_7*.cfg' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($fallback) {
            $ProfilePath = $fallback.FullName
            $Profile = $fallback.Name
        }
        else { throw "EXP22.7 profile was not found: $ProfilePath" }
    }

    $oldLogs = @()
    foreach ($candidate in @(
        (Join-Path $MainDir 'qconsole.log'),
        (Join-Path $MainDir 'rtcwconsole.log'),
        (Join-Path $Root 'qconsole.log'),
        (Join-Path $Root 'rtcwconsole.log')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $oldLogs += $candidate }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$ResultsRoot*" -and $_.Name -match '^(qconsole|rtcwconsole).*\.log$' })) {
        if ($oldLogs -notcontains $file.FullName) { $oldLogs += $file.FullName }
    }
    $oldIndex = 0
    foreach ($oldLog in $oldLogs) {
        $oldIndex++
        Copy-Safe -Source $oldLog -Destination (Join-Path $RunDir ("logs_before_run/{0:D2}_{1}" -f $oldIndex, [IO.Path]::GetFileName($oldLog))) | Out-Null
        Remove-Item -LiteralPath $oldLog -Force -ErrorAction SilentlyContinue
    }

    $keyFiles = @('WolfSP.exe','OpenAL32.dll','dxcompiler.dll','dxil.dll','sl.interposer.dll','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll',('main/' + $Profile))
    $hashLines = @()
    foreach ($relative in $keyFiles) {
        $path = Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
            $hashLines += "$hash  $($item.Length)  $relative"
        }
        else { $hashLines += "MISSING  0  $relative" }
    }
    Write-Text -Path (Join-Path $RunDir 'BINARY_SHA256_AND_SIZE.txt') -Text (($hashLines -join "`r`n") + "`r`n")

    $pk3Lines = @()
    foreach ($pk3 in @(Get-ChildItem -LiteralPath $MainDir -File -Filter '*.pk3' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $is4k = [int]($pk3.Name -match '(?i)(4k|remaster|hd|uhd)')
        $pk3Lines += ("{0}`t{1}`tIs4KLike={2}" -f $pk3.Name, $pk3.Length, $is4k)
    }
    if ($pk3Lines.Count -eq 0) { $pk3Lines = @('NO_PK3_FILES_FOUND') }
    Write-Text -Path (Join-Path $RunDir 'PK3_FILES.txt') -Text (($pk3Lines -join "`r`n") + "`r`n")

    $hardware = @()
    $hardware += "TestStart=$($StartTime.ToString('o'))"
    $hardware += "ComputerName=$env:COMPUTERNAME"
    $hardware += "UserName=$env:USERNAME"
    $hardware += "PowerShell=$($PSVersionTable.PSVersion)"
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $hardware += "OS=$($os.Caption) $($os.Version) Build=$($os.BuildNumber)"
        $hardware += "PhysicalMemoryGB=$([math]::Round($os.TotalVisibleMemorySize / 1MB, 2))"
    } catch { $hardware += "OS_QUERY_ERROR=$($_.Exception.Message)" }
    try { foreach ($cpu in @(Get-CimInstance Win32_Processor)) { $hardware += "CPU=$($cpu.Name) Cores=$($cpu.NumberOfCores) Threads=$($cpu.NumberOfLogicalProcessors)" } } catch {}
    try { foreach ($gpu in @(Get-CimInstance Win32_VideoController)) { $hardware += "GPU=$($gpu.Name) Driver=$($gpu.DriverVersion) VRAMBytes=$($gpu.AdapterRAM)" } } catch {}
    Write-Text -Path (Join-Path $RunDir 'SYSTEM_INFO.txt') -Text (($hardware -join "`r`n") + "`r`n")

    try {
        $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if ($nvidiaSmi) { & $nvidiaSmi.Source '-q' 2>&1 | Out-File -LiteralPath (Join-Path $RunDir 'NVIDIA_SMI_BEFORE.txt') -Encoding utf8 }
    } catch {}

    Copy-Safe -Source $ProfilePath -Destination (Join-Path $RunDir ('config/' + $Profile)) | Out-Null
    foreach ($name in @('BUILD_MANIFEST.txt','SHA256SUMS.txt','FULL_RELEASE_CONTENTS.txt','README_EXP22_7_STATIC_DYNAMIC_HIT_TABLE_RU.txt')) {
        Copy-Safe -Source (Join-Path $Root $name) -Destination (Join-Path $RunDir ('config/' + $name)) | Out-Null
    }

    $Arguments = '+set fs_basepath "{0}" +set fs_homepath "{0}" +set r_dxr 1 +set developer 1 +set logfile 2 +exec "{1}"' -f $Root, $Profile
    Write-Text -Path (Join-Path $RunDir 'LAUNCH_COMMAND.txt') -Text ('"' + $Exe + '" ' + $Arguments + "`r`n")

    Write-Host '=============================================================='
    Write-Host ' DarkWolf EXP22.7 automatic test and result collector v3'
    Write-Host '=============================================================='
    Write-Host "Executable: $Exe"
    Write-Host "Profile:    $Profile"
    Write-Host 'Starting the game...'

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.WorkingDirectory = $Root
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        Write-Host "Game started. PID=$($process.Id). Close the game normally after the test."
        $process.WaitForExit()
        $GameExitCode = $process.ExitCode
    }
    catch {
        $LaunchError = Get-ErrorText -ErrorRecord $_
        Write-Text -Path $LastErrorPath -Text ($LaunchError + "`r`n")
    }
}
catch {
    $text = Get-ErrorText -ErrorRecord $_
    $CollectorErrors += $text
    Write-Text -Path $LastErrorPath -Text ($text + "`r`n")
}
finally {
    $EndTime = Get-Date
    Start-Sleep -Seconds 3

    try {
        if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }

        $logPaths = @()
        $seenLogs = @{}
        foreach ($candidate in @(
            (Join-Path $MainDir 'qconsole.log'),
            (Join-Path $MainDir 'rtcwconsole.log'),
            (Join-Path $Root 'qconsole.log'),
            (Join-Path $Root 'rtcwconsole.log')
        )) { Add-UniquePath -Seen $seenLogs -Paths ([ref]$logPaths) -Candidate $candidate }
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "$ResultsRoot*" -and
                $_.Extension -eq '.log' -and
                $_.LastWriteTime -ge $StartTime.AddMinutes(-2) -and
                $_.Length -lt 100MB
            } | Sort-Object LastWriteTime, FullName)) {
            Add-UniquePath -Seen $seenLogs -Paths ([ref]$logPaths) -Candidate $file.FullName
        }

        $allLines = @()
        $collectedLogs = @()
        $logIndex = 0
        foreach ($logPath in $logPaths) {
            $logIndex++
            $dest = Join-Path $RunDir ("logs/{0:D2}_{1}" -f $logIndex, [IO.Path]::GetFileName($logPath))
            Copy-Item -LiteralPath $logPath -Destination $dest -Force
            $collectedLogs += $dest
            $allLines += @(Get-Content -LiteralPath $dest -ErrorAction SilentlyContinue)
        }

        $logInventory = @()
        foreach ($path in $logPaths) {
            $item = Get-Item -LiteralPath $path
            $logInventory += "$($item.LastWriteTime.ToString('o'))`t$($item.Length)`t$path"
        }
        if ($logInventory.Count -eq 0) { $logInventory = @('NO_ENGINE_LOG_FILES_FOUND') }
        Write-Text -Path (Join-Path $RunDir 'COLLECTED_LOG_FILES.txt') -Text (($logInventory -join "`r`n") + "`r`n")

        $shotIndex = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "$ResultsRoot*" -and
                $_.LastWriteTime -ge $StartTime.AddSeconds(-5) -and
                $_.Extension -match '^\.(png|jpg|jpeg|tga)$' -and
                $_.Length -lt 50MB
            })) {
            $shotIndex++
            $safeName = ($file.FullName.Substring($Root.Length).TrimStart('\','/') -replace '[\\/:*?"<>|]', '_')
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $RunDir ("screenshots/{0:D3}_{1}" -f $shotIndex, $safeName)) -Force
        }

        $crashIndex = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "$ResultsRoot*" -and
                $_.LastWriteTime -ge $StartTime.AddSeconds(-5) -and
                ($_.Extension -match '^\.(dmp|mdmp)$' -or $_.Name -match '(?i)^crash.*\.(log|txt)$')
            })) {
            $crashIndex++
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $RunDir ("crash/{0:D3}_{1}" -f $crashIndex, $file.Name)) -Force
        }

        $perfLines = @($allLines | Where-Object { [string]$_ -match 'EXP22_7_PERF\s+' })
        Write-Text -Path (Join-Path $RunDir 'EXP22_7_PERF_RAW.txt') -Text ((($perfLines -join "`r`n") + "`r`n"))

        $rows = @()
        $sample = 0
        foreach ($line in $perfLines) {
            $sample++
            $record = [ordered]@{ Sample = $sample }
            foreach ($match in [regex]::Matches([string]$line, '(?<key>[A-Za-z][A-Za-z0-9_]*)=(?<value>-?[0-9]+(?:\.[0-9]+)?)')) {
                $number = 0.0
                if ([double]::TryParse($match.Groups['value'].Value, [Globalization.NumberStyles]::Float, $Invariant, [ref]$number)) { $record[$match.Groups['key'].Value] = $number }
            }
            $rows += [pscustomobject]$record
        }

        $perfCsv = Join-Path $RunDir 'EXP22_7_PERF.csv'
        if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath $perfCsv -NoTypeInformation -Encoding UTF8 }
        else { Write-Text -Path $perfCsv -Text "Sample`r`n" }

        $fields = @(
            'avgFps','low1Fps','cpuMs','gpuMs','prepareMs','prepareAvgMs','hitTableMs','hitTableAvgMs',
            'preparedNow','updatedNow','tableBuilt','staticActive','dynamicActive','dirtyPrep','dirtyTable','dispatchSlots',
            'fullRebuilds','partialUpdates','updatedRecords','preparedRecords','reusedSlots','staticFallbacks','dynamicFallbacks',
            'allocated','live','stale','active','built','meshAllocated','meshLive','meshStale','creates','updates','deletes','clears',
            'compactions','prunedDynamic','sceneRev','bindingRev','mapGen','prepCacheHit','prepCacheMiss','tableCacheHit','tableCacheMiss',
            'disabledSkips','vramUsedMB','vramBudgetMB'
        )
        $stats = @()
        foreach ($field in $fields) {
            $stat = Get-Stats -Rows $rows -Name $field
            if ($null -ne $stat) { $stats += $stat }
        }

        $statLines = @('Field,Count,First,Last,Min,Max,Average,Delta')
        foreach ($stat in $stats) {
            $statLines += ("{0},{1},{2},{3},{4},{5},{6},{7}" -f $stat.Name,$stat.Count,(Fmt $stat.First),(Fmt $stat.Last),(Fmt $stat.Min),(Fmt $stat.Max),(Fmt $stat.Avg),(Fmt $stat.Delta))
        }
        Write-Text -Path (Join-Path $RunDir 'EXP22_7_PERF_SUMMARY.csv') -Text (($statLines -join "`r`n") + "`r`n")

        $lowRows = @()
        foreach ($row in $rows) {
            $avg = Get-Value -Object $row -Name 'avgFps'
            $low1 = Get-Value -Object $row -Name 'low1Fps'
            if (($null -ne $avg -and $avg -lt 60.0) -or ($null -ne $low1 -and $low1 -lt 30.0)) { $lowRows += $row }
        }
        if ($lowRows.Count -gt 0) { $lowRows | Export-Csv -LiteralPath (Join-Path $RunDir 'EXP22_7_LOW_FPS_SAMPLES.csv') -NoTypeInformation -Encoding UTF8 }
        else { Write-Text -Path (Join-Path $RunDir 'EXP22_7_LOW_FPS_SAMPLES.csv') -Text "Sample`r`n" }

        $transitions = @()
        for ($i = 1; $i -lt $rows.Count; $i++) {
            $current = $rows[$i]
            $previous = $rows[$i - 1]
            $transition = [ordered]@{
                Sample = Get-Value $current 'Sample'
                avgFps = Get-Value $current 'avgFps'
                low1Fps = Get-Value $current 'low1Fps'
                cpuMs = Get-Value $current 'cpuMs'
                gpuMs = Get-Value $current 'gpuMs'
                prepareMs = Get-Value $current 'prepareMs'
                hitTableMs = Get-Value $current 'hitTableMs'
                preparedNow = Get-Value $current 'preparedNow'
                updatedNow = Get-Value $current 'updatedNow'
                tableBuilt = Get-Value $current 'tableBuilt'
            }
            foreach ($counter in @('fullRebuilds','partialUpdates','updatedRecords','preparedRecords','bindingRev','sceneRev','creates','updates','deletes','active','dynamicActive','reusedSlots','vramUsedMB')) {
                $now = Get-Value $current $counter
                $before = Get-Value $previous $counter
                $deltaName = 'd' + $counter.Substring(0,1).ToUpperInvariant() + $counter.Substring(1)
                if ($null -ne $now -and $null -ne $before) { $transition[$deltaName] = $now - $before }
            }
            $transitions += [pscustomobject]$transition
        }
        if ($transitions.Count -gt 0) { $transitions | Export-Csv -LiteralPath (Join-Path $RunDir 'EXP22_7_TRANSITIONS.csv') -NoTypeInformation -Encoding UTF8 }
        else { Write-Text -Path (Join-Path $RunDir 'EXP22_7_TRANSITIONS.csv') -Text "Sample`r`n" }

        $issues = @($allLines | Where-Object { [string]$_ -match '(?i)(R_AddMDCSurfaces|DXGI_ERROR|device removed|device hung|fatal error|D3D12.*(error|failed)|^ERROR:|\berror\b)' })
        Write-Text -Path (Join-Path $RunDir 'ERRORS_AND_WARNINGS_EXTRACT.txt') -Text ((($issues -join "`r`n") + "`r`n"))

        try {
            $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
            if ($nvidiaSmi) { & $nvidiaSmi.Source '-q' 2>&1 | Out-File -LiteralPath (Join-Path $RunDir 'NVIDIA_SMI_AFTER.txt') -Encoding utf8 }
        } catch {}

        $duration = [math]::Round(($EndTime - $StartTime).TotalSeconds, 2)
        $gameExitText = 'n/a'
        if ($null -ne $GameExitCode) { $gameExitText = [string]$GameExitCode }
        $launchText = 'none'
        if ($LaunchError) { $launchText = $LaunchError -replace '[\r\n]+',' ' }
        $collectorText = 'none'
        if ($CollectorErrors.Count -gt 0) { $collectorText = ($CollectorErrors -join ' | ') -replace '[\r\n]+',' ' }

        $summary = @()
        $summary += 'DARKWOLF EXP22.7 AUTOMATIC TEST RESULT'
        $summary += '======================================='
        $summary += 'CollectorVersion=3'
        $summary += "RunName=$RunName"
        $summary += "Start=$($StartTime.ToString('o'))"
        $summary += "End=$($EndTime.ToString('o'))"
        $summary += "DurationSeconds=$duration"
        $summary += "GameExitCode=$gameExitText"
        $summary += "Profile=$Profile"
        $summary += "TelemetrySamples=$($rows.Count)"
        $summary += "CollectedLogs=$($collectedLogs.Count)"
        $summary += "Screenshots=$shotIndex"
        $summary += "CrashArtifacts=$crashIndex"
        $summary += "LowFpsSamples=$($lowRows.Count)"
        $summary += "LaunchError=$launchText"
        $summary += "CollectorError=$collectorText"
        $summary += ''
        $summary += 'KEY PERFORMANCE STATISTICS:'
        foreach ($stat in $stats) {
            $summary += ("{0}: first={1} last={2} min={3} max={4} avg={5} delta={6}" -f $stat.Name,(Fmt $stat.First),(Fmt $stat.Last),(Fmt $stat.Min),(Fmt $stat.Max),(Fmt $stat.Avg),(Fmt $stat.Delta))
        }
        $summary += ''
        $summary += 'AUTOMATIC FLAGS:'
        if ($rows.Count -lt 10) { $summary += 'ATTENTION: fewer than 10 EXP22_7_PERF samples were captured.' }
        else { $summary += 'PASS: EXP22_7_PERF telemetry was captured.' }
        if ($collectedLogs.Count -eq 0) { $summary += 'ATTENTION: no engine console log was found. Confirm logfile 2 and inspect the game directory for rtcwconsole.log.' }
        if ($issues.Count -gt 0) { $summary += 'ATTENTION: error-like log lines were detected. Inspect ERRORS_AND_WARNINGS_EXTRACT.txt.' }
        else { $summary += 'PASS: no D3D12/DXGI/device-removal error-like line was detected.' }
        if ($rows.Count -gt 0) {
            $lowPercent = 100.0 * $lowRows.Count / $rows.Count
            $summary += "LowFpsSampleRatio=$($lowPercent.ToString('F2', $Invariant))%"
            $tableBuiltValues = @()
            foreach ($row in $rows) { $value = Get-Value $row 'tableBuilt'; if ($null -ne $value) { $tableBuiltValues += [double]$value } }
            if ($tableBuiltValues.Count -gt 0) {
                $tableBuiltPercent = 100.0 * (($tableBuiltValues | Measure-Object -Sum).Sum) / $tableBuiltValues.Count
                $summary += "TableBuiltSampleRatio=$($tableBuiltPercent.ToString('F2', $Invariant))%"
            }
        }
        Write-Text -Path (Join-Path $RunDir 'RESULT_OVERVIEW.txt') -Text (($summary -join "`r`n") + "`r`n")
    }
    catch {
        $text = Get-ErrorText -ErrorRecord $_
        $CollectorErrors += $text
        Write-Text -Path (Join-Path $RunDir 'COLLECTION_ERROR.txt') -Text ($text + "`r`n")
        Write-Text -Path $LastErrorPath -Text (($CollectorErrors -join "`r`n---`r`n") + "`r`n")
    }

    try {
        if (Test-Path -LiteralPath $ZipPath -PathType Leaf) { Remove-Item -LiteralPath $ZipPath -Force }
        Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal -Force
        $ZipCreated = Test-Path -LiteralPath $ZipPath -PathType Leaf
    }
    catch {
        $text = Get-ErrorText -ErrorRecord $_
        $CollectorErrors += $text
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path -LiteralPath $ZipPath -PathType Leaf) { Remove-Item -LiteralPath $ZipPath -Force }
            [IO.Compression.ZipFile]::CreateFromDirectory($RunDir, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
            $ZipCreated = Test-Path -LiteralPath $ZipPath -PathType Leaf
        }
        catch {
            $CollectorErrors += (Get-ErrorText -ErrorRecord $_)
            Write-Text -Path $LastErrorPath -Text (($CollectorErrors -join "`r`n---`r`n") + "`r`n")
        }
    }

    if ($ZipCreated) {
        if (-not $KeepUnpacked) { Remove-Item -LiteralPath $RunDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host ''
        Write-Host '=============================================================='
        Write-Host ' Test completed. Result archive:'
        Write-Host " $ZipPath"
        Write-Host '=============================================================='
        if (-not $NoExplorer) { try { Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`"" } catch {} }
    }
    else { Write-Host "Archive creation failed. Unpacked results remain in: $RunDir" }
}

if (-not $ZipCreated) { exit 4 }
if ($LaunchError) { exit 2 }
if ($null -ne $GameExitCode -and $GameExitCode -ne 0) { exit $GameExitCode }
exit 0
