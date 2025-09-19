param(
  [int]$FeatureCount = 3000,
  [int]$Epochs = 30,
  [int]$BatchSize = 64,
  [switch]$SkipFetch = $false,
  [string]$GuitarOut = 'E:\rnnoise_data\guitar_clean',
  [string]$NoiseOut  = 'E:\rnnoise_data\interfere',
  [string]$TempDownloadDir = 'E:\rnnoise_cache',
  [string]$GuitarUrls = (Join-Path $PSScriptRoot 'urls_guitar.txt'),
  [string]$NoiseUrls  = (Join-Path $PSScriptRoot 'urls_noise.txt'),
  [switch]$PreferMedleyCsv = $true,
  [string[]]$InstrumentAllowList = @('guitar','electric_guitar','acoustic_guitar'),
  [switch]$UseParallel = $true,
  [int]$ParallelJobs = 6,
  [int]$FfmpegThreadsPerJob = 1,
  [switch]$IgnoreAppleResourceForks = $true,
  [switch]$WriteDatasetSummary = $true,
  [switch]$RunEval = $true,
  [int]$EvalLimit = 4,
  # Gating overrides
  [double]$GateThresh = 0.42,
  [double]$GateMinScale = 0.10,
  [double]$GateScaleExp = 2.0,
  [double]$GateUpDamp = 0.45,
  [double]$GateSmoothAlpha = 0.60,
  # Advanced passthrough (rarely changed here)
  [int]$SequenceLength = 2000,
  [int]$CondSize = 128,
  [int]$GruSize = 256,
  [switch]$CPUOnly = $true,
  [int]$Workers = 0,
  [int]$Threads = 0,
  [int]$MaxConcatSecondsSpeech = 0,
  [int]$MaxConcatSecondsNoise = 0,
  [switch]$ForceRegenFeatures = $false,
  [string]$BuildType = 'Release'
)

<#
train_rnnoise.ps1
One-shot convenience wrapper to:
  1. (Optionally) fetch & filter real guitar + interference datasets to E:\rnnoise_data
  2. Concatenate to speech.pcm / noise.pcm
  3. Dump features (cached) up to FeatureCount
  4. Train PyTorch RNNoise (modified IRM target) for Epochs
  5. Export weights to C, rebuild with GUITAR_ISOLATION_MODE
  6. (Optional) Run isolation evaluation

Usage examples:
  # Default full run (fetch + train + eval)
  pwsh ./scripts/train_rnnoise.ps1

  # Skip fetching (reuse existing WAV corpus) and adjust epochs/gating
  pwsh ./scripts/train_rnnoise.ps1 -SkipFetch -Epochs 50 -GateThresh 0.5 -GateMinScale 0.05

Outputs of interest:
  features.f32
  models/checkpoints/*.pth
  src/rnnoise_data.[ch] (updated)
  build/Release/rnnoise_demo.exe
  eval_metrics.json (if -RunEval)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "[train] Repo root: $RepoRoot"

function Invoke-FetchIfNeeded {
  if ($SkipFetch) { Write-Host '[train] SkipFetch specified; skipping dataset fetch.'; return }
  $need = $false
  if (-not (Test-Path $GuitarOut) -or -not (Get-ChildItem $GuitarOut -Recurse -Filter *.wav -ErrorAction SilentlyContinue)) { $need = $true }
  if (-not (Test-Path $NoiseOut)  -or -not (Get-ChildItem $NoiseOut  -Recurse -Filter *.wav -ErrorAction SilentlyContinue)) { $need = $true }
  if (-not $need) { Write-Host '[train] Existing WAV data found; skipping fetch.'; return }
  Write-Host '[train] Fetching real data (guitar + interference)...'
  $fetch = Join-Path $RepoRoot 'scripts/fetch_real_data.ps1'
  if (-not (Test-Path $fetch)) { throw "fetch_real_data.ps1 not found at $fetch" }
  New-Item -ItemType Directory -Force -Path $GuitarOut | Out-Null
  New-Item -ItemType Directory -Force -Path $NoiseOut  | Out-Null
  $params = @{
    GuitarOut = $GuitarOut; NoiseOut = $NoiseOut; TempDownloadDir = $TempDownloadDir;
    GuitarUrls = $GuitarUrls; NoiseUrls = $NoiseUrls; Downloader = 'Auto'; PreferMedleyCsv = $PreferMedleyCsv;
    InstrumentAllowList = $InstrumentAllowList; UseParallel = $UseParallel; ParallelJobs = $ParallelJobs;
    FfmpegThreadsPerJob = $FfmpegThreadsPerJob; IgnoreAppleResourceForks = $IgnoreAppleResourceForks;
  }
  if ($WriteDatasetSummary) { $params['WriteDatasetSummary'] = $true }
  & pwsh $fetch @params
}

Invoke-FetchIfNeeded

# Export gating env vars (runtime; training not affected but evaluation & demo will use them)
$env:RN_GUITAR_GATE_THRESH = '{0:F3}' -f $GateThresh
$env:RN_GUITAR_MIN_SCALE   = '{0:F3}' -f $GateMinScale
$env:RN_GUITAR_SCALE_EXP   = '{0:F3}' -f $GateScaleExp
$env:RN_GUITAR_UP_DAMP     = '{0:F3}' -f $GateUpDamp
$env:RN_GUITAR_SMOOTH_ALPHA= '{0:F3}' -f $GateSmoothAlpha
Write-Host ("[train] Gating env: thresh={0} min={1} exp={2} up={3} smooth={4}" -f $GateThresh,$GateMinScale,$GateScaleExp,$GateUpDamp,$GateSmoothAlpha)

# Delegate heavy lifting to pipeline script to avoid duplication
$pipeline = Join-Path $RepoRoot 'scripts/pipeline_guitar.ps1'
if (-not (Test-Path $pipeline)) { throw "pipeline_guitar.ps1 not found at $pipeline" }

$pipeArgs = @(
  '-DataMode','Real',
  '-GuitarDir', $GuitarOut,
  '-InterfereDir', $NoiseOut,
  '-FeatureCount', $FeatureCount,
  '-Epochs', $Epochs,
  '-BatchSize', $BatchSize,
  '-SequenceLength', $SequenceLength,
  '-CondSize', $CondSize,
  '-GruSize', $GruSize,
  '-Threads', $Threads,
  '-MaxConcatSecondsSpeech', $MaxConcatSecondsSpeech,
  '-MaxConcatSecondsNoise', $MaxConcatSecondsNoise,
  '-BuildType', $BuildType
)
if ($ForceRegenFeatures) { $pipeArgs += '-ForceRegenFeatures' }
if ($CPUOnly) { $pipeArgs += '-CPUOnly' } else { $pipeArgs += '-CPUOnly:$false' }
$pipeArgs += '-EnableGuitarIsolation'
if ($RunEval) { $pipeArgs += @('-RunEval','-EvalLimit', $EvalLimit) }

Write-Host '[train] Launching pipeline_guitar.ps1 ...'
& pwsh $pipeline @pipeArgs

Write-Host '[train] Completed.'
