param(
  [Parameter(Mandatory=$true)][string]$DonorRoot,
  [Parameter(Mandatory=$true)][string]$WorkRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$donorRootResolved = (Resolve-Path -LiteralPath $DonorRoot).Path
$work = (Resolve-Path -LiteralPath $WorkRoot).Path
$expectedDonorCommit = '7a5b93de850c2ac2d172af53ac26923fad9af1cd'
$actualDonorCommit = (& git -C $donorRootResolved rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualDonorCommit -ne $expectedDonorCommit) {
  throw "EXP22.4 donor checkout mismatch. Expected=$expectedDonorCommit Actual=$actualDonorCommit"
}

$donor = Join-Path $donorRootResolved '.github/workflows/darkwolf-d3d12-native-hit-production-composite-exp22_4.yml'
if (-not (Test-Path -LiteralPath $donor -PathType Leaf)) {
  throw "Required donor workflow is missing: $donor"
}

$expectedDonorSha = 'DB30552F3B2663A41892CDD434370A58F468F82C1A5229358E14E09BE2425D0A'
$workflowText = [IO.File]::ReadAllText((Resolve-Path $donor), [Text.Encoding]::UTF8)
$normalizedWorkflowText = $workflowText.Replace("`r`n", "`n").Replace("`r", "`n")
$utf8NoBomForHash = [Text.UTF8Encoding]::new($false)
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
  $actualDonorSha = ([BitConverter]::ToString(
    $sha256.ComputeHash($utf8NoBomForHash.GetBytes($normalizedWorkflowText))
  )).Replace('-', '')
}
finally {
  $sha256.Dispose()
}
if ($actualDonorSha -ne $expectedDonorSha) {
  throw "EXP22.4 donor workflow normalized hash mismatch. Expected=$expectedDonorSha Actual=$actualDonorSha"
}

$payloadMatch = [regex]::Match(
  $normalizedWorkflowText,
  "(?ms)^\s*\`$base64\s*=\s*@'\s*(?<payload>.*?)^\s*'@\s*$"
)
if (-not $payloadMatch.Success) {
  throw 'Unable to locate the EXP22.4 embedded payload here-string.'
}

$payloadBase64 = $payloadMatch.Groups['payload'].Value -replace '\s', ''
$payloadArchive = Join-Path $env:RUNNER_TEMP 'exp22_4-proven-payload.zip'
[IO.File]::WriteAllBytes($payloadArchive, [Convert]::FromBase64String($payloadBase64))

$expectedPayloadSha = '2B2A7C867CDA10D6324AC114F0F5F9AEE05D20FAA50341F417F7C87A6330D393'
$actualPayloadSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadArchive).Hash
if ($actualPayloadSha -ne $expectedPayloadSha) {
  throw "EXP22.4 payload hash mismatch. Expected=$expectedPayloadSha Actual=$actualPayloadSha"
}

Expand-Archive -LiteralPath $payloadArchive -DestinationPath $work -Force
$manifest = Join-Path $work 'PAYLOAD_SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
  throw 'EXP22.4 payload manifest is missing after extraction.'
}

$verified = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $manifest))) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split '\s{2,}', 2
  if ($parts.Count -ne 2) { throw "Malformed payload manifest line: $line" }
  $relative = $parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
  $path = Join-Path $work $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Payload file is missing after extraction: $($parts[1])"
  }
  $fileSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  if ($fileSha -ne $parts[0]) { throw "Payload file hash mismatch: $($parts[1])" }
  ++$verified
}
if ($verified -ne 29) {
  throw "Payload manifest count mismatch. Expected=29 Actual=$verified"
}

foreach ($requiredPath in @(
  'patches/330-d3d12-hit-surface-binding-repair-exp22_3.patch',
  'patches/340-d3d12-native-hit-production-composite-exp22_4.patch',
  'scripts/build_exp224.ps1'
)) {
  $full = Join-Path $work $requiredPath
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    throw "Required EXP22.4 build component is missing: $full"
  }
}

Write-Host "EXP22_6_DONOR_SNAPSHOT=PASS COMMIT=$actualDonorCommit SHA256=$actualDonorSha"
Write-Host "EXP22_6_PAYLOAD=PASS SHA256=$actualPayloadSha FILES=$verified"
