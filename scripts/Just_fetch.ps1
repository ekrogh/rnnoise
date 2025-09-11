<#
Just fetch real audio using URL lists next to this script.
Run:
	pwsh
	scripts/Just_fetch.ps1
#>

param(
	[switch]$AllowInsecure = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

$FetchPs1   = Join-Path $ScriptDir 'fetch_real_data.ps1'
$GuitarUrls = Join-Path $ScriptDir 'urls_guitar.txt'
$NoiseUrls  = Join-Path $ScriptDir 'urls_noise.txt'
$GuitarOut  = Join-Path $RepoRoot 'data/guitar_clean'
$NoiseOut   = Join-Path $RepoRoot 'data/interfere'

Write-Host "ScriptDir: $ScriptDir"
Write-Host "RepoRoot : $RepoRoot"
Write-Host "Fetching -> GuitarOut=$GuitarOut NoiseOut=$NoiseOut"

# Add -AllowInsecure if your network MITMs TLS or SNI breaks; falls back to curl --insecure.
& $FetchPs1 -GuitarUrls $GuitarUrls -NoiseUrls $NoiseUrls -GuitarOut $GuitarOut -NoiseOut $NoiseOut -AllowInsecure:$AllowInsecure -UseParallel -ParallelJobs 8 -FfmpegThreadsPerJob 1

# pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch_real_data.ps1 `
#   -GuitarUrls .\scripts\urls_guitar.txt -NoiseUrls .\scripts\urls_noise.txt `
#   -UseParallel -ParallelJobs 8 -FfmpegThreadsPerJob 1
