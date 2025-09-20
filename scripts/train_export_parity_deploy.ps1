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
  # Path to precomputed feature file (layout 98 or 99 dims) consumed by train_rnnoise.py
  [string]$FeaturesFile = "features.f32",
  # Output directory where checkpoints and ONNX will be written
  [string]$OutputDir = "checkpoints\\gtr_auto",
  # Number of epochs to train
  [int]$Epochs = 10,
  # Final copied model name (top-level)
  [string]$ModelOut = "model.onnx",
  # Optional JUCE app bin directory to deploy the model to
  [string]$JuiceBinDir = "",
  # Deployed model filename in JUCE bin dir
  [string]$JuiceModelName = "model.onnx",
  # Run parity probe/build legacy path too
  [switch]$RunParity,
  # ONNX opset version
  [int]$Opset = 17,
  # Python executable to invoke
  [string]$PythonExe = "python",
  # Optional GRU size / cond size overrides to keep consistent with prior experiments
  [int]$CondSize = 128,
  [int]$GruSize = 384,
  # Activity loss weight (matches train_rnnoise default 0.0005)
  [double]$ActivityLossWeight = 0.0005,
  # Disable activity head supervision
  [switch]$DisableActivityHead,
  # Use guitar activity label if 99-dim features
  [switch]$UseGuitarActivityLabel,
  # Attempt to auto-install missing Python deps (numpy, torch, tqdm)
  [switch]$AutoInstallDeps,
  # Optional path to create/use a dedicated virtual environment for training
  [string]$VenvPath = "",
  # Write a requirements file capturing resolved versions
  [switch]$WriteRequirements,
  # Show verbose pip output for dependency installs
  [switch]$VerboseDeps,
  # Directory containing training Python package (default 'torch' but recommend renaming to avoid PyTorch shadowing)
  [string]$TrainDir = 'torch'
)

$ErrorActionPreference = 'Stop'

function Timestamp { return (Get-Date).ToString('u') }

Write-Host "[`Timestamp`] TRAIN START" -ForegroundColor Cyan

