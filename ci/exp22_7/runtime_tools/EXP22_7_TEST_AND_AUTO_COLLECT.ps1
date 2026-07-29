[CmdletBinding()]
param(
    [string]$GameRoot = $PSScriptRoot,
    [string]$Profile = 'darkwolf_exp22_7_production.cfg',
    [switch]$KeepUnpacked,
    [switch]$NoExplorer
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

function Write-Text {
    param([string]$Path, [AllowEmptyString()][string]$Text)
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
    } catch {}
    return $false
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
    $values = New-Object System.Collections.Generic.List[double]
    foreach ($row in $Rows) {
        $value = Get-Value -Object $row -Name $Name
        if ($null -ne $value) { $values.Add($value) }
    }
    if ($values.Count -eq 0) { return $null }
    $measure = $values | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{
        Name = $Name
        Count = $values.Count
        First = $values[0]
        Last = $values[$values.Count - 1]
        Min = [double]$measure.Minimum
        Max = [double]$measure.Maximum
        Avg = [double]$measure.Average
        Delta = $values[$values.Count - 1] - $values[0]
    }
}

function Fmt {
    param($Value, [int]$Decimals = 3)
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString("F$Decimals", $Invariant)
}

try {
    $Root = (Resolve-Path -LiteralPath $GameRoot).Path
} catch {
    $Root = $GameRoot
}

$ResultsRoot = Join-Path $Root 'EXP22_7_RESULTS'
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
$LastErrorPath = Join-Path $ResultsRoot 'EXP22_7_COLLECTOR_LAST_ERROR.txt'
if (Test-Path -LiteralPath $LastErrorPath) { Remove-Item -LiteralPath $LastErrorPath -Force -ErrorAction SilentlyContinue }

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
$FatalCollectorError = $null

