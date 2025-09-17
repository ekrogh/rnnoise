param(
  [ValidateSet('Auto','Synthetic','Real')] [string]$DataMode = 'Auto',
  [int]$FeatureCount = 10000,
  [int]$Epochs = 15,
  [int]$BatchSize = 32,
  [int]$SequenceLength = 1500,
  [int]$GruSize = 256,
  [int]$CondSize = 128,
  [string]$BuildType = 'Release',
  [switch]$CPUOnly = $false,
  [string]$CudaVisibleDevices = '0',
  [string]$GuitarDir = '',
  [string]$InterfereDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# Unblock common files to avoid prompts
try {
  Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.ps1','.psm1','.psd1','.exe','.dll','.bat','.py' } |
    Unblock-File -ErrorAction SilentlyContinue
} catch {}

# Build argument list for run_unattended_train.ps1
$scriptPath = Join-Path $RepoRoot 'scripts/run_unattended_train.ps1'
if (-not (Test-Path $scriptPath)) { throw "run_unattended_train.ps1 not found at $scriptPath" }

$args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $scriptPath,
  '-DataMode', $DataMode,
  '-FeatureCount', "$FeatureCount",
  '-Epochs', "$Epochs",
  '-BatchSize', "$BatchSize",
  '-SequenceLength', "$SequenceLength",
  '-GruSize', "$GruSize",
  '-CondSize', "$CondSize",
  '-BuildType', $BuildType,
  '-CudaVisibleDevices', $CudaVisibleDevices
)
if ($CPUOnly) { $args += @('-CPUOnly:$true') } else { $args += @('-CPUOnly:$false') }
if ($DataMode -eq 'Real') {
  if (-not $GuitarDir -or -not $InterfereDir) { throw 'When -DataMode Real, provide -GuitarDir and -InterfereDir.' }
  $args += @('-GuitarDir', $GuitarDir, '-InterfereDir', $InterfereDir)
}

Write-Host 'Launching unattended training in background...'
Start-Process -FilePath 'pwsh' -ArgumentList $args -WorkingDirectory $RepoRoot -WindowStyle Hidden | Out-Null

# Try to show initial log lines
$logsDir = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

Write-Host 'Waiting for log to appear...'
$log = $null
for ($i=0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 1
  $latest = Get-ChildItem -Path $logsDir -Filter 'pipeline_*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { $log = $latest.FullName; break }
}

if ($log) {
  Write-Host "Log: $log"
  try { Get-Content -Path $log -TotalCount 60 } catch {}
  Write-Host '--- tail ---'
  try { Get-Content -Path $log -Tail 60 } catch {}
} else {
  Write-Host 'No log found yet. Training should be starting shortly.'
}
