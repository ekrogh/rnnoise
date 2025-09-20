<#!
train_export_parity_deploy.ps1
End-to-end pipeline:
 1. Train model
 2. Export ONNX
 3. Build legacy and PURE_ONNX libs
 4. Run parity (optional if legacy build present)
 5. Copy model.onnx to JUCE project runtime folder

Usage:
  powershell -ExecutionPolicy Bypass -File scripts\train_export_parity_deploy.ps1 `
    -SpeechList list_speech.txt -NoiseList list_noise.txt `
    -Epochs 10 -CheckpointDir checkpoints\gtr_auto `
    -JuiceBinDir "D:\\Users\\eigil\\projects\\juceProjs\\AudioAnalyzer\\Bin" `
    -JuiceModelName model.onnx -RunParity
#>
param(
  [string]$SpeechList = "list_speech.txt",
  [string]$NoiseList = "list_noise.txt",
  [int]$Epochs = 10,
  [string]$CheckpointDir = "checkpoints\gtr_auto",
  [string]$ModelOut = "model.onnx",
  [string]$JuiceBinDir = "",
  [string]$JuiceModelName = "model.onnx",
  [switch]$RunParity,
  [int]$Opset = 17,
  [string]$PythonExe = "python"
)

$ErrorActionPreference = 'Stop'

function Timestamp { return (Get-Date).ToString('u') }

Write-Host "[`Timestamp`] TRAIN START" -ForegroundColor Cyan

# 1. Train
& $PythonExe torch/rnnoise/train_rnnoise.py --speech-list $SpeechList --noise-list $NoiseList --epochs $Epochs --checkpoint-dir $CheckpointDir --export-onnx --onnx-opset $Opset 2>&1 | Tee-Object "$CheckpointDir/train.log"

# Find exported ONNX (fallback to provided output name)
$exported = Get-ChildItem -Recurse -Filter *.onnx -Path $CheckpointDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $exported) { Write-Host "No ONNX found in $CheckpointDir, expected inline export. Exiting." -ForegroundColor Red; exit 1 }
Write-Host "Found ONNX: $($exported.FullName)" -ForegroundColor Green

# Copy to top-level model.out name
Copy-Item $exported.FullName -Destination $ModelOut -Force

# 2. Build legacy (if parity requested)
if($RunParity) {
  Write-Host "[`Timestamp`] Building legacy (embedded)" -ForegroundColor Yellow
  cmake -B build_legacy -DPURE_ONNX=OFF -DCMAKE_BUILD_TYPE=Release | Out-Null
  cmake --build build_legacy --config Release --target rnnoise_demo | Out-Null
}

# 3. Build PURE_ONNX
Write-Host "[`Timestamp`] Building PURE_ONNX" -ForegroundColor Yellow
cmake -B build_pure -DPURE_ONNX=ON -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=Release | Out-Null
cmake --build build_pure --config Release --target onnx_parity_probe rnnoise dump_features_gains | Out-Null

# 4. Parity (if requested)
if($RunParity) {
  Write-Host "[`Timestamp`] Running parity probe" -ForegroundColor Yellow
  $rawTmp = "parity_input.raw"
  # Generate or assume existing raw test; user should prepare. If missing, synthesize 1s silence.
  if(-not (Test-Path $rawTmp)) { [IO.File]::WriteAllBytes($rawTmp, (New-Object byte[] (480*2*5))) }
  type $rawTmp | build_pure/Release/onnx_parity_probe.exe $ModelOut > pure.txt
  # Legacy path placeholder: user to supply legacy.txt from demo variant; we only log pure if no legacy.
  if(Test-Path legacy.txt) {
    python tools/compare_parity.py legacy.txt pure.txt > parity_report.txt
    Write-Host "Parity report written to parity_report.txt" -ForegroundColor Green
  } else {
    Write-Host "legacy.txt not found; skipping compare (pure.txt ready)." -ForegroundColor Yellow
  }
}

# 5. Deploy to JUCE application
if($JuiceBinDir -and (Test-Path $JuiceBinDir)) {
  $dest = Join-Path $JuiceBinDir $JuiceModelName
  Copy-Item $ModelOut -Destination $dest -Force
  Write-Host "Deployed model to $dest" -ForegroundColor Green
} else {
  Write-Host "JUCE bin dir not provided or missing; skipping deployment." -ForegroundColor Yellow
}

Write-Host "[`Timestamp`] Pipeline finished." -ForegroundColor Cyan
