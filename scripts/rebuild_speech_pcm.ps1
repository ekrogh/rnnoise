param(
  [string]$GuitarUrls = (Join-Path $PSScriptRoot 'urls_guitar.txt'),
  [string]$NoiseUrls  = (Join-Path $PSScriptRoot 'urls_noise.txt'),
  [string]$GuitarOut  = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/guitar_clean'),
  [string]$NoiseOut   = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/interfere'),
  [switch]$PreferMedleyCsv = $true,
  [string[]]$InstrumentAllowList = @('guitar','electric_guitar','acoustic_guitar'),
  [ValidateSet('Auto','Builtin','Aria2c')][string]$Downloader = 'Builtin',
  [switch]$ForceClean = $true,
  [int]$Threads = 0,
  [switch]$Validate = $true
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Require-Cmd($name) { if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Command '$name' not found in PATH." } }

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repo: $RepoRoot"
Require-Cmd ffmpeg

# 1) Fetch (filtered)
$fetch = Join-Path $PSScriptRoot 'fetch_real_data.ps1'
if (-not (Test-Path $fetch)) { throw "fetch_real_data.ps1 not found at $fetch" }
New-Item -ItemType Directory -Force -Path $GuitarOut | Out-Null
New-Item -ItemType Directory -Force -Path $NoiseOut  | Out-Null

# Optional clean to avoid mixing in stale, unfiltered WAVs
if ($ForceClean) {
  Write-Host "Cleaning existing WAVs in $GuitarOut ..."
  Get-ChildItem $GuitarOut -Recurse -Filter *.wav -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

$fetchParams = @{
  GuitarUrls = $GuitarUrls
  NoiseUrls  = $NoiseUrls
  GuitarOut  = $GuitarOut
  NoiseOut   = $NoiseOut
  Downloader = $Downloader
  PreferMedleyCsv = $PreferMedleyCsv
  InstrumentAllowList = $InstrumentAllowList
  UseParallel = $true
  ParallelJobs = 0
  FfmpegThreadsPerJob = 1
  ValidateBeforeConvert = $true
}
Write-Host ("Running fetch_real_data.ps1 (Downloader={0}) with Medley filtering..." -f $Downloader)
& $fetch @fetchParams

# 2) Rebuild lists
$speechList = Join-Path $RepoRoot 'list_speech.txt'
$noiseList  = Join-Path $RepoRoot 'list_noise.txt'
function Format-ConcatLine([string]$p) {
  $q = $p -replace "'", "\\'"
  "file '$q'"
}
if (Test-Path $speechList) { Remove-Item $speechList -Force -ErrorAction SilentlyContinue }
if (Test-Path $noiseList)  { Remove-Item $noiseList  -Force -ErrorAction SilentlyContinue }
$speechItems = Get-ChildItem $GuitarOut -Recurse -Filter *.wav -File -ErrorAction SilentlyContinue
if ($speechItems -and $speechItems.Count -gt 0) {
  $speechItems | ForEach-Object { Format-ConcatLine $_.FullName } | Set-Content -Encoding UTF8 $speechList
} else {
  throw "No WAVs found for speech list in $GuitarOut"
}
$noiseItems = Get-ChildItem $NoiseOut -Recurse -Filter *.wav -File -ErrorAction SilentlyContinue
if ($noiseItems -and $noiseItems.Count -gt 0) {
  $noiseItems | ForEach-Object { Format-ConcatLine $_.FullName } | Set-Content -Encoding UTF8 $noiseList
}

# 3) Build speech.pcm (48k, mono, s16le)
Push-Location $RepoRoot
try {
  Write-Host "Building speech.pcm ..."
  ffmpeg -y -hide_banner -loglevel error -nostdin -f concat -safe 0 -i $speechList -f s16le -acodec pcm_s16le -ar 48000 -ac 1 .\speech.pcm
} finally { Pop-Location }

# 4) Optional validation
if ($Validate) {
  $pcm = Join-Path $RepoRoot 'speech.pcm'
  if (-not (Test-Path $pcm)) { throw "speech.pcm not found after build." }
  try {
    Require-Cmd ffprobe
    $size = (Get-Item $pcm).Length
    $secs = [math]::Round($size / (2*1*48000), 1)  # bytes / (bytes-per-sample * channels * rate)
    Write-Host ("speech.pcm size={0:N0} bytes (~{1} s @ 48k mono s16)" -f $size, $secs)
  } catch { Write-Host "Validation note: ffprobe not available; basic size check only." }
}

Write-Host "Done. speech.pcm rebuilt with Medley guitar filtering."