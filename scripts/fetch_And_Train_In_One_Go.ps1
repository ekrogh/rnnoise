# Fetch and train in one go
# pwsh
param(
	[switch]$AllowInsecure = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

$PipelineGuitarPs1 = Join-Path $ScriptDir 'pipeline_guitar.ps1'
$GuitarOut         = Join-Path $RepoRoot  'data/guitar_clean'
$InterfereDir      = Join-Path $RepoRoot  'data/interfere'

& $PipelineGuitarPs1 -DataMode Real -GuitarDir $GuitarOut -InterfereDir $InterfereDir -FetchFromUrls -FeatureCount 5000 -Epochs 100

# pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\pipeline_guitar.ps1 `
#   -DataMode Auto -Threads 0 -MaxConcatSecondsSpeech 600 -MaxConcatSecondsNoise 600 `
#   -FeatureCount 5000 -Epochs 10 -BatchSize 128
