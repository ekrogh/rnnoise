<#
Run the RNNoise guitar-preserving training unattended:
- Uses ExecutionPolicy Bypass when invoked by caller
- Unblocks common file types to avoid SmartScreen/MOTW prompts
- Optionally pins CUDA device via env var and passes through to pipeline
- Pipes all output to a timestamped log file in logs/.

Usage (example):
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_unattended_train.ps1 `
    -DataMode Auto -FeatureCount 10000 -Epochs 15 -BatchSize 32 -SequenceLength 1500 `
    -GruSize 256 -CondSize 128 -CudaVisibleDevices '0' -CPUOnly:$false -BuildType Release
#>

param(
  [ValidateSet('Auto','Synthetic','Real')] [string]$DataMode = 'Auto',
  [int]$FeatureCount = 10000,
  [int]$Epochs = 15,
  [int]$BatchSize = 32,
  [int]$SequenceLength = 1500,
  [int]$GruSize = 256,
  [int]$CondSize = 128,
  [string]$BuildType = 'Release',
  [switch]$CPUOnly = $false,
  [string]$CudaVisibleDevices = '0',
  [string]$GuitarDir = '',
  [string]$InterfereDir = '',
  [switch]$FetchFromUrls = $false,
  [string]$TempDownloadDir = '',
  [ValidateSet('All','NoiseOnly')][string]$MusanMode = 'All',
  [double]$ActivityLossWeight = 0.0005,
  [string]$Suffix = '',
  [switch]$UseGuitarActivityLabel = $false,
  [string]$AlbumDirForEval = '',
  [int]$MaxConcatSecondsSpeech = 0,
  [int]$MaxConcatSecondsNoise = 0,
  [switch]$ForceRegenFeatures = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ScriptsDir = $PSScriptRoot
Set-Location $RepoRoot

# Ensure logs directory
$Logs = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
$Log = Join-Path $Logs ("pipeline_${ts}.log")

# Preempt prompts by unblocking common file types
try {
  Get-ChildItem -Path $RepoRoot -Recurse -Include *.ps1,*.psm1,*.psd1,*.exe,*.dll,*.bat,*.py -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
} catch {}

# Set CUDA device if provided
if ($CudaVisibleDevices -ne '') {
  $env:CUDA_VISIBLE_DEVICES = $CudaVisibleDevices
}

Write-Host "Starting training (logging to $Log) ..."

# Build named parameters for pipeline and invoke with splatting to avoid misbinding
$pipe = Join-Path $ScriptsDir 'pipeline_guitar.ps1'
if (-not (Test-Path $pipe)) { throw "pipeline_guitar.ps1 not found at $pipe" }

$p = @{
  DataMode        = $DataMode
  FeatureCount    = $FeatureCount
  Epochs          = $Epochs
  BatchSize       = $BatchSize
  SequenceLength  = $SequenceLength
  GruSize         = $GruSize
  CondSize        = $CondSize
  BuildType       = $BuildType
  CPUOnly         = $CPUOnly
}
if ($CudaVisibleDevices -ne '') { $p['CudaVisibleDevices'] = $CudaVisibleDevices }
if ($DataMode -eq 'Real') {
  if (-not $GuitarDir -or -not $InterfereDir) {
    throw 'When -DataMode Real, provide both -GuitarDir and -InterfereDir.'
  }
  $p['GuitarDir']    = $GuitarDir
  $p['InterfereDir'] = $InterfereDir
}
if ($FetchFromUrls) { $p['FetchFromUrls'] = $true }
if ($TempDownloadDir -and $TempDownloadDir.Trim() -ne '') { $p['TempDownloadDir'] = $TempDownloadDir }
if ($MusanMode) { $p['MusanMode'] = $MusanMode }
if ($ActivityLossWeight -ne $null) { $p['ActivityLossWeight'] = $ActivityLossWeight }
if ($Suffix) { $p['Suffix'] = $Suffix }
if ($UseGuitarActivityLabel) { $p['UseGuitarActivityLabel'] = $true }
if ($AlbumDirForEval) { $p['AlbumDirForEval'] = $AlbumDirForEval }
if ($MaxConcatSecondsSpeech -gt 0) { $p['MaxConcatSecondsSpeech'] = $MaxConcatSecondsSpeech }
if ($MaxConcatSecondsNoise -gt 0) { $p['MaxConcatSecondsNoise'] = $MaxConcatSecondsNoise }
if ($ForceRegenFeatures) { $p['ForceRegenFeatures'] = $true }

# Execute pipeline and tee output to log
& $pipe @p *>&1 | Tee-Object -FilePath $Log -Append

Write-Host "Training finished. See log: $Log"
