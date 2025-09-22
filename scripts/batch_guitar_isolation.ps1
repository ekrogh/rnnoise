<#+
.SYNOPSIS
  Batch process a directory of audio files (mp3/wav/flac/etc) through RNNoise ONNX guitar isolation.
.DESCRIPTION
  For each supported input file, produces:
    1) Baseline denoised (no gating) output
    2) Guitar-isolated (gated) output
  Uses existing mp32wav2rnnoise.ps1 wrapper for convenience. Auto-build of ONNX demo
  will occur through rnnoise_wav.ps1 if needed.
.PARAMETER InDir
  Input directory containing audio files.
.PARAMETER OutDir
  Output directory root; per-file outputs placed here.
.PARAMETER Model
  Path to ONNX model (default: model.onnx at repo root).
.PARAMETER Pattern
  Glob-like filter (PowerShell -like) for input extensions. Default: *.mp3;*.wav;*.flac;*.m4a
.PARAMETER BuildType
  Debug or Release (passed through).
.PARAMETER GuitarThreshold
  Gating probability threshold.
.PARAMETER GuitarAttenDB
  Attenuation (dB) when below threshold.
.PARAMETER DryRun
  Show what would be processed without running.
.PARAMETER Parallel
  Enable parallel processing (Start-Job) for faster batch (Windows PowerShell 5+).
.PARAMETER MaxParallel
  Limit number of concurrent jobs if Parallel is used (default 4).
.PARAMETER SkipBaseline
  Only produce guitar-isolated output.
.EXAMPLE
  pwsh -File scripts/batch_guitar_isolation.ps1 -InDir .\album -OutDir .\processed -Model .\model.onnx -GuitarThreshold 0.5 -GuitarAttenDB -35
#>
param(
  [Parameter(Mandatory=$true)] [string]$InDir,
  [Parameter(Mandatory=$true)] [string]$OutDir,
  [string]$Model = 'model.onnx',
  [string]$Pattern = '*.mp3;*.wav;*.flac;*.m4a',
  [ValidateSet('Debug','Release')] [string]$BuildType = 'Release',
  [double]$GuitarThreshold = 0.55,
  [double]$GuitarAttenDB = -40,
  [double]$ProbFloor = 0.0,
  [double]$EnergyThreshold = 0.0,
  [double]$MinScale = 0.0,
  [switch]$SoftMask,
  [double]$Gamma = 0.0,
  [switch]$DumpCsv,
  [switch]$Parallel,
  [int]$MaxParallel = 4,
  [switch]$DryRun,
  [switch]$SkipBaseline,
  [switch]$SummaryCsv,              # emit aggregate summary CSV in OutDir
  [string]$SummaryCsvPath = ''      # optional explicit path for summary CSV
)

$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Error $m; exit 1 }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wrapper  = Join-Path $repoRoot 'scripts/mp32wav2rnnoise.ps1'
if (-not (Test-Path -LiteralPath $wrapper)) { Fail "Wrapper script not found: $wrapper" }
if (-not (Test-Path -LiteralPath $InDir)) {
  Write-Host "[BATCH] Input directory not found: $InDir" -ForegroundColor Yellow
  Write-Host "[BATCH] Existing top-level items:" -ForegroundColor Yellow
  Get-ChildItem -LiteralPath (Get-Location) -Directory | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "  - $_" }
  Fail "InDir not found: $InDir"
}
if (-not (Test-Path -LiteralPath $Model)) { Fail "Model not found: $Model" }
$Model = (Resolve-Path -LiteralPath $Model).Path

# Collect files
$extPatterns = $Pattern.Split(';') | Where-Object { $_ -and $_.Trim() -ne '' }
$files = @()
foreach ($p in $extPatterns) {
  $files += Get-ChildItem -LiteralPath $InDir -Recurse -File -Include $p
}
$files = $files | Sort-Object -Property FullName -Unique
if (-not $files) { Write-Warning "No input files matched pattern(s) $Pattern in $InDir"; exit 0 }

# Ensure output dir
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

Write-Host "[BATCH] Files: $($files.Count)  Model: $Model  Threshold: $GuitarThreshold  Atten: $GuitarAttenDB dB  Parallel: $Parallel" -ForegroundColor Cyan

# Collect per-file summaries
$GLOBAL:BatchSummaries = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

$jobs = @()

