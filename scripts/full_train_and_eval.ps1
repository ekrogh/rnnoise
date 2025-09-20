[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GuitarDir,
  [Parameter(Mandatory=$true)][string]$InterfereDir,
  [Parameter(Mandatory=$true)][string]$AlbumDir,
  [int]$FeatureCount = 120000,
  [int]$Epochs = 30,
  [int]$BatchSize = 48,
  [int]$SequenceLength = 1500,
  [int]$GruSize = 256,
  [int]$CondSize = 128,
  [float]$ActivityLossWeight = 0.7,
  [switch]$UseCuda,
  [string]$BuildType = 'Release',
  [switch]$IncludeWav,
  [switch]$VerboseEval
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..')
$trainScript = Join-Path $scriptRoot 'run_unattended_train.ps1'
$albumEval = Join-Path $scriptRoot 'album_eval.ps1'

if (-not (Test-Path $trainScript)) { throw "Training script not found: $trainScript" }
if (-not (Test-Path $albumEval)) { throw "Album eval script not found: $albumEval" }

Write-Host "[full-train] Starting full training pipeline..." -ForegroundColor Cyan

$cpuOnly = $true
if ($UseCuda) { $cpuOnly = $false }

$trainParams = @(
  '-DataMode','Real',
  '-GuitarDir', $GuitarDir,
  '-InterfereDir', $InterfereDir,
  '-FeatureCount', $FeatureCount,
  '-Epochs', $Epochs,
  '-BatchSize', $BatchSize,
  '-SequenceLength', $SequenceLength,
  '-GruSize', $GruSize,
  '-CondSize', $CondSize,
  '-UseGuitarActivityLabel',
  '-ActivityLossWeight', $ActivityLossWeight,
  '-BuildType', $BuildType,
  '-Suffix', "full_run_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)
if (-not $cpuOnly) { $trainParams += @('-CPUOnly:$false','-CudaVisibleDevices','0') } else { $trainParams += '-CPUOnly:$true' }

pwsh -NoProfile -ExecutionPolicy Bypass -File $trainScript @trainParams
if ($LASTEXITCODE -ne 0) { throw "Training failed (exit $LASTEXITCODE)" }

Write-Host "[full-train] Training finished successfully." -ForegroundColor Green

Write-Host "[full-train] Running album evaluation..." -ForegroundColor Cyan
$evalParams = @('-AlbumDir', $AlbumDir)
if ($IncludeWav) { $evalParams += '-IncludeWav' }
if ($VerboseEval) { $evalParams += '-Verbose' }

pwsh -NoProfile -ExecutionPolicy Bypass -File $albumEval @evalParams
if ($LASTEXITCODE -ne 0) { throw "Album evaluation failed (exit $LASTEXITCODE)" }

Write-Host "[full-train] Complete. Metrics at build/album_metrics.csv" -ForegroundColor Cyan
