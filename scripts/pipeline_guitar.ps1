<#
Train RNNoise to pass guitar and suppress other sounds (with optional real-data fetch, duration filtering, summaries, and feature caching).

Examples
- Synthetic (auto):
    .\pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64
- Real data (use your WAV folders):
    .\pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100

Notes
- Requires ffmpeg and CMake in PATH.
- Defaults to CPU-only Torch; pass -CPUOnly:$false to try CUDA if available.
- DataMode:
  Auto (default): use data/guitar_clean & data/interfere if WAVs exist, otherwise synthesize.
  Synthetic: always synthesize a small set into data/guitar_clean and data/interfere.
  Real: use -GuitarDir and -InterfereDir (any WAVs; resampled to 48 kHz mono).
- Optional real-data fetching: -FetchFromUrls will call fetch_real_data.ps1 with pass-through parameters:
  -Downloader Auto|Builtin|Aria2c
  -ShowDownloadProgress
  -MinSeconds / -MaxSeconds
  -WriteDatasetSummary
  -IgnoreAppleResourceForks
  -PerFileSkipWarnings
- Feature caching: skips dumping features if speech.pcm/noise.pcm + FeatureCount signature unchanged (override with -ForceRegenFeatures).
- Artifacts:
  features.f32
  models/checkpoints
  models/c/rnnoise_data.[ch] (copied into src/)
  build/Release/* (rnnoise library + rnnoise_demo.exe)
#>

param(
  [string]$VenvPath = "D:\venvs\rnnoise312",
  [int]$FeatureCount = 5000,
  [int]$Epochs = 100,
  [int]$BatchSize = 64,
  [int]$SequenceLength = 2000,
  [int]$Workers = 0,
  [string]$CudaVisibleDevices = '',
  [int]$CondSize = 128,
  [int]$GruSize = 256,
  [string]$BuildType = "Release",
  [switch]$SkipSynth = $false,
  [switch]$CPUOnly = $true,
  [ValidateSet('Auto','Synthetic','Real')] [string]$DataMode = 'Auto',
  [string]$GuitarDir = '',
  [string]$InterfereDir = '',
  [switch]$FetchFromUrls = $false,
  [string]$GuitarUrls = (Join-Path $PSScriptRoot 'urls_guitar.txt'),
  [string]$NoiseUrls = (Join-Path $PSScriptRoot 'urls_noise.txt'),
  [switch]$AllowInsecure = $false,
  # Medley-solos-DB filtering passthrough
  [switch]$PreferMedleyCsv = $true,
  [string[]]$InstrumentAllowList = @('guitar','electric_guitar','acoustic_guitar'),
  [switch]$UseParallel = $true,
  [int]$ParallelJobs = 0,
  [int]$FfmpegThreadsPerJob = 1,
  [switch]$ValidateBeforeConvert = $false,
  # Pass-through download/convert tuning for fetch_real_data.ps1
  [ValidateSet('Auto','Builtin','Aria2c')][string]$Downloader = 'Auto',
  [switch]$ShowDownloadProgress = $false,
  [double]$MinSeconds = 0,
  [double]$MaxSeconds = 0,
  [switch]$WriteDatasetSummary = $false,
  [switch]$IgnoreAppleResourceForks = $true,
  [switch]$PerFileSkipWarnings = $false,
  [int]$Threads = 0,
  [int]$MaxConcatSecondsSpeech = 0,
  [int]$MaxConcatSecondsNoise = 0,
  [switch]$ForceRegenFeatures = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repo root: $RepoRoot"

Write-Host "--- Usage / Optional args ---"
Write-Host "  Synthetic (auto):  pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64"
Write-Host "  Real data:         pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100"
Write-Host "Notes:"
Write-Host "  - Requires ffmpeg and CMake in PATH."
Write-Host "  - Defaults to CPU-only Torch; pass -CPUOnly:`$false to try CUDA."
Write-Host "  - GPU tuning: use -BatchSize, -SequenceLength, -GruSize, and -CondSize to fit VRAM."
Write-Host "  - DataMode: Auto|Synthetic|Real (see header)."
Write-Host "  - Optional fetch: -FetchFromUrls to download from URL lists before training."
Write-Host "Artifacts:"
Write-Host "  - features: features.f32"
Write-Host "  - checkpoints: models/checkpoints"
Write-Host "  - exported C weights copied to src/rnnoise_data.[ch]"
Write-Host "  - binaries in build/Release"

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Command '$name' not found in PATH. Please install it."
  }
}

# 1) Ensure venv exists and get python path
if (-not (Test-Path (Join-Path $VenvPath 'Scripts/python.exe'))) {
  Write-Host "Creating venv at $VenvPath"
  python -m venv $VenvPath
}
$Py = Join-Path $VenvPath 'Scripts/python.exe'
Write-Host "Using Python: $Py"

# 2) Pip setup and deps
& $Py -m pip install --upgrade pip
try { & $Py -m pip config set global.cache-dir "D:/pip-cache" | Out-Null } catch {}
& $Py -m pip install numpy soundfile tqdm
if ($CPUOnly) {
  & $Py -m pip install --upgrade torch --index-url https://download.pytorch.org/whl/cpu
} else {
  # If this venv already has CUDA-enabled torch, skip reinstall; otherwise install cu121 wheel.
  $cudaProbeCode = @'
import sys
try:
    import torch
    sys.stdout.write("1" if torch.cuda.is_available() else "0")
except Exception:
    sys.stdout.write("0")
'@
  $cudaProbe = & $Py -c $cudaProbeCode
  if ($cudaProbe -eq '1') {
    Write-Host "CUDA-enabled torch already available; skipping reinstall."
  } else {
    & $Py -m pip install --upgrade torch --index-url https://download.pytorch.org/whl/cu121
  }
}

# Resolve input data strategy
$DefaultGuitar = Join-Path $RepoRoot 'data/guitar_clean'
$DefaultNoise  = Join-Path $RepoRoot 'data/interfere'

$UseSynth = $false
if ($DataMode -eq 'Real' -or ($GuitarDir -ne '' -or $InterfereDir -ne '')) {
  if ($GuitarDir -eq '' -or $InterfereDir -eq '') { throw "When -DataMode Real, provide both -GuitarDir and -InterfereDir." }
  $GuitarIn = $GuitarDir
  $NoiseIn  = $InterfereDir
  $UseSynth = $false
} elseif ($DataMode -eq 'Synthetic') {
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
  $UseSynth = $true
} else { # Auto
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
  $hasGuitar = (Test-Path $GuitarIn) -and (Get-ChildItem $GuitarIn -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
  $hasNoise  = (Test-Path $NoiseIn)  -and (Get-ChildItem $NoiseIn  -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
  $UseSynth = -not ($hasGuitar -and $hasNoise)
}

# 3) Optional: synthesize small dataset (unless explicitly skipped)
if ($UseSynth -and -not $SkipSynth) {
  Write-Host "Synthesizing guitar/interference WAVs into $DefaultGuitar and $DefaultNoise..."
  & $Py (Join-Path $RepoRoot 'scripts/synthesize_guitar_data.py')
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
}

if (-not (Test-Path $GuitarIn)) { throw "GuitarDir not found: $GuitarIn" }
if (-not (Test-Path $NoiseIn))  { throw "InterfereDir not found: $NoiseIn" }

#
# Set-PSDebug -Trace 1
# or for more detail:
# Set-PSDebug -Trace 2

# Optional: fetch real data from URL lists (runs before concat), targeting the chosen dirs
if ($FetchFromUrls) {
  Write-Host "Fetching real audio using URL lists..."
  $fetchPs1 = Join-Path $RepoRoot 'scripts/fetch_real_data.ps1'
  if (-not (Test-Path $fetchPs1)) { throw "fetch_real_data.ps1 not found at $fetchPs1" }
  New-Item -ItemType Directory -Force -Path $GuitarIn | Out-Null
  New-Item -ItemType Directory -Force -Path $NoiseIn  | Out-Null
  $fetchParams = @{
    GuitarUrls = $GuitarUrls
    NoiseUrls  = $NoiseUrls
    GuitarOut  = $GuitarIn
    NoiseOut   = $NoiseIn
    Downloader = $Downloader
    MinSeconds = $MinSeconds
    MaxSeconds = $MaxSeconds
  }
  # Prefer Medley CSV instrument filtering and parallel conversion when available
  if ($PreferMedleyCsv) { $fetchParams['PreferMedleyCsv'] = $true }
  if ($InstrumentAllowList -and $InstrumentAllowList.Count -gt 0) { $fetchParams['InstrumentAllowList'] = $InstrumentAllowList }
  if ($UseParallel) { $fetchParams['UseParallel'] = $true }
  if ($ParallelJobs -gt 0) { $fetchParams['ParallelJobs'] = $ParallelJobs }
  if ($FfmpegThreadsPerJob -gt 0) { $fetchParams['FfmpegThreadsPerJob'] = $FfmpegThreadsPerJob }
  if ($ValidateBeforeConvert) { $fetchParams['ValidateBeforeConvert'] = $true }
  if ($AllowInsecure) { $fetchParams['AllowInsecure'] = $true }
  if ($IgnoreAppleResourceForks) { $fetchParams['IgnoreAppleResourceForks'] = $true }
  if ($PerFileSkipWarnings) { $fetchParams['PerFileSkipWarnings'] = $true }
  if ($ShowDownloadProgress) { $fetchParams['ShowDownloadProgress'] = $true }
  if ($WriteDatasetSummary) { $fetchParams['WriteDatasetSummary'] = $true }
  Write-Host ("fetch_real_data.ps1 param summary: " + ($fetchParams.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value } | Sort-Object | Out-String).Trim())
  & $fetchPs1 @fetchParams
}

# Set-PSDebug -Off

# 4) Concatenate to PCM streams with ffmpeg
Require-Cmd ffmpeg
Push-Location $RepoRoot
try {
  $speechList = Join-Path $RepoRoot 'list_speech.txt'
  $noiseList  = Join-Path $RepoRoot 'list_noise.txt'
  function Format-ConcatLine([string]$p) {
    # Escape single quotes for ffmpeg concat demuxer
    $q = $p -replace "'", "\\'"
    return "file '$q'"
  }
  Get-ChildItem $GuitarIn -Recurse -Filter *.wav |
    ForEach-Object { Format-ConcatLine $_.FullName } |
    Set-Content -Encoding UTF8 $speechList
  Get-ChildItem $NoiseIn  -Recurse -Filter *.wav |
    ForEach-Object { Format-ConcatLine $_.FullName } |
    Set-Content -Encoding UTF8 $noiseList

  if (-not (Test-Path $speechList) -or -not (Get-Content $speechList)) { throw "No WAVs in $GuitarIn." }
  if (-not (Test-Path $noiseList)  -or -not (Get-Content $noiseList))  { throw "No WAVs in $NoiseIn." }

  $ffCommon = @('-hide_banner','-loglevel','error','-nostdin')
  $ffThreads = @(); if ($Threads -ge 0) { $ffThreads = @('-threads', "$Threads") }
  Write-Host "Building speech.pcm ..."
  $speechArgs = @('-y','-f','concat','-safe','0','-i', $speechList) + $ffCommon
  if ($MaxConcatSecondsSpeech -gt 0) { $speechArgs += @('-t', "$MaxConcatSecondsSpeech") }
  $speechArgs += @('-f','s16le','-acodec','pcm_s16le','-ar','48000','-ac','1') + $ffThreads + @('.\speech.pcm')
  ffmpeg @speechArgs | Out-Null
  Write-Host "Building noise.pcm ..."
  $noiseArgs = @('-y','-f','concat','-safe','0','-i', $noiseList) + $ffCommon
  if ($MaxConcatSecondsNoise -gt 0) { $noiseArgs += @('-t', "$MaxConcatSecondsNoise") }
  $noiseArgs += @('-f','s16le','-acodec','pcm_s16le','-ar','48000','-ac','1') + $ffThreads + @('.\noise.pcm')
  ffmpeg @noiseArgs | Out-Null
}
finally { Pop-Location }

# 5) Build dump_features tool
$BuildDir = Join-Path $RepoRoot 'build'
Write-Host "Configuring CMake with tools and examples..."
cmake -S $RepoRoot -B $BuildDir -DBUILD_TOOLS=ON -DBUILD_EXAMPLES=ON -DCMAKE_BUILD_TYPE=$BuildType | Out-Null
Write-Host "Building dump_features..."
cmake --build $BuildDir --config $BuildType --target dump_features | Out-Null

$DumpExe = Join-Path $BuildDir (Join-Path $BuildType 'dump_features.exe')
if (-not (Test-Path $DumpExe)) { $DumpExe = Join-Path $BuildDir 'dump_features.exe' }
if (-not (Test-Path $DumpExe)) { throw "dump_features.exe not found after build." }

# 6) Dump features
Push-Location $RepoRoot
try {
  $featCache = Join-Path $RepoRoot 'features.cache.json'
  function Get-DataSignature {
    param([string]$speechPcm,[string]$noisePcm,[int]$featureCount)
    $items = @()
    foreach ($p in @($speechPcm,$noisePcm)) {
      if (Test-Path $p) {
        $fi = Get-Item $p
        $items += "$($fi.FullName)|$($fi.Length)|$($fi.LastWriteTimeUtc.ToFileTimeUtc())"
      } else {
        $items += "$p|missing"
      }
    }
    $items += "FeatureCount=$featureCount"
    $concat = ($items -join ';')
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($concat)
    $hash = $sha256.ComputeHash($bytes)
    -join ($hash | ForEach-Object { $_.ToString('x2') })
  }
  $sig = Get-DataSignature -speechPcm (Join-Path $RepoRoot 'speech.pcm') -noisePcm (Join-Path $RepoRoot 'noise.pcm') -featureCount $FeatureCount
  $prevSig = $null
  if (-not $ForceRegenFeatures -and (Test-Path $featCache)) {
    try { $prev = Get-Content $featCache -Raw | ConvertFrom-Json; $prevSig = $prev.signature } catch {}
  }
  if (-not $ForceRegenFeatures -and $prevSig -and $prevSig -eq $sig -and (Test-Path (Join-Path $RepoRoot 'features.f32'))) {
    Write-Host "Skipping feature dump (cache hit). Use -ForceRegenFeatures to override." 
  } else {
    Write-Host "Dumping features ($FeatureCount sequences)..."
    & $DumpExe .\speech.pcm .\noise.pcm .\features.f32 $FeatureCount
    $cacheObj = [pscustomobject]@{ signature=$sig; feature_count=$FeatureCount; generated_utc=(Get-Date).ToUniversalTime().ToString('o') }
    $cacheObj | ConvertTo-Json -Depth 5 | Out-File -FilePath $featCache -Encoding UTF8
  }
}
finally { Pop-Location }

# 7) Train model (PyTorch)
$ModelsDir = Join-Path $RepoRoot 'models'
Write-Host "Training PyTorch model for $Epochs epochs..."
$trainArgs = @()
$trainArgs += @((Join-Path $RepoRoot 'torch/rnnoise/train_rnnoise.py'))
$trainArgs += @((Join-Path $RepoRoot 'features.f32'))
$trainArgs += @($ModelsDir)
$trainArgs += @('--epochs', "$Epochs", '--batch-size', "$BatchSize")
if ($SequenceLength -gt 0) { $trainArgs += @('--sequence-length', "$SequenceLength") }
if ($Workers -ge 0) { $trainArgs += @('--workers', "$Workers") }
if ($CondSize -gt 0) { $trainArgs += @('--cond-size', "$CondSize") }
if ($GruSize -gt 0) { $trainArgs += @('--gru-size', "$GruSize") }
if ($CudaVisibleDevices -ne '') { $trainArgs += @('--cuda-visible-devices', $CudaVisibleDevices) }
& $Py @trainArgs

# 8) Export weights to C and rebuild rnnoise
$Checkpoint = Join-Path $ModelsDir (Join-Path 'checkpoints' ("rnnoise_{0}.pth" -f $Epochs))
if (-not (Test-Path $Checkpoint)) {
  # try latest checkpoint if exact epoch file not found
  $latest = Get-ChildItem (Join-Path $ModelsDir 'checkpoints') -Filter 'rnnoise_*.pth' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { $Checkpoint = $latest.FullName }
}
if (-not (Test-Path $Checkpoint)) { throw "Checkpoint not found in $ModelsDir/checkpoints." }

$COut = Join-Path $ModelsDir 'c'
& $Py (Join-Path $RepoRoot 'torch/rnnoise/dump_rnnoise_weights.py') $Checkpoint $COut --quantize

Copy-Item (Join-Path $COut 'rnnoise_data.*') (Join-Path $RepoRoot 'src') -Force

Write-Host "Building rnnoise library with new weights..."
cmake --build $BuildDir --config $BuildType --target rnnoise | Out-Null

# 9) Build example CLI (rnnoise_demo)
Write-Host "Building rnnoise_demo example..."
cmake --build $BuildDir --config $BuildType --target rnnoise_demo | Out-Null

Write-Host "All done. Outputs:"
Write-Host " - features: $RepoRoot\features.f32"
Write-Host " - checkpoints: $ModelsDir\checkpoints"
Write-Host " - C weights: $COut\rnnoise_data.[ch] copied into src/"
Write-Host " - built binaries in: $BuildDir\$BuildType (includes rnnoise_demo.exe)"
