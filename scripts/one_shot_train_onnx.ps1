<#
 one_shot_train_onnx.ps1

 Purpose:
   Convenience wrapper to ensure a guitar-focused RNNoise ONNX model (`model.onnx`) exists
   for demos/tests (e.g. `eks_rnnoise_demo_onnx`). Can run in a FAST (default) or FULL_TRAIN
   mode depending on environment variables.

 Modes:
   FAST (default)
     - Skips work if `model.onnx` already exists (unless FORCE_TRAIN set)
     - Trains 1 epoch (override with EPOCHS)
     - Output dir: checkpoints/one_shot
   FULL_TRAIN (set env FULL_TRAIN=1)
     - Ignores existing model unless SKIP_IF_PRESENT=1
     - Default epochs: 30 (override with EPOCHS)
     - Enables parity build automatically
     - Output dir: checkpoints/full_<UTC_TIMESTAMP>

 Environment Variables:
   FORCE_TRAIN      : Force retrain even if model exists (overrides SKIP_IF_PRESENT)
   SKIP_IF_PRESENT  : (FULL_TRAIN only) If model exists, skip instead of retrain
   FULL_TRAIN       : Non-empty => engage extended training mode
   EPOCHS           : Override epoch count (FAST default 1, FULL default 30)
   ACTIVITY_LOSS    : Activity loss weight (default 0.0005)
   TRAIN_DIR        : Training package dir (tries rnnoise_train then torch fallback if unset)
   FEATURES_FILE    : Override features file name/path (default features.f32)
   OUTPUT_DIR       : Override output checkpoint directory (both modes)

 Added Artifacts:
   model_meta.json  : Metadata (epochs, timestamp, fullTrain flag, git commit if available)

 Exit Codes:
   0 success / model present
   1 unrecoverable error (missing features or training failure)

 Examples:
   pwsh ./scripts/one_shot_train_onnx.ps1
   $env:FULL_TRAIN=1; pwsh ./scripts/one_shot_train_onnx.ps1
   $env:FULL_TRAIN=1; $env:EPOCHS=50; $env:ACTIVITY_LOSS=0.001; pwsh ./scripts/one_shot_train_onnx.ps1
   Remove-Item Env:FULL_TRAIN, Env:EPOCHS, Env:ACTIVITY_LOSS
 #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
function Timestamp { (Get-Date).ToString('u') }

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
Push-Location $repoRoot

$modelOut = Join-Path $repoRoot 'model.onnx'
$force = [bool]$env:FORCE_TRAIN
$full = [bool]$env:FULL_TRAIN
$skipIfPresent = [bool]$env:SKIP_IF_PRESENT
$modelExists = Test-Path -LiteralPath $modelOut

# FAST mode short-circuit OR FULL mode with skip logic
if($modelExists) {
  if($force) {
    Write-Host "[one-shot] FORCE_TRAIN set -> retraining despite existing model." -ForegroundColor Yellow
  } elseif($full -and $skipIfPresent) {
    Write-Host "[one-shot] FULL_TRAIN with SKIP_IF_PRESENT=1 and model exists -> skipping retrain." -ForegroundColor Green
    Pop-Location; exit 0
  } elseif(-not $full) {
    Write-Host "[one-shot] model.onnx already exists. Set FORCE_TRAIN=1 or FULL_TRAIN=1 to retrain." -ForegroundColor Green
    Pop-Location; exit 0
  } else {
    Write-Host "[one-shot] FULL_TRAIN requested -> retraining existing model." -ForegroundColor Yellow
  }
}

$featuresFile = if($env:FEATURES_FILE) { $env:FEATURES_FILE } else { 'features.f32' }
if(-not (Test-Path $featuresFile)) {
  Write-Host "[one-shot] Missing $featuresFile. Generate features first (see training pipeline)." -ForegroundColor Red
  Pop-Location; exit 1
}

