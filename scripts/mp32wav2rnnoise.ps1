<#!
Convert an MP3 (or any ffmpeg-readable) file to a processed WAV using rnnoise_demo
with guitar isolation gating controls.

Examples:
  # Default gating
  .\mp32wav2rnnoise.ps1 -In "song.mp3" -Out processed\song_rnnoise.wav

  # Bypass gating completely (hear baseline denoiser output)
  .\mp32wav2rnnoise.ps1 -In song.mp3 -Out song_clean.wav -BypassGuitarGate

  # Softer gate (allow more residual)
  .\mp32wav2rnnoise.ps1 -In song.mp3 -Out song_soft.wav -GateMinScale 0.25 -GateThresh 0.30

Parameters map to environment variables consumed in denoise.c when built with GUITAR_ISOLATION_MODE.
#!>
param(
  [Parameter(Mandatory=$true)] [string]$In,
  [Parameter(Mandatory=$true)] [string]$Out,
  [ValidateSet('Debug','Release')] [string]$BuildType = 'Release',
  [double]$GateThresh = 0.42,
  [double]$GateMinScale = 0.10,
  [double]$GateScaleExp = 2.0,
  [double]$GateUpDamp = 0.45,
  [double]$GateSmoothAlpha = 0.60,
  [switch]$BypassGuitarGate = $false,
  [switch]$GuitarGateDebug = $false
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rnnoiseWav = Join-Path $scriptDir 'rnnoise_wav.ps1'
if (-not (Test-Path $rnnoiseWav)) { throw "rnnoise_wav.ps1 not found at $rnnoiseWav" }

& $rnnoiseWav -InWav $In -OutWav $Out -BuildType $BuildType -GateThresh $GateThresh -GateMinScale $GateMinScale -GateScaleExp $GateScaleExp -GateUpDamp $GateUpDamp -GateSmoothAlpha $GateSmoothAlpha -BypassGuitarGate:$BypassGuitarGate -GuitarGateDebug:$GuitarGateDebug