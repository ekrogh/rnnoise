param(
  [Parameter(Mandatory=$true)][string]$AlbumDir,
  [string]$GuitarDir = '',
  [string]$InterfereDir = '',
  [int]$MaxIterations = 5,
  [int]$BaseFeatureCount = 8000,
  [int]$BaseEpochs = 10,
  [int]$BatchSize = 48,
  [int]$SequenceLength = 1400,
  [int]$GruSize = 256,
  [int]$CondSize = 128,
  [double]$InitActivityWeight = 0.0005,
  [double]$ActivityWeightScale = 1.6,
  [double]$MinImprovement = 0.002,
  [string]$BuildType = 'Release',
  [switch]$CPUOnly,
  [string]$CudaVisibleDevices = '0',
  [string]$WorkLogDir = "$PSScriptRoot/../build/refine_logs",
  [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $WorkLogDir)) { New-Item -ItemType Directory -Force -Path $WorkLogDir | Out-Null }

function Get-CompositeScoreFromCsv($csvPath) {
  if (-not (Test-Path $csvPath)) { return $null }
  $lines = Get-Content $csvPath
  if ($lines.Count -lt 2) { return $null }
  $header = $lines[0].Split(',')
  $idx = [Array]::IndexOf($header, 'composite_score')
  if ($idx -lt 0) { return $null }
  $last = $lines[-1].Split(',')
  if ($last.Length -le $idx) { return $null }
  try { return [double]$last[$idx] } catch { return $null }
}

$metricsCsv = Join-Path $RepoRoot 'build/album_metrics.csv'
if (Test-Path $metricsCsv) { Remove-Item $metricsCsv -Force }

$activityWeight = $InitActivityWeight
$bestScore = -1
$bestConfig = $null

for ($iter = 1; $iter -le $MaxIterations; $iter++) {
  Write-Host "[iterate] Iteration $iter / $MaxIterations (activityWeight=$activityWeight)" -ForegroundColor Cyan
  $suffix = "iter${iter}_aw$([string]::Format('{0:0.5}', $activityWeight).Replace('.','p'))"
  $trainCmd = @{
    DataMode = 'Real'
    GuitarDir = $GuitarDir
    InterfereDir = $InterfereDir
    FeatureCount = $BaseFeatureCount
    Epochs = $BaseEpochs
    BatchSize = $BatchSize
    SequenceLength = $SequenceLength
    GruSize = $GruSize
    CondSize = $CondSize
    BuildType = $BuildType
    CPUOnly = $CPUOnly
    CudaVisibleDevices = $CudaVisibleDevices
    ActivityLossWeight = $activityWeight
    Suffix = $suffix
  }
  $runScript = Join-Path $RepoRoot 'scripts/run_unattended_train.ps1'
  & $runScript @trainCmd | Tee-Object -FilePath (Join-Path $WorkLogDir "train_${suffix}.log") | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warning "Training failed at iteration $iter"; break }

  # Album evaluation
  $albumEval = Join-Path $RepoRoot 'scripts/album_eval.ps1'
  & $albumEval -AlbumDir $AlbumDir -Verbose:$Verbose | Tee-Object -FilePath (Join-Path $WorkLogDir "eval_${suffix}.log") | Out-Null
  $score = Get-CompositeScoreFromCsv $metricsCsv
  if ($score -eq $null) { Write-Warning "No composite score captured; stopping."; break }
  Write-Host "[iterate] Iter $iter composite_score=$score (best=$bestScore)" -ForegroundColor Yellow

  if ($score -gt $bestScore + $MinImprovement) {
    $bestScore = $score
    $bestConfig = @{ iteration=$iter; activityWeight=$activityWeight; suffix=$suffix }
    Write-Host "[iterate] New best score $bestScore" -ForegroundColor Green
    # Increase activity weight cautiously
    $activityWeight = [Math]::Min($activityWeight * $ActivityWeightScale, 0.01)
  } else {
    # small or no improvement: slightly reduce weight to avoid overfitting probability head
    $activityWeight = [Math]::Max($activityWeight / 1.4, 0.0001)
  }
}

if ($bestConfig) {
  $summary = "Best iteration=$($bestConfig.iteration) score=$bestScore activityWeight=$($bestConfig.activityWeight) suffix=$($bestConfig.suffix)"
  $summary | Out-File (Join-Path $WorkLogDir 'summary.txt')
  Write-Host "[iterate] Completed. $summary" -ForegroundColor Magenta
} else {
  Write-Host "[iterate] Completed with no successful improvement cycles." -ForegroundColor Magenta
}
