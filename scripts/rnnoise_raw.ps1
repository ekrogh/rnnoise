param(
    [Parameter(Mandatory=$true)][string]$InRaw,
    [Parameter(Mandatory=$true)][string]$OutRaw,
    [ValidateSet('Legacy','PureONNX')][string]$Mode = 'PureONNX',
    [string]$Model = 'model.onnx',
    [ValidateSet('Debug','Release')][string]$BuildType = 'Release'
)

<#!
 rnnoise_raw.ps1
 Purpose: Run raw 16-bit mono 48 kHz PCM through RNNoise (legacy or PURE_ONNX) without WAV conversion.

 Usage examples:
   # PURE_ONNX (default) using model.onnx in repo root
   pwsh ./scripts/rnnoise_raw.ps1 -InRaw input.raw -OutRaw output.raw

   # Explicit model path
   pwsh ./scripts/rnnoise_raw.ps1 -InRaw input.raw -OutRaw output.raw -Model checkpoints/full_20250920_222048/rnnoise.onnx

   # Legacy embedded build
   pwsh ./scripts/rnnoise_raw.ps1 -InRaw input.raw -OutRaw output.raw -Mode Legacy

 Requirements:
   - Input: 16-bit little-endian PCM, mono, 48 kHz (FRAME_SIZE=480 alignment optional; trailing partial frame ignored)
   - Built executables:
       Legacy   : build/<BuildType>/rnnoise_demo.exe
       PureONNX : build_pure/<BuildType>/eks_rnnoise_demo_onnx.exe

 Notes:
   - For PURE_ONNX if Model not located in the working directory and not passed explicitly, specify -Model.
   - This script does not convert formats; use ffmpeg beforehand if you start from WAV or other sample rates.
#>

$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Error $m; exit 1 }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if(-not (Test-Path -LiteralPath $InRaw)) { Fail "Input raw PCM not found: $InRaw" }
if([IO.Path]::GetExtension($InRaw) -eq '.wav') { Write-Warning 'Input seems to be a WAV file; this script expects raw PCM (no header). Convert first.' }

$exe = $null
switch($Mode) {
  'Legacy'   { $exe = Join-Path $repoRoot "build/$BuildType/rnnoise_demo.exe" }
  'PureONNX' { $exe = Join-Path $repoRoot "build_pure/$BuildType/eks_rnnoise_demo_onnx.exe" }
}
if(-not (Test-Path $exe)) { Fail "Required executable not found: $exe (build with appropriate flags)." }

if($Mode -eq 'PureONNX') {
  if(-not (Test-Path -LiteralPath $Model)) {
    # If user passed relative path check relative to repo root
    $modelRepo = Join-Path $repoRoot $Model
    if(Test-Path -LiteralPath $modelRepo) { $Model = $modelRepo } else { Fail "ONNX model not found: $Model" }
  }
  Write-Host "[RNNOISE][RAW] PURE_ONNX mode -> $exe (model=$Model)" -ForegroundColor Cyan
  & $exe $InRaw $OutRaw $Model
} else {
  Write-Host "[RNNOISE][RAW] Legacy mode -> $exe" -ForegroundColor Cyan
  & $exe $InRaw $OutRaw
}

if($LASTEXITCODE -ne 0) { Fail "Execution failed (exit $LASTEXITCODE)." }
if(-not (Test-Path -LiteralPath $OutRaw)) { Fail "Output not produced: $OutRaw" }

# Basic size sanity (not fatal): ensure at least one frame (480 samples) processed
try {
  $bytes = (Get-Item $OutRaw).Length
  if($bytes -lt 480*2) { Write-Warning "Output shorter than one 10ms frame (bytes=$bytes)" }
} catch { }

Write-Host "Done -> $OutRaw" -ForegroundColor Green