$defaultEpochs = if($full) { 30 } else { 1 }
$epochs = if($env:EPOCHS) { [int]$env:EPOCHS } else { $defaultEpochs }
$actLoss = if($env:ACTIVITY_LOSS) { $env:ACTIVITY_LOSS } else { '0.0005' }
$trainDir = if($env:TRAIN_DIR) { $env:TRAIN_DIR } elseif(Test-Path 'rnnoise_train') { 'rnnoise_train' } elseif(Test-Path 'torch') { 'torch' } else { 'torch' }
$venv = if($env:VENV_PATH) { $env:VENV_PATH } elseif(Test-Path 'D:\venvs\rnnoise_train') { 'D:\venvs\rnnoise_train' } else { Join-Path $repoRoot '.venv_rnnoise_train' }
Write-Host "[one-shot] Using venv path: $venv" -ForegroundColor DarkCyan

Write-Host "[one-shot] Mode=$([string]::Join('', ($full ? 'FULL' : 'FAST'))) epochs=$epochs actLoss=$actLoss trainDir=$trainDir" -ForegroundColor Cyan
if($trainDir -eq 'rnnoise_train' -and -not (Test-Path 'rnnoise_train')) { Write-Host "[one-shot] WARNING: Expected rnnoise_train directory missing; falling back to torch if present." -ForegroundColor Yellow }

$script = Join-Path $repoRoot 'scripts' 'train_export_parity_deploy.ps1'
if(-not (Test-Path $script)) { Write-Host "[one-shot] Cannot find training pipeline script: $script" -ForegroundColor Red; Pop-Location; exit 1 }

# Output directory selection
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
$outputDir = if($env:OUTPUT_DIR) { $env:OUTPUT_DIR } elseif($full) { "checkpoints/full_$timestamp" } else { 'checkpoints/one_shot' }
if(-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

${paramsPipeline} = [ordered]@{
  FeaturesFile = $featuresFile
  OutputDir = $outputDir
  Epochs = $epochs
  ModelOut = 'model.onnx'
  UseGuitarActivityLabel = $true
  AutoInstallDeps = $true
  VenvPath = $venv
  TrainDir = $trainDir
  ActivityLossWeight = [double]$actLoss
}
if($force -or $full){ $paramsPipeline.RunParity = $true }
if([bool]$env:USE_GPU){ $paramsPipeline.PreferGPU = $true }

$argString = ($paramsPipeline.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
Write-Host "[one-shot] Invoking pipeline (splat): & $script $argString" -ForegroundColor DarkGray
& $script @paramsPipeline
if($LASTEXITCODE -ne 0) { Write-Host "[one-shot] Training pipeline failed (exit $LASTEXITCODE)." -ForegroundColor Red; Pop-Location; exit 1 }

if(Test-Path $modelOut) {
  Write-Host "[one-shot] model.onnx ready." -ForegroundColor Green
  # Build metadata JSON
  $gitHash = $null
  try {
    $gitHash = (git rev-parse HEAD 2>$null).Trim()
  } catch { }
  if(-not $gitHash) { $gitHash = 'unknown' }
  $meta = [ordered]@{
    timestampUtc = (Get-Date).ToUniversalTime().ToString('u')
    fullTrain    = $full
    epochs       = $epochs
    activityLoss = $actLoss
    outputDir    = $outputDir
    modelPath    = $modelOut
    gitCommit    = $gitHash
    featuresFile = (Resolve-Path -Path $featuresFile).Path
    cudaRequested = [bool]$env:USE_GPU
  }
  $metaJsonPath = Join-Path $repoRoot 'model_meta.json'
  $meta | ConvertTo-Json -Depth 3 | Out-File $metaJsonPath -Encoding UTF8
  Write-Host "[one-shot] Wrote metadata -> $metaJsonPath" -ForegroundColor DarkCyan
  Pop-Location; exit 0
} else {
  Write-Host "[one-shot] model.onnx not produced." -ForegroundColor Red
  Pop-Location; exit 1
}