function Invoke-Isolation {
  param(
    [string]$InputFile,
    [string]$Model,
    [string]$OutDir,
    [string]$BuildType,
    [double]$GuitarThreshold = 0.55,
  [double]$GuitarAttenDB = -40,
  [double]$ProbFloor = 0.0,
  [double]$EnergyThreshold = 0.0,
  [double]$MinScale = 0.0,
  [switch]$SoftMask,
  [double]$Gamma = 0.0,
  [switch]$DumpCsv,
    [bool]$SkipBaseline = $false,
    [string]$Wrapper,
    [string]$InRoot
  )
  # Skip empty (likely placeholder) files early
  $fi = Get-Item -LiteralPath $InputFile
  if ($fi.Length -lt 100) { Write-Host "[SKIP] File too small (<100 bytes): $InputFile" -ForegroundColor DarkYellow; return }

  # Compute relative path from input root for nested directory mirroring
  $relFull = Resolve-Path -LiteralPath $InputFile
  $rootFull = Resolve-Path -LiteralPath $InRoot
  $relPath = $relFull.Path.Substring($rootFull.Path.Length).TrimStart('\\','/')
  $relDir = Split-Path -Path $relPath -Parent
  if (-not $relDir -or $relDir -eq '.') { $relDir = '' }
  $leaf = [IO.Path]::GetFileNameWithoutExtension($InputFile)
  $subOut = if ($relDir) { Join-Path $OutDir $relDir } else { $OutDir }
  if (-not (Test-Path -LiteralPath $subOut)) { New-Item -ItemType Directory -Path $subOut -Force | Out-Null }
  $baseOut = Join-Path $subOut ("{0}_baseline.wav" -f $leaf)
  $gtrOut  = Join-Path $subOut ("{0}_guitar.wav" -f $leaf)

  $commonArgs = @('-InAudio', $InputFile, '-Model', $Model, '-BuildType', $BuildType)
  $errors = @()
  if (-not $SkipBaseline) {
    $argsBase = @('-OutWav', $baseOut, '-GuitarOnly:$false') + $commonArgs
    $proc = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Wrapper @argsBase 2>&1
    if ($LASTEXITCODE -ne 0) { $errors += "Baseline failed ($LASTEXITCODE): $($proc | Select-Object -Last 5)" }
  }
  $argsGtr = @('-OutWav', $gtrOut, '-GuitarOnly', '-GuitarThreshold', $GuitarThreshold, '-GuitarAttenDB', $GuitarAttenDB)
  if ($ProbFloor -gt 0) { $argsGtr += @('-ProbFloor', $ProbFloor) }
  if ($EnergyThreshold -gt 0) { $argsGtr += @('-EnergyThreshold', $EnergyThreshold) }
  if ($MinScale -gt 0) { $argsGtr += @('-MinScale', $MinScale) }
  if ($SoftMask) { $argsGtr += '-SoftMask' }
  if ($Gamma -gt 0) { $argsGtr += @('-Gamma', ($Gamma.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
  if ($DumpCsv) {
    $csvOut = [IO.Path]::ChangeExtension($gtrOut, '.csv')
    $argsGtr += @('-DumpProbCsv', $csvOut)
  }
  $argsGtr += $commonArgs
  $proc2 = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Wrapper @argsGtr 2>&1
  if ($LASTEXITCODE -ne 0) { $errors += "Guitar isolation failed ($LASTEXITCODE): $($proc2 | Select-Object -Last 5)" }

  if ($errors.Count -gt 0) {
    Write-Warning "[FAIL] $InputFile : $($errors -join ' | ')"
  } else {
    Write-Host "[OK] $InputFile" -ForegroundColor Green
  }
  # Attempt to locate a per-run summary line from wrapper's ONNX execution output if CSV dumped
  $summary = $null
  if ($DumpCsv) {
    # Find corresponding gating CSV path (if produced) for potential scale statistics later (defer heavy parsing here)
    $csvCandidate = [IO.Path]::ChangeExtension($gtrOut, '.csv')
    if (Test-Path -LiteralPath $csvCandidate) {
      # Lazy parse: just count lines for frames; we rely on ONNX summary for gating counts
      try { $csvLines = (Get-Content -LiteralPath $csvCandidate | Measure-Object).Count } catch { $csvLines = 0 }
    }
  }
  # Parse any [SUMMARY] lines captured in proc2 if available
  if ($proc2) {
    $summaryLine = ($proc2 | Select-String -Pattern '^\[SUMMARY\]' | Select-Object -Last 1).Line
    if ($summaryLine) { $summary = $summaryLine }
  }
  if ($summary) {
    # Example format: [SUMMARY] frames=1234 active=900 gated=334 active_pct=72.95 avg_prob=0.4567
    $m = [regex]::Match($summary, 'frames=(\d+) active=(\d+) gated=(\d+) active_pct=([0-9.]+) avg_prob=([0-9.]+)')
    if ($m.Success) {
      $obj = [pscustomobject]@{
        File        = $InputFile
        Frames      = [int]$m.Groups[1].Value
        ActiveFrames= [int]$m.Groups[2].Value
        GatedFrames = [int]$m.Groups[3].Value
        ActivePct   = [double]$m.Groups[4].Value
        AvgProb     = [double]$m.Groups[5].Value
        Threshold   = $GuitarThreshold
        AttenDB     = $GuitarAttenDB
        ProbFloor   = $ProbFloor
        EnergyThr   = $EnergyThreshold
        MinScale    = $MinScale
      }
      $GLOBAL:BatchSummaries.Add($obj)
    }
  }
  return @{ Base=$baseOut; Guitar=$gtrOut; Errors=$errors; Summary=$summary }
}

if ($DryRun) {
  foreach ($f in $files) { Write-Host "[DRYRUN] Would process: $($f.FullName)" }
  exit 0
}

foreach ($f in $files) {
  if ($Parallel) {
    while ($jobs.Count -ge $MaxParallel) {
      $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
      Start-Sleep -Milliseconds 150
    }
    $argMap = [ordered]@{
      InputFile       = $f.FullName
      Model           = $Model
      OutDir          = $OutDir
      BuildType       = $BuildType
      GuitarThreshold = $GuitarThreshold
  GuitarAttenDB   = $GuitarAttenDB
  ProbFloor       = $ProbFloor
  EnergyThreshold = $EnergyThreshold
  MinScale        = $MinScale
  SoftMask        = [bool]$SoftMask
  Gamma           = $Gamma
  DumpCsv         = [bool]$DumpCsv
      SkipBaseline    = [bool]$SkipBaseline
      Wrapper         = $wrapper
      InRoot          = $InDir
    }
    $jobs += Start-Job -ScriptBlock {
      param($p)
      # Inline isolation logic (mirrors Invoke-Isolation)
      $InputFile       = $p.InputFile
      $Model           = $p.Model
      $OutDir          = $p.OutDir
      $BuildType       = $p.BuildType
      $GuitarThreshold = [double]$p.GuitarThreshold
      $GuitarAttenDB   = [double]$p.GuitarAttenDB
      $SkipBaseline    = [bool]$p.SkipBaseline
  $SoftMask        = [bool]$p.SoftMask
  $Gamma           = [double]$p.Gamma
      $Wrapper         = $p.Wrapper
      $InRoot          = $p.InRoot
      try {
        $fi = Get-Item -LiteralPath $InputFile
        if ($fi.Length -lt 100) { Write-Host "[SKIP] File too small (<100 bytes): $InputFile" -ForegroundColor DarkYellow; return }
        $relFull = (Resolve-Path -LiteralPath $InputFile).Path
        $rootFull = (Resolve-Path -LiteralPath $InRoot).Path
        try {
          $relPath = [IO.Path]::GetRelativePath($rootFull, $relFull)
        } catch {
          # Fallback manual substring if GetRelativePath unavailable
          if ($relFull.StartsWith($rootFull)) { $relPath = $relFull.Substring($rootFull.Length).TrimStart('\','/') } else { $relPath = [IO.Path]::GetFileName($relFull) }
        }
        $relPath = $relPath -replace '^\\+','' -replace '^/+',''
        $relDir = Split-Path -Path $relPath -Parent
        if (-not $relDir -or $relDir -eq '.') { $relDir = '' }
        $leaf = [IO.Path]::GetFileNameWithoutExtension($InputFile)
        $subOut = if ($relDir) { Join-Path $OutDir $relDir } else { $OutDir }
        if (-not (Test-Path -LiteralPath $subOut)) { New-Item -ItemType Directory -Path $subOut -Force | Out-Null }
        $baseOut = Join-Path $subOut ("{0}_baseline.wav" -f $leaf)
        $gtrOut  = Join-Path $subOut ("{0}_guitar.wav" -f $leaf)
        $commonArgs = @('-InAudio', $InputFile, '-Model', $Model, '-BuildType', $BuildType)
        $errors = @()
        if (-not $SkipBaseline) {
          $argsBase = @('-OutWav', $baseOut, '-GuitarOnly:$false') + $commonArgs
          $proc = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Wrapper @argsBase 2>&1
          if ($LASTEXITCODE -ne 0) { $errors += "Baseline failed ($LASTEXITCODE): $($proc | Select-Object -Last 5)" }
        }
        $argsGtr = @('-OutWav', $gtrOut, '-GuitarOnly', '-GuitarThreshold', $GuitarThreshold, '-GuitarAttenDB', $GuitarAttenDB) + $commonArgs
  if ($SoftMask) { $argsGtr += '-SoftMask' }
  if ($Gamma -gt 0) { $argsGtr += @('-Gamma', ([string]([double]$Gamma))) }
        $proc2 = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Wrapper @argsGtr 2>&1
        if ($LASTEXITCODE -ne 0) { $errors += "Guitar isolation failed ($LASTEXITCODE): $($proc2 | Select-Object -Last 5)" }
  if ($errors.Count -gt 0) { Write-Warning "[FAIL] $InputFile : $($errors -join ' | ')" } else { Write-Host "[OK] $InputFile" -ForegroundColor Green }
      } catch {
        Write-Warning "[EXCEPTION] $InputFile : $_"
      }
    } -ArgumentList ($argMap)
  } else {
    Write-Host "[BATCH] Processing: $($f.FullName)" -ForegroundColor Gray
    Invoke-Isolation -InputFile $f.FullName -Model $Model -OutDir $OutDir -BuildType $BuildType -GuitarThreshold $GuitarThreshold -GuitarAttenDB $GuitarAttenDB -SkipBaseline:$SkipBaseline -Wrapper $wrapper -InRoot $InDir | Out-Null
  }
}

if ($Parallel) {
  Write-Host "[BATCH] Waiting for jobs..." -ForegroundColor Yellow
  Wait-Job -Job $jobs | Out-Null
  $failed = $jobs | Where-Object { $_.State -ne 'Completed' }
  if ($failed) {
    $failedIds = ($failed | Select-Object -ExpandProperty Id) -join ', '
    Write-Warning "Some jobs failed: $failedIds" }
  Receive-Job -Job $jobs | Out-Null
  Remove-Job -Job $jobs -Force | Out-Null
}

Write-Host "[BATCH] Done." -ForegroundColor Green

if ($BatchSummaries -and $BatchSummaries.Count -gt 0) {
  $totalFrames = ($BatchSummaries | Measure-Object -Property Frames -Sum).Sum
  $totalActive = ($BatchSummaries | Measure-Object -Property ActiveFrames -Sum).Sum
  $totalGated  = ($BatchSummaries | Measure-Object -Property GatedFrames -Sum).Sum
  $weightedAvgProb = 0.0
  foreach ($s in $BatchSummaries) { if ($s.Frames -gt 0) { $weightedAvgProb += ($s.AvgProb * $s.Frames) } }
  if ($totalFrames -gt 0) { $weightedAvgProb = $weightedAvgProb / $totalFrames }
  $globalActivePct = if ($totalFrames -gt 0) { 100.0 * $totalActive / $totalFrames } else { 0.0 }
  Write-Host ("[BATCH][SUMMARY] files={0} frames={1} active={2} gated={3} active_pct={4:F2} weighted_avg_prob={5:F4}" -f $BatchSummaries.Count,$totalFrames,$totalActive,$totalGated,$globalActivePct,$weightedAvgProb) -ForegroundColor Cyan
  if ($SummaryCsv) {
    $csvPath = if ($SummaryCsvPath) { $SummaryCsvPath } else { Join-Path $OutDir 'batch_summary.csv' }
    try {
      $BatchSummaries | Export-Csv -NoTypeInformation -Path $csvPath -Force
      Add-Content -Path $csvPath ("#TOTAL files={0} frames={1} active={2} gated={3} active_pct={4:F2} weighted_avg_prob={5:F4}" -f $BatchSummaries.Count,$totalFrames,$totalActive,$totalGated,$globalActivePct,$weightedAvgProb)
      Write-Host "[BATCH][SUMMARY] Wrote CSV: $csvPath" -ForegroundColor Green
    } catch { Write-Warning "[BATCH][SUMMARY] Failed to write CSV: $($_.Exception.Message)" }
  }
} else {
  Write-Host "[BATCH][SUMMARY] No per-file summary data collected (maybe no gating CSVs or summaries)." -ForegroundColor DarkYellow
}