try {
    foreach ($directory in @($RunDir, (Join-Path $RunDir 'logs'), (Join-Path $RunDir 'config'), (Join-Path $RunDir 'screenshots'), (Join-Path $RunDir 'crash'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        throw "WolfSP.exe was not found: $Exe"
    }
    if (-not (Test-Path -LiteralPath $MainDir -PathType Container)) {
        throw "The main directory was not found: $MainDir"
    }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        $fallback = Get-ChildItem -LiteralPath $MainDir -File -Filter '*exp22_7*.cfg' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($fallback) {
            $ProfilePath = $fallback.FullName
            $Profile = $fallback.Name
        } else {
            throw "EXP22.7 profile was not found: $ProfilePath"
        }
    }

    $PrimaryLog = Join-Path $MainDir 'qconsole.log'
    if (Test-Path -LiteralPath $PrimaryLog -PathType Leaf) {
        Copy-Safe -Source $PrimaryLog -Destination (Join-Path $RunDir 'logs/qconsole_before_run.log') | Out-Null
        Remove-Item -LiteralPath $PrimaryLog -Force -ErrorAction SilentlyContinue
    }

    $keyFiles = @('WolfSP.exe','OpenAL32.dll','dxcompiler.dll','dxil.dll','sl.interposer.dll','main/cgamex64.dll','main/qagamex64.dll','main/uix64.dll',('main/' + $Profile))
    $hashLines = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $keyFiles) {
        $path = Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
            $hashLines.Add("$hash  $($item.Length)  $relative")
        } else {
            $hashLines.Add("MISSING  0  $relative")
        }
    }
    Write-Text -Path (Join-Path $RunDir 'BINARY_SHA256_AND_SIZE.txt') -Text (($hashLines -join "`r`n") + "`r`n")

    $pk3Lines = New-Object System.Collections.Generic.List[string]
    foreach ($pk3 in @(Get-ChildItem -LiteralPath $MainDir -File -Filter '*.pk3' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $is4k = [int]($pk3.Name -match '(?i)(4k|remaster|hd|uhd)')
        $pk3Lines.Add(("{0}`t{1}`tIs4KLike={2}" -f $pk3.Name, $pk3.Length, $is4k))
    }
    if ($pk3Lines.Count -eq 0) { $pk3Lines.Add('NO_PK3_FILES_FOUND') }
    Write-Text -Path (Join-Path $RunDir 'PK3_FILES.txt') -Text (($pk3Lines -join "`r`n") + "`r`n")

    $hardware = New-Object System.Collections.Generic.List[string]
    $hardware.Add("TestStart=$($StartTime.ToString('o'))")
    $hardware.Add("ComputerName=$env:COMPUTERNAME")
    $hardware.Add("PowerShell=$($PSVersionTable.PSVersion)")
    try { $hardware.Add("OS=$((Get-CimInstance Win32_OperatingSystem).Caption)") } catch { $hardware.Add("OS_QUERY_ERROR=$($_.Exception.Message)") }
    try { foreach ($cpu in @(Get-CimInstance Win32_Processor)) { $hardware.Add("CPU=$($cpu.Name) Cores=$($cpu.NumberOfCores) Threads=$($cpu.NumberOfLogicalProcessors)") } } catch {}
    try { foreach ($gpu in @(Get-CimInstance Win32_VideoController)) { $hardware.Add("GPU=$($gpu.Name) Driver=$($gpu.DriverVersion) VRAMBytes=$($gpu.AdapterRAM)") } } catch {}
    Write-Text -Path (Join-Path $RunDir 'SYSTEM_INFO.txt') -Text (($hardware -join "`r`n") + "`r`n")

    Copy-Safe -Source $ProfilePath -Destination (Join-Path $RunDir ('config/' + $Profile)) | Out-Null
    foreach ($name in @('BUILD_MANIFEST.txt','SHA256SUMS.txt','FULL_RELEASE_CONTENTS.txt','README_EXP22_7_STATIC_DYNAMIC_HIT_TABLE_RU.txt')) {
        Copy-Safe -Source (Join-Path $Root $name) -Destination (Join-Path $RunDir ('config/' + $name)) | Out-Null
    }

    $Arguments = '+set fs_basepath "{0}" +set fs_homepath "{0}" +set r_dxr 1 +set developer 1 +set logfile 2 +exec "{1}"' -f $Root, $Profile
    Write-Text -Path (Join-Path $RunDir 'LAUNCH_COMMAND.txt') -Text ('"' + $Exe + '" ' + $Arguments + "`r`n")

    Write-Host '=============================================================='
    Write-Host ' DarkWolf EXP22.7 automatic test and result collector'
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
    } catch {
        $LaunchError = $_.Exception.ToString()
        Write-Text -Path $LastErrorPath -Text ($LaunchError + "`r`n")
    }
}
catch {
    $FatalCollectorError = $_.Exception.ToString()
    Write-Text -Path $LastErrorPath -Text ($FatalCollectorError + "`r`n")
}
finally {
    $EndTime = Get-Date
    Start-Sleep -Seconds 2

    try {
        if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }
        $allLines = New-Object System.Collections.Generic.List[string]
        $collectedLogs = New-Object System.Collections.Generic.List[string]
        $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'qconsole*.log' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$ResultsRoot*" -and $_.LastWriteTime -ge $StartTime.AddMinutes(-2) })
        $index = 0
        foreach ($file in $candidates) {
            $index++
            $dest = Join-Path $RunDir ("logs/qconsole_{0:D2}.log" -f $index)
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            $collectedLogs.Add($dest)
            foreach ($line in @(Get-Content -LiteralPath $dest -ErrorAction SilentlyContinue)) { $allLines.Add([string]$line) }
        }

        $perfLines = @($allLines | Where-Object { $_ -match 'EXP22_7_PERF\s+' })
        Write-Text -Path (Join-Path $RunDir 'EXP22_7_PERF_RAW.txt') -Text ((($perfLines -join "`r`n") + "`r`n"))
        $rows = New-Object System.Collections.Generic.List[object]
        $sample = 0
        foreach ($line in $perfLines) {
            $sample++
            $record = [ordered]@{ Sample = $sample }
            foreach ($match in [regex]::Matches($line, '(?<key>[A-Za-z][A-Za-z0-9_]*)=(?<value>-?[0-9]+(?:\.[0-9]+)?)')) {
                $number = 0.0
                if ([double]::TryParse($match.Groups['value'].Value, [Globalization.NumberStyles]::Float, $Invariant, [ref]$number)) { $record[$match.Groups['key'].Value] = $number }
            }
            $rows.Add([pscustomobject]$record)
        }
        if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath (Join-Path $RunDir 'EXP22_7_PERF.csv') -NoTypeInformation -Encoding UTF8 } else { Write-Text -Path (Join-Path $RunDir 'EXP22_7_PERF.csv') -Text "Sample`r`n" }

        $fields = @('avgFps','low1Fps','cpuMs','gpuMs','prepareMs','prepareAvgMs','hitTableMs','hitTableAvgMs','preparedNow','updatedNow','tableBuilt','staticActive','dynamicActive','dirtyPrep','dirtyTable','dispatchSlots','fullRebuilds','partialUpdates','updatedRecords','preparedRecords','reusedSlots','staticFallbacks','dynamicFallbacks','allocated','live','stale','active','built','compactions','prunedDynamic','sceneRev','bindingRev','mapGen','prepCacheHit','prepCacheMiss','tableCacheHit','tableCacheMiss','disabledSkips','vramUsedMB','vramBudgetMB')
        $stats = New-Object System.Collections.Generic.List[object]
        foreach ($field in $fields) { $stat = Get-Stats -Rows @($rows) -Name $field; if ($null -ne $stat) { $stats.Add($stat) } }
        $statLines = New-Object System.Collections.Generic.List[string]
        $statLines.Add('Field,Count,First,Last,Min,Max,Average,Delta')
        foreach ($stat in $stats) { $statLines.Add(("{0},{1},{2},{3},{4},{5},{6},{7}" -f $stat.Name,$stat.Count,(Fmt $stat.First),(Fmt $stat.Last),(Fmt $stat.Min),(Fmt $stat.Max),(Fmt $stat.Avg),(Fmt $stat.Delta))) }
        Write-Text -Path (Join-Path $RunDir 'EXP22_7_PERF_SUMMARY.csv') -Text (($statLines -join "`r`n") + "`r`n")

        $issues = @($allLines | Where-Object { $_ -match '(?i)(R_AddMDCSurfaces|DXGI_ERROR|device removed|device hung|fatal error|D3D12.*(error|failed)|^ERROR:|\berror\b)' })
        Write-Text -Path (Join-Path $RunDir 'ERRORS_AND_WARNINGS_EXTRACT.txt') -Text ((($issues -join "`r`n") + "`r`n"))

        $duration = [math]::Round(($EndTime - $StartTime).TotalSeconds, 2)
        $summary = New-Object System.Collections.Generic.List[string]
        $summary.Add('DARKWOLF EXP22.7 AUTOMATIC TEST RESULT')
        $summary.Add('=======================================')
        $summary.Add("RunName=$RunName")
        $summary.Add("DurationSeconds=$duration")
        $summary.Add("GameExitCode=$(if ($null -eq $GameExitCode) { 'n/a' } else { $GameExitCode })")
        $summary.Add("Profile=$Profile")
        $summary.Add("TelemetrySamples=$($rows.Count)")
        $summary.Add("CollectedLogs=$($collectedLogs.Count)")
        $summary.Add("LaunchError=$(if ($LaunchError) { $LaunchError -replace '[\r\n]+',' ' } else { 'none' })")
        $summary.Add("CollectorError=$(if ($FatalCollectorError) { $FatalCollectorError -replace '[\r\n]+',' ' } else { 'none' })")
        $summary.Add('')
        foreach ($stat in $stats) { $summary.Add(("{0}: first={1} last={2} min={3} max={4} avg={5} delta={6}" -f $stat.Name,(Fmt $stat.First),(Fmt $stat.Last),(Fmt $stat.Min),(Fmt $stat.Max),(Fmt $stat.Avg),(Fmt $stat.Delta))) }
        Write-Text -Path (Join-Path $RunDir 'RESULT_OVERVIEW.txt') -Text (($summary -join "`r`n") + "`r`n")

        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal -Force
        if (-not $KeepUnpacked) { Remove-Item -LiteralPath $RunDir -Recurse -Force }
        Write-Host "Result archive: $ZipPath"
        if (-not $NoExplorer) { try { Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`"" } catch {} }
    }
    catch {
        $packError = $_.Exception.ToString()
        Write-Text -Path $LastErrorPath -Text ($packError + "`r`n")
        if (-not $FatalCollectorError) { $FatalCollectorError = $packError }
    }
}

if ($FatalCollectorError) { exit 3 }
if ($LaunchError) { exit 2 }
if ($null -ne $GameExitCode -and $GameExitCode -ne 0) { exit $GameExitCode }
exit 0
