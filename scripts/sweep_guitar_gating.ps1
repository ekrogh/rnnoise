param(
  [string]$InputDir = "data/guitar_clean",
  [string]$DemoExe = "build/Release/rnnoise_demo.exe",
  [string]$EvalScript = "scripts/evaluate_isolation.py",
  [int]$Limit = 10,
  [string]$Ext = ".wav",
  [string]$OutDir = "gating_sweeps"
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path $EvalScript)) { Write-Error "Evaluation script not found: $EvalScript" }
if (!(Test-Path $DemoExe)) { Write-Error "Demo exe not found: $DemoExe" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Parameter grids
$thresholds = 0.35,0.40,0.45
$minScales  = 0.05,0.10,0.15
$exponents  = 1.5,2.0,2.5
$upDamps    = 0.4,0.5

$results = @()

foreach ($t in $thresholds) {
  foreach ($m in $minScales) {
    foreach ($e in $exponents) {
      foreach ($u in $upDamps) {
        $tag = "T${t}_M${m}_E${e}_U${u}".Replace('.','p')
        $reportTxt = Join-Path $OutDir "report_${tag}.txt"
        $reportJson = Join-Path $OutDir "report_${tag}.json"
        Write-Host "Running sweep $tag"
        $env:RN_GUITAR_GATE_THRESH = $t
        $env:RN_GUITAR_MIN_SCALE = $m
        $env:RN_GUITAR_SCALE_EXP = $e
        $env:RN_GUITAR_UP_DAMP = $u
        # Keep smoothing alpha default from build (can expose later)
        python $EvalScript --input-dir $InputDir --demo-exe $DemoExe --limit $Limit --ext $Ext --report $reportTxt --json $reportJson | Out-Null
        if (Test-Path $reportJson) {
          $json = Get-Content $reportJson -Raw | ConvertFrom-Json
          if ($json.Length -gt 0) {
            # Aggregate: mean mid retain, mean high retain, mean suppression score
            $midMean = ($json | Measure-Object -Property retain_mid -Average).Average
            $highMean = ($json | Measure-Object -Property retain_high -Average).Average
            $suppMean = ($json | Measure-Object -Property suppression_score_db -Average).Average
            $results += [pscustomobject]@{
              Threshold = $t; MinScale = $m; Exponent = $e; UpDamp = $u;
              MidRetain = [math]::Round($midMean,4);
              HighRetain = [math]::Round($highMean,4);
              SuppressionDB = [math]::Round($suppMean,2);
              Report = $reportJson
            }
          }
        }
      }
    }
  }
}

$summaryPath = Join-Path $OutDir "summary.csv"
$results | Export-Csv -NoTypeInformation -Path $summaryPath
Write-Host "Sweep complete. Summary: $summaryPath"