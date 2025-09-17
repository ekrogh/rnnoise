param(
    [Parameter(Mandatory=$true)] [string]$InWav,
    [Parameter(Mandatory=$true)] [string]$OutWav,
    [ValidateSet('Debug','Release')] [string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Error $msg; exit 1 }

# Resolve paths
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$demoExe  = Join-Path $repoRoot "build\$BuildType\rnnoise_demo.exe"

if (-not (Test-Path $demoExe)) { Fail "rnnoise_demo not found: $demoExe. Build with examples enabled." }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Fail "ffmpeg is required on PATH." }
if (-not (Test-Path -LiteralPath $InWav)) { Fail "Input audio not found: $InWav" }

# Temp files
$tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("rnnoise-" + [guid]::NewGuid()))
try {
    $pcmIn  = Join-Path $tmp.FullName 'in.pcm'
    $pcmOut = Join-Path $tmp.FullName 'out.pcm'
    $wav48k = Join-Path $tmp.FullName 'in48k.wav'

    Write-Host "[1/3] Resampling/formatting input to 48 kHz mono..."
    ffmpeg -y -hide_banner -loglevel error -i "$InWav" -ac 1 -ar 48000 "$wav48k"
    ffmpeg -y -hide_banner -loglevel error -i "$wav48k" -f s16le -ac 1 -ar 48000 "$pcmIn"

    Write-Host "[2/3] Running rnnoise_demo..."
    & "$demoExe" "$pcmIn" "$pcmOut" | Out-Null

    Write-Host "[3/3] Converting output to WAV..."
    # Build an absolute output path without requiring the file to already exist
    $outDir  = Split-Path -Path $OutWav -Parent
    $outName = Split-Path -Path $OutWav -Leaf
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        $outDir = (Get-Location).Path
    } else {
        $outDir = (Resolve-Path -LiteralPath $outDir).Path
    }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $outFull = Join-Path $outDir $outName
    ffmpeg -y -hide_banner -loglevel error -f s16le -ac 1 -ar 48000 -i "$pcmOut" "$outFull"

    Write-Host "Done -> $outFull"
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
}
