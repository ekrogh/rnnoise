param(
  [string]$AlbumDir,
  [string]$BaseDataMode = 'Real',
  [int]$FeatureCount = 8000,
  [int]$Epochs = 8,
  [int]$BatchSize = 32,
  [int]$SequenceLength = 1200,
  [int]$GruSize = 256,
  [int]$CondSize = 128,
  [string]$CudaVisibleDevices = '0',
  [switch]$CPUOnly,
  [string]$BuildType = 'Release',
  [string]$AlbumEvalScript = "$PSScriptRoot/album_eval.ps1",
  [string]$MetricsCsv = "$PSScriptRoot/../build/album_metrics.csv",
  [string]$LogDir = "$PSScriptRoot/../build/auto_opt_logs",
  [switch]$Verbose
)

# Parameter search grids (adjust as needed)
$activityWeights = @(0.0, 0.0005, 0.0015)
$thresholds = @(0.30, 0.40, 0.50)
$minScales = @(0.05, 0.10)
$exponents = @(0.60, 0.80)
$dampings = @(0.85, 0.93)

function Ensure-Dir($d) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
Ensure-Dir $LogDir

$bestScore = -1
$bestConfig = $null
$summaryPath = Join-Path $LogDir 'summary.txt'
"Auto Optimization Run $(Get-Date)" | Out-File $summaryPath -Encoding utf8

$comboCount = 0
foreach ($aw in $activityWeights) { foreach ($th in $thresholds) { foreach ($ms in $minScales) { foreach ($ex in $exponents) { foreach ($dp in $dampings) {
  $comboCount++
  $env:RN_GUITAR_THRESHOLD = $th
  $env:RN_GUITAR_MIN_SCALE = $ms
  $env:RN_GUITAR_EXPONENT = $ex
  $env:RN_GUITAR_DAMPING = $dp
  $env:RN_GUITAR_ACTIVITY_WEIGHT = $aw

  $suffix = "_aw$aw`_th$th`_ms$ms`_ex$ex`_dp$dp"
  $logFile = Join-Path $LogDir "train$suffix.log"
  Write-Host "[$comboCount] Training config $suffix" -ForegroundColor Cyan
  & $PSScriptRoot/run_unattended_train.ps1 -DataMode $BaseDataMode -FeatureCount $FeatureCount -Epochs $Epochs -BatchSize $BatchSize -SequenceLength $SequenceLength -GruSize $GruSize -CondSize $CondSize -CudaVisibleDevices $CudaVisibleDevices -CPUOnly:$CPUOnly -BuildType $BuildType -Suffix $suffix -ActivityLossWeight $aw | Tee-Object -FilePath $logFile | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warning "Training failed for $suffix"; continue }

  # After training assume latest checkpoint integrated into build via run script; run album eval
  if ($AlbumDir) {
    Write-Host "Evaluating album for $suffix" -ForegroundColor Yellow
    & $AlbumEvalScript -AlbumDir $AlbumDir -Verbose:$Verbose
    if ($LASTEXITCODE -ne 0) { Write-Warning "Album eval failed for $suffix"; continue }
    # Extract last composite score from metrics CSV
    if (Test-Path -LiteralPath $MetricsCsv) {
      $lastLine = (Get-Content $MetricsCsv | Select-Object -Last 1)
      if ($lastLine -and $lastLine -notmatch 'composite_score') {
        $parts = $lastLine.Split(',')
        $headers = (Get-Content $MetricsCsv | Select-Object -First 1).Split(',')
        $idx = [array]::IndexOf($headers, 'composite_score')
        if ($idx -ge 0 -and $idx -lt $parts.Length) {
          $score = [double]$parts[$idx]
          "Config $suffix composite_score=$score" | Out-File $summaryPath -Append
          if ($score -gt $bestScore) {
            $bestScore = $score
            $bestConfig = $suffix
            Write-Host "New best score $bestScore with $suffix" -ForegroundColor Green
          }
        }
      }
    }
  }
}}}}}

Write-Host "Optimization complete. Best score=$bestScore config=$bestConfig" -ForegroundColor Magenta
"Best: $bestConfig score=$bestScore" | Out-File $summaryPath -Append
