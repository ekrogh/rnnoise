<#
Optional args:
  - pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64

Notes
- Requires ffmpeg and CMake in PATH.
- Defaults to CPU-only Torch; pass -CPUOnly:$false to try CUDA if available.
- Artifacts:
  - features: features.f32
  - checkpoints: models/checkpoints
  - exported C weights copied to src/rnnoise_data.[ch]
  - binaries in build/Release
#>
  [int]$FeatureCount = 100,
  [int]$Epochs = 5,
  [int]$BatchSize = 64,
  [string]$BuildType = "Release",
  [switch]$SkipSynth = $false,
  [switch]$CPUOnly = $true
)
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repo root: $RepoRoot"

  <#
  Quick examples
    - Synthetic (default auto):
        .\pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64
    - Real data (use your WAV folders):
        .\pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100

  Notes
  - Requires ffmpeg and CMake in PATH.
  - Defaults to CPU-only Torch; pass -CPUOnly:$false to try CUDA if available.
  - DataMode:
      Auto (default): use data/guitar_clean & data/interfere if they contain WAVs, otherwise synthesize.
      Synthetic: always synthesize into data/guitar_clean and data/interfere.
      Real: use -GuitarDir and -InterfereDir (folders of 48 kHz mono or any WAVs; will be resampled).
  - Artifacts:
    - features: features.f32
    - checkpoints: models/checkpoints
    - exported C weights copied to src/rnnoise_data.[ch]
    - binaries in build/Release
  #>
Write-Host "--- Usage / Optional args ---"
Write-Host "  pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64"
Write-Host "Notes:"
Write-Host "  - Requires ffmpeg and CMake in PATH."
Write-Host "  - Defaults to CPU-only Torch; pass -CPUOnly:`$false to try CUDA."
Write-Host "Artifacts:"
    [switch]$SkipSynth = $false,
    [switch]$CPUOnly = $true,
    [ValidateSet('Auto','Synthetic','Real')] [string]$DataMode = 'Auto',
    [string]$GuitarDir = '',
    [string]$InterfereDir = ''
Write-Host "  - exported C weights copied to src/rnnoise_data.[ch]"
Write-Host "  - binaries in build/Release"

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Command '$name' not found in PATH. Please install it."
  }
}

# 1) Ensure venv exists and get python path
  Write-Host "  Synthetic (auto):  pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64"
  Write-Host "  Real data:          pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100"
  Write-Host "Creating venv at $VenvPath"
  python -m venv $VenvPath
}
  Write-Host "  - DataMode: Auto|Synthetic|Real (see header for behavior)."
$Py = Join-Path $VenvPath 'Scripts/python.exe'
Write-Host "Using Python: $Py"