# Pre-flight validations
if(-not (Test-Path $FeaturesFile)) { Write-Host "Feature file '$FeaturesFile' not found." -ForegroundColor Red; exit 1 }
$featSize = (Get-Item $FeaturesFile).Length
if($featSize -lt 1024) { Write-Host "Feature file too small ($featSize bytes) - aborting." -ForegroundColor Red; exit 1 }
if(-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

Write-Host "Using features: $FeaturesFile" -ForegroundColor DarkCyan
Write-Host ("Output dir : {0}" -f $OutputDir) -ForegroundColor DarkCyan
Write-Host "Epochs     : $Epochs" -ForegroundColor DarkCyan
Write-Host "Opset      : $Opset" -ForegroundColor DarkCyan

$OnnxPath = Join-Path $OutputDir "rnnoise.onnx"
$logPath = Join-Path $OutputDir "train.log"
$trainCandidates = @(
  (Join-Path $TrainDir 'train_rnnoise.py'),
  (Join-Path (Join-Path $TrainDir 'rnnoise') 'train_rnnoise.py')
)
$TrainScript = $null
foreach($c in $trainCandidates) { if(Test-Path $c) { $TrainScript = $c; break } }
if(-not $TrainScript) {
  Write-Host "Could not locate training script. Looked at:" -ForegroundColor Red
  $trainCandidates | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  if(Test-Path $TrainDir) {
    Write-Host ("Listing of {0}:" -f $TrainDir) -ForegroundColor Yellow
    Get-ChildItem -Path $TrainDir | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
  } else {
    Write-Host "TrainDir '$TrainDir' does not exist." -ForegroundColor Red
  }
  Write-Host "Adjust -TrainDir to the folder containing either train_rnnoise.py or rnnoise/train_rnnoise.py" -ForegroundColor Yellow
  exit 1
}

# Detect shadowing of PyTorch by local training dir named 'torch'
if($TrainDir -ieq 'torch') {
  if(Test-Path '.\torch') {
    if(-not (Test-Path '.\torch\__init__.py')) {
      Write-Host "WARNING: Local directory '.\\torch' may shadow real PyTorch. Recommended: Rename to 'rnnoise_train' and re-run with -TrainDir rnnoise_train" -ForegroundColor Yellow
    }
  }
}

# Ensure decimal separator is '.' (some locales format double to comma)
$actLossStr = ([System.Globalization.CultureInfo]::InvariantCulture.NumberFormat).NumberDecimalSeparator
$activityLossInvariant = $ActivityLossWeight.ToString([System.Globalization.CultureInfo]::InvariantCulture)

if($AutoInstallDeps) {
  Write-Host "[`Timestamp`] Checking Python dependencies..." -ForegroundColor Cyan
  # Optionally create/use virtual environment to avoid global conflicts
  if($VenvPath) {
    # Expand relative path to absolute for clarity
    $VenvPath = (Resolve-Path -Path $VenvPath -ErrorAction SilentlyContinue) ?? $VenvPath
    if(-not (Test-Path $VenvPath)) {
      Write-Host "Creating virtual environment at $VenvPath" -ForegroundColor Yellow
      & $PythonExe -m venv $VenvPath
      if($LASTEXITCODE -ne 0) { Write-Host "Failed to create venv at $VenvPath." -ForegroundColor Red; exit 1 }
    }
    $activate = Join-Path $VenvPath "Scripts\Activate.ps1"
    if(-not (Test-Path $activate)) { Write-Host "Activation script missing in venv ($activate)." -ForegroundColor Red; exit 1 }
    Write-Host "Activating venv: $VenvPath" -ForegroundColor Yellow
    . $activate
    $PythonExe = "python"
  }

  # Upgrade pip first (quietly) to reduce resolver issues
  if($VerboseDeps) { & $PythonExe -m pip install --upgrade pip }
  else { & $PythonExe -m pip install --upgrade pip | Out-Null }

  # Minimal set needed for training script
  $core = @('numpy','tqdm')
  $missing = @()
  foreach($m in $core) {
    & $PythonExe -c "import $m" 2>$null; if($LASTEXITCODE -ne 0) { $missing += $m }
  }
  if($missing.Count -gt 0) {
    Write-Host "Installing core deps: $($missing -join ', ')" -ForegroundColor Yellow
    if($VerboseDeps) { & $PythonExe -m pip install $missing --upgrade }
    else { & $PythonExe -m pip install $missing --upgrade | Out-Null }
  }
  # Re-check core deps; collect any still missing
  $stillMissing = @()
  foreach($m in $core) { & $PythonExe -c "import $m" 2>$null; if($LASTEXITCODE -ne 0) { $stillMissing += $m } }
  if($stillMissing.Count -gt 0) {
    Write-Host "FAILED to import after install: $($stillMissing -join ', ')" -ForegroundColor Red
    Write-Host "Try manual: $PythonExe -m pip install $($stillMissing -join ' ')" -ForegroundColor Red
    exit 1
  }
  # Attempt to distinguish between real PyTorch and local 'torch' folder (name collision)
  & $PythonExe -c "import sys,os; import torch; import types; ok = all(hasattr(torch,a) for a in ('__version__','nn','tensor')); print('TORCH_STATUS', 'OK' if ok else 'PLACEHOLDER', getattr(torch,'__file__',None)); sys.exit(0 if ok else 1)" 2>$null
  if($LASTEXITCODE -ne 0) {
    Write-Host "Installing real PyTorch (CPU wheel) - local placeholder detected or missing." -ForegroundColor Yellow
    if($VerboseDeps) { & $PythonExe -m pip install torch --index-url https://download.pytorch.org/whl/cpu }
    else { & $PythonExe -m pip install torch --index-url https://download.pytorch.org/whl/cpu | Out-Null }
    & $PythonExe -c "import sys; import torch; import torch.nn as nn; ok = all(hasattr(torch,a) for a in ('__version__','nn','tensor')); print('TORCH_POST_INSTALL', ok, getattr(torch,'__version__','?'), getattr(torch,'__file__',None)); sys.exit(0 if ok else 1)" 2>$null
    if($LASTEXITCODE -ne 0) {
      Write-Host "PyTorch CPU wheel install failed; trying generic index." -ForegroundColor Yellow
      if($VerboseDeps) { & $PythonExe -m pip install torch --upgrade }
      else { & $PythonExe -m pip install torch --upgrade | Out-Null }
      & $PythonExe -c "import sys; import torch; ok = all(hasattr(torch,a) for a in ('__version__','nn','tensor')); print('TORCH_POST_FALLBACK', ok, getattr(torch,'__version__','?'), getattr(torch,'__file__',None)); sys.exit(0 if ok else 1)" 2>$null
      if($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: Could not obtain real PyTorch. A directory named 'torch' in the repo may be shadowing the package." -ForegroundColor Red
        Write-Host "Rename the local 'torch' folder (e.g. to 'rnnoise_train') then re-run." -ForegroundColor Red
        exit 1
      }
    }
  }
  if($WriteRequirements) {
    $reqFile = Join-Path $OutputDir "requirements_training.txt"
    if($VerboseDeps) { & $PythonExe -m pip freeze > $reqFile }
    else { & $PythonExe -m pip freeze > $reqFile }
    Write-Host "Wrote requirements to $reqFile" -ForegroundColor DarkCyan
  }
  # Ensure ONNX Python package present for export
  if(-not (Test-Path $OnnxPath)) {
    & $PythonExe -c "import onnx" 2>$null
    if($LASTEXITCODE -ne 0) {
      Write-Host "Installing onnx package for export" -ForegroundColor Yellow
      if($VerboseDeps) { & $PythonExe -m pip install onnx }
      else { & $PythonExe -m pip install onnx | Out-Null }
      & $PythonExe -c "import onnx" 2>$null
      if($LASTEXITCODE -ne 0) { Write-Host "Failed to install onnx; export will fail." -ForegroundColor Red }
    }
  }
  Write-Host "[`Timestamp`] Dependency check complete." -ForegroundColor Green
}

# Final import sanity test with shadow recovery
& $PythonExe -c @"
import sys, os
def try_import():
  mods=['numpy','tqdm','torch']
  paths={}
  missing=[]
  for m in mods:
    try:
      mod=__import__(m)
      paths[m]=getattr(mod,'__file__',None)
    except Exception as e:
      print('IMPORT_FAIL', m, e)
      missing.append(m)
  if missing:
    print('MISSING', ','.join(missing))
    return False, paths
  import torch
  ok = all(hasattr(torch,a) for a in ('__version__','nn','tensor'))
  if not ok:
    print('TORCH_INCOMPLETE', getattr(torch,'__file__',None))
    return False, paths
  print('Imports OK | torch', getattr(torch,'__version__','?'), 'cuda', hasattr(torch,'cuda') and torch.cuda.is_available(), 'paths', paths)
  return True, paths

ok, paths = try_import()
if not ok and 'torch' in paths and paths['torch'] is None:
  # Attempt path shuffle: move site-packages ahead explicitly
  sp = [p for p in sys.path if 'site-packages' in p]
  for p in reversed(sp):
    if sys.path[0] != p:
      sys.path.insert(0, p)
  print('Retrying import after path reorder...')
  ok, paths = try_import()
sys.exit(0 if ok else 1)
"@ 2>$null
if($LASTEXITCODE -ne 0) {
  Write-Host "Failed to import required Python modules or real PyTorch. If a local directory named 'torch' exists, rename it (e.g. rnnoise_train) and pass -TrainDir rnnoise_train." -ForegroundColor Red
  exit 1
}

$trainArgs = @(
  $TrainScript,
  $FeaturesFile,
  $OutputDir,
  "--epochs", $Epochs,
  "--onnx-opset", $Opset,
  "--export-onnx", $OnnxPath,
  "--cond-size", $CondSize,
  "--gru-size", $GruSize,
  "--activity-loss-weight", $activityLossInvariant
)
if($DisableActivityHead) { $trainArgs += "--disable-activity-head" }
if($UseGuitarActivityLabel) { $trainArgs += "--use-guitar-activity-label" }

Write-Host "Invoking: $PythonExe $($trainArgs -join ' ')" -ForegroundColor Gray
& $PythonExe @trainArgs 2>&1 | Tee-Object $logPath

if(-not (Test-Path $OnnxPath)) {
  Write-Host "Expected ONNX at $OnnxPath not found. Searching recursively..." -ForegroundColor Yellow
  $exported = Get-ChildItem -Recurse -Filter *.onnx -Path $OutputDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $exported) { Write-Host "No ONNX found in $OutputDir. Exiting." -ForegroundColor Red; exit 1 }
  $OnnxPath = $exported.FullName
}
Write-Host "Found ONNX: $OnnxPath" -ForegroundColor Green

# Copy to top-level model output name
Copy-Item $OnnxPath -Destination $ModelOut -Force

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
  $parityExe = Join-Path "build_pure/Release" "onnx_parity_probe.exe"
  if(-not (Test-Path $parityExe)) { Write-Host "Parity executable not found at $parityExe" -ForegroundColor Red; exit 1 }
  type $rawTmp | & $parityExe $ModelOut > pure.txt
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
