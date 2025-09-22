param(
  [string]$InAudio = "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\01 Riding With The King.mp3",
  [string]$OutWav = ".\processed\01_Riding_With_The_King_guitar.wav",
  [string]$Model = 'model.onnx',
  [ValidateSet('Debug','Release')] [string]$BuildType = 'Release',
  [switch]$GuitarOnly = $true,
  [double]$GuitarThreshold = 0.55,
  [double]$GuitarAttenDB = -40,
  [double]$ProbFloor = 0.0,
  [double]$EnergyThreshold = 0.0,
  [double]$MinScale = 0.0,
  [string]$DumpProbCsv = '',
  # Adaptive gating parameters (dynamic threshold based on EMA probability)
  [double]$AdaptiveFactor = 1.35,
  [double]$EmaAlpha = 0.15,
  # Additional convenience / diagnostics
  [switch]$BaselineAlso,          # produce a baseline (no gating) output alongside gated
  [switch]$Diagnostics,           # verbose gating-friendly settings (CSV auto if not supplied)
  [switch]$AutoName,              # auto-generate output name(s) based on input & params
  [switch]$ForceRebuild,          # pass through to underlying wav script
  [switch]$Aggressive,            # stronger isolation preset
  [switch]$Ultra,                 # very strong isolation preset (may degrade guitar)
  [switch]$ForceSafeDefaults,
  [switch]$AutoTighten,           # iteratively re-run escalating isolation until criteria met
  [int]$MaxPasses = 6,            # max tightening iterations
  [double]$TargetInactiveMedianScale = 0.25, # desired median scale for inactive frames
  [double]$TargetInactiveMeanScale = 0.35,   # fallback mean-based stop
  [double]$EscalateThresholdStep = 0.05,     # increment threshold each pass
  [double]$EscalateAttenStepDB = -5,         # additional attenuation (negative number)
  [double]$MinAttenDB = -70,                 # clamp maximum attenuation
  [double]$MaxThreshold = 0.90,              # clamp threshold
  # Autonomous isolation (higher-level success criteria)
  [switch]$AutoIsolate,                      # implies AutoTighten with richer success metrics
  [double]$TargetActivePctMin = 0.15,        # acceptable lower bound fraction (0-1) of active frames
  [double]$TargetActivePctMax = 0.65,        # acceptable upper bound fraction (0-1) of active frames
  [double]$MinActiveInactiveScaleGap = 0.35, # required (meanActiveScale - meanInactiveScale)
  [double]$MinProbGap = 0.25                 # required (avgProbActive - avgProbInactive)
  , [int]$DebugFirstN = 0                     # instrumentation: dump first N prob frames
  , [double]$ForceThreshold = -1              # instrumentation: force threshold value (0-1) if >=0
  , [switch]$DumpProbHist                     # instrumentation: print probability histogram
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rnnoiseWav = Join-Path $scriptDir 'rnnoise_wav.ps1'
if (-not (Test-Path -LiteralPath $rnnoiseWav)) { throw "rnnoise_wav.ps1 not found at $rnnoiseWav" }

Write-Host "[mp32wav2rnnoise] Processing $InAudio -> $OutWav using model $Model (GuitarOnly=$GuitarOnly Threshold=$GuitarThreshold AttenDB=$GuitarAttenDB)"
if (-not (Test-Path -LiteralPath $InAudio)) {
  Write-Error "[mp32wav2rnnoise] Input audio not found: $InAudio" -ErrorAction Stop
}
if (-not (Test-Path -LiteralPath $Model)) {
  Write-Error "[mp32wav2rnnoise] Model file not found: $Model" -ErrorAction Stop
}
 # Ensure output directory exists early
$outDir = Split-Path -Path $OutWav -Parent
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Auto-name logic (before safe defaults) if requested
if ($AutoName) {
  $inBase = [IO.Path]::GetFileNameWithoutExtension($InAudio)
  if ([string]::IsNullOrWhiteSpace($inBase)) { $inBase = 'input' }
  $tag = if ($GuitarOnly) { 'guitar' } else { 'baseline' }
  $OutWav = Join-Path ($outDir ? $outDir : '.') ("{0}_{1}.wav" -f $inBase, $tag)
  if ($DumpProbCsv) { } elseif ($GuitarOnly) { $DumpProbCsv = Join-Path ($outDir ? $outDir : '.') ("{0}_gating.csv" -f $inBase) }
  Write-Host "[mp32wav2rnnoise] AutoName resolved OutWav=$OutWav DumpProbCsv=$DumpProbCsv"
}

# Diagnostics mode tweaks (if gating enabled)
if ($Diagnostics -and $GuitarOnly) {
  if (-not $DumpProbCsv) { $DumpProbCsv = (Join-Path ($outDir ? $outDir : '.') 'gating_diag.csv') }
  if ($ProbFloor -le 0) { $ProbFloor = 0.05 }
  if ($MinScale -le 0) { $MinScale = 0.05 }
  Write-Host "[mp32wav2rnnoise] Diagnostics mode: enabling CSV + gentle safety floors." -ForegroundColor Cyan
}

# Apply preset overrides (processed after diagnostics & before ForceSafeDefaults so safe defaults can still clamp floor values)
if ($GuitarOnly) {
  if ($Ultra) { $Aggressive = $true }
  if ($Aggressive) {
    # Base aggressive adjustments (raise threshold, attenuation, floors)
    if ($GuitarThreshold -lt 0.6) { $GuitarThreshold = 0.60 }
    if ($GuitarAttenDB -gt -50) { $GuitarAttenDB = -50 }
    if ($ProbFloor -lt 0.06) { $ProbFloor = 0.06 }
    if ($MinScale -lt 0.04) { $MinScale = 0.04 }
    if ($AdaptiveFactor -lt 1.35) { $AdaptiveFactor = 1.35 }
  }
  if ($Ultra) {
    # More extreme suppression
    if ($GuitarThreshold -lt 0.68) { $GuitarThreshold = 0.68 }
    if ($GuitarAttenDB -gt -60) { $GuitarAttenDB = -60 }
    if ($ProbFloor -lt 0.08) { $ProbFloor = 0.08 }
    if ($MinScale -lt 0.035) { $MinScale = 0.035 }
    if ($AdaptiveFactor -lt 1.45) { $AdaptiveFactor = 1.45 }
    if ($EnergyThreshold -lt 350) { $EnergyThreshold = 350 }
  }
  if ($Aggressive -or $Ultra) {
    Write-Host ("[mp32wav2rnnoise] Preset Applied => Threshold={0} AttenDB={1} ProbFloor={2} MinScale={3} AdaptiveFactor={4} EnergyThreshold={5}" -f $GuitarThreshold,$GuitarAttenDB,$ProbFloor,$MinScale,$AdaptiveFactor,$EnergyThreshold) -ForegroundColor Magenta
  }
}
if ($GuitarOnly -and $ForceSafeDefaults) {
  if ($ProbFloor -le 0) { $ProbFloor = 0.10 }
  if ($MinScale -le 0) { $MinScale = 0.05 }
  if ($EnergyThreshold -le 0) { $EnergyThreshold = 400 }
  if ($AdaptiveFactor -le 0) { $AdaptiveFactor = 1.35 }
  if ($EmaAlpha -le 0 -or $EmaAlpha -gt 1) { $EmaAlpha = 0.15 }
  Write-Host "[mp32wav2rnnoise] Safe defaults applied: ProbFloor=$ProbFloor MinScale=$MinScale EnergyThreshold=$EnergyThreshold" -ForegroundColor Yellow
}
# Additional silence mitigation: if still zero safety floors, nudge them lightly
if ($GuitarOnly -and $ProbFloor -le 0 -and $MinScale -le 0) {
  $ProbFloor = 0.04; $MinScale = 0.04
  Write-Host "[mp32wav2rnnoise] Applied low-level safety floors ProbFloor=0.04 MinScale=0.04 to avoid hard silence." -ForegroundColor DarkYellow
}
$args = @('-InWav', $InAudio, '-OutWav', $OutWav, '-Model', $Model, '-BuildType', $BuildType)
if ($GuitarOnly) {
  $args += @('-GuitarOnly', '-GuitarThreshold', $GuitarThreshold, '-GuitarAttenDB', $GuitarAttenDB)
  if ($ProbFloor -gt 0) { $args += @('-ProbFloor', $ProbFloor) }
  if ($EnergyThreshold -gt 0) { $args += @('-EnergyThreshold', $EnergyThreshold) }
  if ($MinScale -gt 0) { $args += @('-MinScale', $MinScale) }
  if ($DumpProbCsv) { $args += @('-DumpProbCsv', $DumpProbCsv) }
  if ($AdaptiveFactor -gt 0) { $args += @('-AdaptiveFactor', $AdaptiveFactor) }
  if ($EmaAlpha -gt 0 -and $EmaAlpha -le 1) { $args += @('-EmaAlpha', $EmaAlpha) }
  if ($DebugFirstN -gt 0) { $args += @('-DebugFirstN', $DebugFirstN) }
  if ($ForceThreshold -ge 0 -and $ForceThreshold -le 1) { $args += @('-ForceThreshold', $ForceThreshold) }
  if ($DumpProbHist) { $args += '-DumpProbHist' }
}
if ($ForceRebuild) { $args += '-ForceRebuild' }
pwsh -NoProfile -ExecutionPolicy Bypass -File $rnnoiseWav @args

if ( ($AutoTighten -or $AutoIsolate) -and $GuitarOnly) {
  if (-not $DumpProbCsv) {
    # Need diagnostics CSV to evaluate; create a temp one
    $DumpProbCsv = Join-Path ($outDir ? $outDir : '.') ("autotighten_gating.csv")
  }
  $modeLabel = if ($AutoIsolate) { 'AutoIsolate' } else { 'AutoTighten' }
  Write-Host "[$modeLabel] Starting iterative tightening (MaxPasses=$MaxPasses TargetMedian=$TargetInactiveMedianScale TargetMean=$TargetInactiveMeanScale)" -ForegroundColor Cyan
  $pass = 1
  $baseOutName = [IO.Path]::GetFileNameWithoutExtension($OutWav)
  $ext = [IO.Path]::GetExtension($OutWav)
  $currentOut = $OutWav
  while ($pass -le $MaxPasses) {
    # Expect a CSV from previous run (or generate if first loop missing)
    $csvPath = $DumpProbCsv
    if (-not (Test-Path -LiteralPath $csvPath)) {
      Write-Host "[AutoTighten] CSV missing for analysis; re-running with diagnostics capture." -ForegroundColor Yellow
      $argsDiag = @('-InWav', $InAudio, '-OutWav', $currentOut, '-Model', $Model, '-BuildType', $BuildType, '-GuitarOnly', '-GuitarThreshold', $GuitarThreshold, '-GuitarAttenDB', $GuitarAttenDB, '-DumpProbCsv', $csvPath)
      if ($ProbFloor -gt 0) { $argsDiag += @('-ProbFloor', $ProbFloor) }
      if ($EnergyThreshold -gt 0) { $argsDiag += @('-EnergyThreshold', $EnergyThreshold) }
      if ($MinScale -gt 0) { $argsDiag += @('-MinScale', $MinScale) }
      if ($AdaptiveFactor -gt 0) { $argsDiag += @('-AdaptiveFactor', $AdaptiveFactor) }
      if ($EmaAlpha -gt 0 -and $EmaAlpha -le 1) { $argsDiag += @('-EmaAlpha', $EmaAlpha) }
      pwsh -NoProfile -ExecutionPolicy Bypass -File $rnnoiseWav @argsDiag
    }
    # Parse CSV to compute per-frame inactive scale distribution
    $rows = Get-Content -LiteralPath $csvPath | Select-Object -Skip 1 | Where-Object { $_ -and ($_ -notmatch '^frame,') }
    if (-not $rows -or $rows.Count -lt 10) {
      Write-Host "[AutoTighten] Insufficient rows in CSV ($($rows.Count)). Stopping." -ForegroundColor Red
      break
    }
    $inactiveScales = @()
    $activeScales = @()
    $activeProbs = @()
    $inactiveProbs = @()
    $activeCount = 0
    $inactiveCount = 0
    foreach ($r in $rows) {
      $parts = $r.Split(',')
      if ($parts.Count -ge 5) {
        $prob = [double]$parts[1]
        $rms = [double]$parts[2] # reserved if we later need heuristics
        $active = [int]$parts[3]
        $scale = [double]$parts[4]
        if ($active -eq 0) {
          $inactiveScales += $scale
          $inactiveProbs  += $prob
          $inactiveCount++
        } else {
          $activeScales += $scale
          $activeProbs  += $prob
          $activeCount++
        }
      }
    }
    if (-not $inactiveScales -or $inactiveScales.Count -lt 5) {
      Write-Host "[AutoTighten] Not enough inactive frames to evaluate (Count=$($inactiveScales.Count)). Stopping." -ForegroundColor Yellow
      break
    }
    $totalFramesEval = $activeCount + $inactiveCount
    $activePct = if ($totalFramesEval -gt 0) { $activeCount / $totalFramesEval } else { 0 }
    $sorted = $inactiveScales | Sort-Object
    $midIndex = [int]([math]::Floor($sorted.Count / 2))
    if ($midIndex -ge $sorted.Count) { $midIndex = $sorted.Count - 1 }
    $median = $sorted[$midIndex]
    $mean = ($inactiveScales | Measure-Object -Average).Average
    $meanActiveScale = if ($activeScales.Count -gt 0) { ($activeScales | Measure-Object -Average).Average } else { 1.0 }
    $meanInactiveScale = $mean
    $scaleGap = $meanActiveScale - $meanInactiveScale
    $avgProbActive = if ($activeProbs.Count -gt 0) { ($activeProbs | Measure-Object -Average).Average } else { 0 }
    $avgProbInactive = if ($inactiveProbs.Count -gt 0) { ($inactiveProbs | Measure-Object -Average).Average } else { 0 }
    $probGap = $avgProbActive - $avgProbInactive
    Write-Host ("[$modeLabel][Pass {0}] medianInact={1:F3} meanInact={2:F3} activePct={3:P1} meanActScale={4:F3} scaleGap={5:F3} probGap={6:F3} Thr={7:F2} Att={8} MinScale={9:F3}" -f $pass,$median,$meanInactiveScale,$activePct,$meanActiveScale,$scaleGap,$probGap,$GuitarThreshold,$GuitarAttenDB,$MinScale) -ForegroundColor DarkCyan

    $successSimple = (($median -le $TargetInactiveMedianScale) -and ($meanInactiveScale -le $TargetInactiveMeanScale))
    $successAdvanced = $false
    if ($AutoIsolate) {
      $successAdvanced = $successSimple -and ($activePct -ge $TargetActivePctMin) -and ($activePct -le $TargetActivePctMax) -and ($scaleGap -ge $MinActiveInactiveScaleGap) -and ($probGap -ge $MinProbGap)
    }
    if ( ($AutoIsolate -and $successAdvanced) -or ( -not $AutoIsolate -and $successSimple) ) {
      Write-Host "[$modeLabel] Target achieved (criteria satisfied)." -ForegroundColor Green
      break
    }
    # Escalate parameters
    $oldThr = $GuitarThreshold
    $thrStep = $EscalateThresholdStep
    if ($AutoIsolate -and $activePct -gt $TargetActivePctMax) { $thrStep = [math]::Min($EscalateThresholdStep * 2, 0.20) }
    $GuitarThreshold = [math]::Min($MaxThreshold, $GuitarThreshold + $thrStep)
    $oldAtt = $GuitarAttenDB
    $GuitarAttenDB = [math]::Max($MinAttenDB, $GuitarAttenDB + $EscalateAttenStepDB) # step is negative
    # Reduce MinScale gradually (but not below a safety floor)
    if ($MinScale -gt 0.02) { $MinScale = [math]::Max(0.02, $MinScale - 0.01) }
    Write-Host ("[$modeLabel] Escalating: Thr {0:F2}->{1:F2} Att {2}->{3} MinScale->{4:F3} (thrStep={5:F3})" -f $oldThr,$GuitarThreshold,$oldAtt,$GuitarAttenDB,$MinScale,$thrStep) -ForegroundColor Magenta
    if ($AutoIsolate -and $activePct -lt $TargetActivePctMin -and $scaleGap -lt $MinActiveInactiveScaleGap) {
      Write-Host "[$modeLabel] WARNING: ActivePct below target and scale gap small; further tightening may degrade guitar." -ForegroundColor Yellow
    }
    # Re-run with updated params; keep overwriting same OutWav for iterative refinement
    $argsLoop = @('-InWav', $InAudio, '-OutWav', $currentOut, '-Model', $Model, '-BuildType', $BuildType, '-GuitarOnly', '-GuitarThreshold', $GuitarThreshold, '-GuitarAttenDB', $GuitarAttenDB, '-DumpProbCsv', $csvPath)
    if ($ProbFloor -gt 0) { $argsLoop += @('-ProbFloor', $ProbFloor) }
    if ($EnergyThreshold -gt 0) { $argsLoop += @('-EnergyThreshold', $EnergyThreshold) }
    if ($MinScale -gt 0) { $argsLoop += @('-MinScale', $MinScale) }
    if ($AdaptiveFactor -gt 0) { $argsLoop += @('-AdaptiveFactor', $AdaptiveFactor) }
    if ($EmaAlpha -gt 0 -and $EmaAlpha -le 1) { $argsLoop += @('-EmaAlpha', $EmaAlpha) }
    if ($ForceRebuild) { $argsLoop += '-ForceRebuild' }
    pwsh -NoProfile -ExecutionPolicy Bypass -File $rnnoiseWav @argsLoop
    $pass++
  }
  if ($pass -gt $MaxPasses) { Write-Host "[$modeLabel] Reached MaxPasses ($MaxPasses) without meeting criteria." -ForegroundColor Yellow }
}

# Optional baseline (no gating) pass
if ($BaselineAlso) {
  $baseOut = if ($AutoName) { $OutWav -replace '_guitar','_baseline' } else { [IO.Path]::Combine($outDir, ([IO.Path]::GetFileNameWithoutExtension($OutWav) + '_baseline.wav')) }
  Write-Host "[mp32wav2rnnoise] Generating baseline (no gating) -> $baseOut" -ForegroundColor Gray
  $baseArgs = @('-InWav', $InAudio, '-OutWav', $baseOut, '-Model', $Model, '-BuildType', $BuildType)
  if ($ForceRebuild) { $baseArgs += '-ForceRebuild' }
  pwsh -NoProfile -ExecutionPolicy Bypass -File $rnnoiseWav @baseArgs
}

# Post-run silence heuristic: if output WAV very small or ffprobe RMS near zero, prompt user.
try {
  if (Test-Path -LiteralPath $OutWav) {
    $outInfo = Get-Item -LiteralPath $OutWav
    if ($outInfo.Length -lt 2048) {
      Write-Warning "[mp32wav2rnnoise] Output file extremely small; likely silence after gating. Try: -ForceSafeDefaults or lower -GuitarThreshold or raise -MinScale."
    }
  }
} catch {}

# try {
#   $vlcExe = "C:\Program Files\VideoLAN\VLC\vlc.exe"
#   if (Test-Path -LiteralPath $vlcExe) {
#     $playTarget = (Resolve-Path -LiteralPath $OutWav -ErrorAction SilentlyContinue)
#     if ($playTarget) {
#       Write-Host "[mp32wav2rnnoise] Launching VLC for $playTarget" -ForegroundColor DarkCyan
#       & $vlcExe "$playTarget" | Out-Null
#     } else {
#       Write-Verbose "[mp32wav2rnnoise] Skipping VLC launch; cannot resolve OutWav ($OutWav)."
#     }
#   }
# } catch { Write-Verbose "[mp32wav2rnnoise] VLC playback attempt failed: $($_.Exception.Message)" }

Write-Host "[mp32wav2rnnoise] Done"