# 2) Pip setup and deps
& $Py -m pip install --upgrade pip
try { & $Py -m pip config set global.cache-dir "D:/pip-cache" | Out-Null } catch {}
& $Py -m pip install numpy soundfile tqdm
  # Resolve input data strategy
  $DefaultGuitar = Join-Path $RepoRoot 'data/guitar_clean'
  $DefaultNoise  = Join-Path $RepoRoot 'data/interfere'

  $UseSynth = $false
  if ($DataMode -eq 'Real' -or ($GuitarDir -ne '' -or $InterfereDir -ne '')) {
    if ($GuitarDir -eq '' -or $InterfereDir -eq '') { throw "When -DataMode Real, provide both -GuitarDir and -InterfereDir." }
    $GuitarIn = $GuitarDir
    $NoiseIn  = $InterfereDir
    $UseSynth = $false
  } elseif ($DataMode -eq 'Synthetic') {
    $GuitarIn = $DefaultGuitar
    $NoiseIn  = $DefaultNoise
    $UseSynth = $true
  } else { # Auto
    $GuitarIn = $DefaultGuitar
    $NoiseIn  = $DefaultNoise
    $hasGuitar = (Test-Path $GuitarIn) -and (Get-ChildItem $GuitarIn -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
    $hasNoise  = (Test-Path $NoiseIn)  -and (Get-ChildItem $NoiseIn  -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
    $UseSynth = -not ($hasGuitar -and $hasNoise)
  }

  # 3) Optional: synthesize small dataset (unless explicitly skipped)
  if ($UseSynth -and -not $SkipSynth) {
    Write-Host "Synthesizing guitar/interference WAVs into $DefaultGuitar and $DefaultNoise..."
    & $Py (Join-Path $RepoRoot 'scripts/synthesize_guitar_data.py')
    $GuitarIn = $DefaultGuitar
    $NoiseIn  = $DefaultNoise
  }

  if (-not (Test-Path $GuitarIn)) { throw "GuitarDir not found: $GuitarIn" }
  if (-not (Test-Path $NoiseIn))  { throw "InterfereDir not found: $NoiseIn" }
}

# 3) Optional: synthesize small dataset
if (-not $SkipSynth) {
  Write-Host "Synthesizing guitar/interference WAVs..."
  & $Py (Join-Path $RepoRoot 'scripts/synthesize_guitar_data.py')
}
    Get-ChildItem $GuitarIn -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $speechList
    Get-ChildItem $NoiseIn  -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $noiseList
Require-Cmd ffmpeg
Push-Location $RepoRoot
try {
  $speechList = Join-Path $RepoRoot 'list_speech.txt'
  $noiseList  = Join-Path $RepoRoot 'list_noise.txt'
  Get-ChildItem .\data\guitar_clean -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $speechList
  Get-ChildItem .\data\interfere   -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $noiseList

  if (-not (Test-Path $speechList) -or -not (Get-Content $speechList)) { throw "No WAVs in data/guitar_clean." }
  if (-not (Test-Path $noiseList)  -or -not (Get-Content $noiseList))  { throw "No WAVs in data/interfere." }

  Write-Host "Building speech.pcm ..."
  ffmpeg -y -f concat -safe 0 -i $speechList -f s16le -acodec pcm_s16le -ar 48000 -ac 1 .\speech.pcm | Out-Null
  Write-Host "Building noise.pcm ..."
  ffmpeg -y -f concat -safe 0 -i $noiseList  -f s16le -acodec pcm_s16le -ar 48000 -ac 1 .\noise.pcm | Out-Null
}
finally { Pop-Location }

# 5) Build dump_features tool
$BuildDir = Join-Path $RepoRoot 'build'
Write-Host "Configuring CMake with tools and examples..."
cmake -S $RepoRoot -B $BuildDir -DBUILD_TOOLS=ON -DBUILD_EXAMPLES=ON -DCMAKE_BUILD_TYPE=$BuildType | Out-Null
Write-Host "Building dump_features..."
cmake --build $BuildDir --config $BuildType --target dump_features | Out-Null

$DumpExe = Join-Path $BuildDir (Join-Path $BuildType 'dump_features.exe')
if (-not (Test-Path $DumpExe)) { $DumpExe = Join-Path $BuildDir 'dump_features.exe' }
if (-not (Test-Path $DumpExe)) { throw "dump_features.exe not found after build." }

# 6) Dump features
Push-Location $RepoRoot
try {
  Write-Host "Dumping features ($FeatureCount sequences)..."
  & $DumpExe .\speech.pcm .\noise.pcm .\features.f32 $FeatureCount
}
finally { Pop-Location }

# 7) Train model (PyTorch)
$ModelsDir = Join-Path $RepoRoot 'models'
<#
Quick examples
  - Synthetic (auto):
      .\pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64
  - Real data (use your WAV folders):
      .\pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100

Notes
- Requires ffmpeg and CMake in PATH.
- Defaults to CPU-only Torch; pass -CPUOnly:$false to try CUDA if available.
- DataMode:
    Auto (default): use data/guitar_clean & data/interfere if they contain WAVs, otherwise synthesize.
    Synthetic: always synthesize into data/guitar_clean and data/interfere.
    Real: use -GuitarDir and -InterfereDir (folders of WAVs; will be resampled to 48 kHz mono).
- Artifacts:
  - features: features.f32
  - checkpoints: models/checkpoints
  - exported C weights copied to src/rnnoise_data.[ch]
  - binaries in build/Release
#>

param(
  [string]$VenvPath = "D:\venvs\rnnoise312",
  [int]$FeatureCount = 100,
  [int]$Epochs = 5,
  [int]$BatchSize = 64,
  [string]$BuildType = "Release",
  [switch]$SkipSynth = $false,
  [switch]$CPUOnly = $true,
  [ValidateSet('Auto','Synthetic','Real')] [string]$DataMode = 'Auto',
  [string]$GuitarDir = '',
  [string]$InterfereDir = '',
  [switch]$FetchFromUrls = $false,
  [string]$GuitarUrls = (Join-Path $PSScriptRoot 'urls_guitar.txt'),
  [string]$NoiseUrls = (Join-Path $PSScriptRoot 'urls_noise.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Repo root: $RepoRoot"

Write-Host "--- Usage / Optional args ---"
Write-Host "  Synthetic (auto):  pipeline_guitar.ps1 -FeatureCount 200 -Epochs 10 -BatchSize 64"
Write-Host "  Real data:         pipeline_guitar.ps1 -DataMode Real -GuitarDir D:\data\guitar -InterfereDir D:\data\noise -FeatureCount 5000 -Epochs 100"
Write-Host "Notes:"
Write-Host "  - Requires ffmpeg and CMake in PATH."
Write-Host "  - Defaults to CPU-only Torch; pass -CPUOnly:`$false to try CUDA."
Write-Host "  - DataMode: Auto|Synthetic|Real (see header for behavior)."
Write-Host "  - Optional fetch: -FetchFromUrls to download from URL lists before training."
Write-Host "Artifacts:"
Write-Host "  - features: features.f32"
Write-Host "  - checkpoints: models/checkpoints"
Write-Host "  - exported C weights copied to src/rnnoise_data.[ch]"
Write-Host "  - binaries in build/Release"

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Command '$name' not found in PATH. Please install it."
  }
}

# 1) Ensure venv exists and get python path
if (-not (Test-Path (Join-Path $VenvPath 'Scripts/python.exe'))) {
  Write-Host "Creating venv at $VenvPath"
  python -m venv $VenvPath
}
$Py = Join-Path $VenvPath 'Scripts/python.exe'
Write-Host "Using Python: $Py"

# 2) Pip setup and deps
& $Py -m pip install --upgrade pip
try { & $Py -m pip config set global.cache-dir "D:/pip-cache" | Out-Null } catch {}
& $Py -m pip install numpy soundfile tqdm
if ($CPUOnly) {
  & $Py -m pip install torch --index-url https://download.pytorch.org/whl/cpu
} else {
  & $Py -m pip install torch
}

# Resolve input data strategy
$DefaultGuitar = Join-Path $RepoRoot 'data/guitar_clean'
$DefaultNoise  = Join-Path $RepoRoot 'data/interfere'

$UseSynth = $false
if ($DataMode -eq 'Real' -or ($GuitarDir -ne '' -or $InterfereDir -ne '')) {
  if ($GuitarDir -eq '' -or $InterfereDir -eq '') { throw "When -DataMode Real, provide both -GuitarDir and -InterfereDir." }
  $GuitarIn = $GuitarDir
  $NoiseIn  = $InterfereDir
  $UseSynth = $false
} elseif ($DataMode -eq 'Synthetic') {
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
  $UseSynth = $true
} else { # Auto
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
  $hasGuitar = (Test-Path $GuitarIn) -and (Get-ChildItem $GuitarIn -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
  $hasNoise  = (Test-Path $NoiseIn)  -and (Get-ChildItem $NoiseIn  -Recurse -Filter *.wav -ErrorAction SilentlyContinue)
  $UseSynth = -not ($hasGuitar -and $hasNoise)
}

# 3) Optional: synthesize small dataset (unless explicitly skipped)
if ($UseSynth -and -not $SkipSynth) {
  Write-Host "Synthesizing guitar/interference WAVs into $DefaultGuitar and $DefaultNoise..."
  & $Py (Join-Path $RepoRoot 'scripts/synthesize_guitar_data.py')
  $GuitarIn = $DefaultGuitar
  $NoiseIn  = $DefaultNoise
}

if (-not (Test-Path $GuitarIn)) { throw "GuitarDir not found: $GuitarIn" }
if (-not (Test-Path $NoiseIn))  { throw "InterfereDir not found: $NoiseIn" }

# Optional: fetch real data from URL lists (runs before concat), targeting the chosen dirs
if ($FetchFromUrls) {
  Write-Host "Fetching real audio using URL lists..."
  $fetchPs1 = Join-Path $RepoRoot 'scripts/fetch_real_data.ps1'
  if (-not (Test-Path $fetchPs1)) { throw "fetch_real_data.ps1 not found at $fetchPs1" }
  # Decide output destinations: if using real or default dirs, ensure they exist
  New-Item -ItemType Directory -Force -Path $GuitarIn | Out-Null
  New-Item -ItemType Directory -Force -Path $NoiseIn  | Out-Null
  & powershell -ExecutionPolicy Bypass -File $fetchPs1 -GuitarUrls $GuitarUrls -NoiseUrls $NoiseUrls -GuitarOut $GuitarIn -NoiseOut $NoiseIn
}

# 4) Concatenate to PCM streams with ffmpeg
Require-Cmd ffmpeg
Push-Location $RepoRoot
try {
  $speechList = Join-Path $RepoRoot 'list_speech.txt'
  $noiseList  = Join-Path $RepoRoot 'list_noise.txt'
  Get-ChildItem $GuitarIn -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $speechList
  Get-ChildItem $NoiseIn  -Recurse -Filter *.wav | ForEach-Object { "file '$( $_.FullName )'" } | Set-Content -Encoding ASCII $noiseList

  if (-not (Test-Path $speechList) -or -not (Get-Content $speechList)) { throw "No WAVs in $GuitarIn." }
  if (-not (Test-Path $noiseList)  -or -not (Get-Content $noiseList))  { throw "No WAVs in $NoiseIn." }

  Write-Host "Building speech.pcm ..."
  ffmpeg -y -f concat -safe 0 -i $speechList -f s16le -acodec pcm_s16le -ar 48000 -ac 1 .\speech.pcm | Out-Null
  Write-Host "Building noise.pcm ..."
  ffmpeg -y -f concat -safe 0 -i $noiseList  -f s16le -acodec pcm_s16le -ar 48000 -ac 1 .\noise.pcm | Out-Null
}
finally { Pop-Location }

# 5) Build dump_features tool
$BuildDir = Join-Path $RepoRoot 'build'
Write-Host "Configuring CMake with tools..."
cmake -S $RepoRoot -B $BuildDir -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=$BuildType | Out-Null
Write-Host "Building dump_features..."
cmake --build $BuildDir --config $BuildType --target dump_features | Out-Null

$DumpExe = Join-Path $BuildDir (Join-Path $BuildType 'dump_features.exe')
if (-not (Test-Path $DumpExe)) { $DumpExe = Join-Path $BuildDir 'dump_features.exe' }
if (-not (Test-Path $DumpExe)) { throw "dump_features.exe not found after build." }

# 6) Dump features
Push-Location $RepoRoot
try {
  Write-Host "Dumping features ($FeatureCount sequences)..."
  & $DumpExe .\speech.pcm .\noise.pcm .\features.f32 $FeatureCount
}
finally { Pop-Location }

# 7) Train model (PyTorch)
$ModelsDir = Join-Path $RepoRoot 'models'
Write-Host "Training PyTorch model for $Epochs epochs..."
& $Py (Join-Path $RepoRoot 'torch/rnnoise/train_rnnoise.py') (Join-Path $RepoRoot 'features.f32') $ModelsDir --epochs $Epochs --batch-size $BatchSize

# 8) Export weights to C and rebuild rnnoise
$Checkpoint = Join-Path $ModelsDir (Join-Path 'checkpoints' ("rnnoise_{0}.pth" -f $Epochs))
if (-not (Test-Path $Checkpoint)) {
  # try latest checkpoint if exact epoch file not found
  $latest = Get-ChildItem (Join-Path $ModelsDir 'checkpoints') -Filter 'rnnoise_*.pth' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { $Checkpoint = $latest.FullName }
}
if (-not (Test-Path $Checkpoint)) { throw "Checkpoint not found in $ModelsDir/checkpoints." }

$COut = Join-Path $ModelsDir 'c'
& $Py (Join-Path $RepoRoot 'torch/rnnoise/dump_rnnoise_weights.py') $Checkpoint $COut --quantize

Copy-Item (Join-Path $COut 'rnnoise_data.*') (Join-Path $RepoRoot 'src') -Force

Write-Host "Building rnnoise library with new weights..."
cmake --build $BuildDir --config $BuildType --target rnnoise | Out-Null

# 9) Build example CLI (rnnoise_demo)
Write-Host "Building rnnoise_demo example..."
cmake --build $BuildDir --config $BuildType --target rnnoise_demo | Out-Null

Write-Host "All done. Outputs:"
Write-Host " - features: $RepoRoot\features.f32"
Write-Host " - checkpoints: $ModelsDir\checkpoints"
Write-Host " - C weights: $COut\rnnoise_data.[ch] copied into src/"
Write-Host " - built binaries in: $BuildDir\$BuildType (includes rnnoise_demo.exe)"
