param(
    [Parameter(Mandatory=$true)] [string]$InWav,
    [Parameter(Mandatory=$true)] [string]$OutWav,
    [ValidateSet('Debug','Release')] [string]$BuildType = 'Release',
    [double]$GateThresh = 0.42,
    [double]$GateMinScale = 0.10,
    [double]$GateScaleExp = 2.0,
    [double]$GateUpDamp = 0.45,
    [double]$GateSmoothAlpha = 0.60,
    [switch]$BypassGuitarGate = $false,
    [switch]$GuitarGateDebug = $false
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Error $msg; exit 1 }

# Resolve paths
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$demoExe  = Join-Path $repoRoot "build\$BuildType\rnnoise_demo.exe"

if (-not (Test-Path $demoExe)) { Fail "rnnoise_demo not found: $demoExe. Build with examples enabled (cmake -DBUILD_EXAMPLES=ON)." }
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

    # Export gating env vars (if not bypassed)
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    if ($BypassGuitarGate) {
        $env:RN_GUITAR_BYPASS = '1'
        Write-Host "[2/3] Running rnnoise_demo (GUITAR GATE BYPASSED)..."
    } else {
        $env:RN_GUITAR_GATE_THRESH = $GateThresh.ToString($ci)
        $env:RN_GUITAR_MIN_SCALE   = $GateMinScale.ToString($ci)
        $env:RN_GUITAR_SCALE_EXP   = $GateScaleExp.ToString($ci)
        $env:RN_GUITAR_UP_DAMP     = $GateUpDamp.ToString($ci)
        $env:RN_GUITAR_SMOOTH_ALPHA= $GateSmoothAlpha.ToString($ci)
        if ($GuitarGateDebug) { $env:RN_GUITAR_DEBUG = '1' }
        Write-Host ("[2/3] Running rnnoise_demo (gate thresh={0} min={1} exp={2} up={3} smooth={4} bypass={5})" -f $GateThresh,$GateMinScale,$GateScaleExp,$GateUpDamp,$GateSmoothAlpha,$BypassGuitarGate)
    }
    & "$demoExe" "$pcmIn" "$pcmOut" | Out-Null

    Write-Host "[3/3] Converting output to WAV..."
    # Build an absolute output path without requiring the file to already exist
    $outDir  = Split-Path -Path $OutWav -Parent
    $outName = Split-Path -Path $OutWav -Leaf
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        $outDir = (Get-Location).Path
    } else {
        # Create directory if it doesn't exist rather than resolving first
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        # Now safely resolve to an absolute path
        $outDir = (Resolve-Path -LiteralPath $outDir).Path
    }
    $outFull = Join-Path $outDir $outName
    ffmpeg -y -hide_banner -loglevel error -f s16le -ac 1 -ar 48000 -i "$pcmOut" "$outFull"

    Write-Host "Done -> $outFull"
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
}
