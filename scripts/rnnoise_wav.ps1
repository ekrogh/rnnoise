param(
    [Parameter(Mandatory=$true)] [string]$InWav,
    [Parameter(Mandatory=$true)] [string]$OutWav,
    [string]$Model = 'model.onnx',
    [ValidateSet('Debug','Release')] [string]$BuildType = 'Release',
    [switch]$GuitarOnly,
    [double]$GuitarThreshold = 0.55,
    [double]$GuitarAttenDB = -40,
    [double]$ProbFloor = 0.0,
    [double]$EnergyThreshold = 0.0,
    [double]$MinScale = 0.0,
    [string]$DumpProbCsv = '',
    [double]$AdaptiveFactor = 0.0,
    [double]$EmaAlpha = 0.0,
    [switch]$SoftMask,
    [double]$Gamma = 0.0,
    # Instrumentation / debugging
    [int]$DebugFirstN = 0,
    [double]$ForceThreshold = -1,
    [switch]$DumpProbHist,
    [switch]$Diagnostics,
    [switch]$ForceRebuild = $false,
    [switch]$AutoBuild = $true
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Error $msg; exit 1 }

# Resolve paths
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Locate ONNX demo (PURE_ONNX) executable
$onnxExeCandidates = @(
    (Join-Path $repoRoot "build_pure\$BuildType\eks_rnnoise_demo_onnx.exe"),
    (Join-Path $repoRoot "build\$BuildType\eks_rnnoise_demo_onnx.exe")
)
$onnxExe = $onnxExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($ForceRebuild) {
    Write-Host "[FORCE-REBUILD] Force rebuild requested for eks_rnnoise_demo_onnx.exe" -ForegroundColor Yellow
}
if (-not $onnxExe -or $ForceRebuild) {
    if ($AutoBuild) {
        Write-Host "[AUTO-BUILD] eks_rnnoise_demo_onnx.exe missing. Attempting to build (PURE_ONNX)." -ForegroundColor Yellow
        if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
            Fail "cmake not found on PATH. Install CMake or run manual build: cmake -S . -B build_pure -DPURE_ONNX=ON -DBUILD_EXAMPLES=ON -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=$BuildType; cmake --build build_pure --config $BuildType --target eks_rnnoise_demo_onnx"
        }
        $buildDir = Join-Path $repoRoot 'build_pure'
        if (-not (Test-Path -LiteralPath $buildDir)) { New-Item -ItemType Directory -Path $buildDir | Out-Null }
        & cmake -S $repoRoot -B $buildDir -DPURE_ONNX=ON -DBUILD_EXAMPLES=ON -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=$BuildType 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "CMake configure failed for PURE_ONNX build." }
        & cmake --build $buildDir --config $BuildType --target eks_rnnoise_demo_onnx 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "CMake build failed for eks_rnnoise_demo_onnx." }
        $onnxExe = $onnxExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($onnxExe) {
            Write-Host "[AUTO-BUILD] Build succeeded: $onnxExe" -ForegroundColor Green
        } else {
            Fail "Auto-build completed but eks_rnnoise_demo_onnx.exe still not found (searched: $($onnxExeCandidates -join ', '))"
        }
    } else {
        Fail "eks_rnnoise_demo_onnx.exe not found. Build with -DRNNOISE_PURE_ONNX=ON (searched: $($onnxExeCandidates -join ', '))"
    }
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Fail "ffmpeg is required on PATH." }
if (-not (Test-Path -LiteralPath $InWav)) { Fail "Input audio not found: $InWav" }
if (-not (Test-Path -LiteralPath $Model)) { Fail "Model ONNX not found: $Model" }
else { $Model = (Resolve-Path -LiteralPath $Model).Path }

# Temp files
$tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("rnnoise-" + [guid]::NewGuid()))
try {
    $pcmIn  = Join-Path $tmp.FullName 'in.pcm'
    $pcmOut = Join-Path $tmp.FullName 'out.pcm'
    $wav48k = Join-Path $tmp.FullName 'in48k.wav'

    Write-Host "[1/3] Resampling/formatting input to 48 kHz mono..."
    ffmpeg -y -hide_banner -loglevel error -i "$InWav" -ac 1 -ar 48000 "$wav48k"
    ffmpeg -y -hide_banner -loglevel error -i "$wav48k" -f s16le -ac 1 -ar 48000 "$pcmIn"

    Write-Host "[2/3] Running ONNX guitar-isolation model..."
    $args = @("$pcmIn", "$pcmOut", "$Model")
    if ($GuitarOnly) {
        $thr = $GuitarThreshold.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $att = $GuitarAttenDB.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $args += @('--guitar-only', '--guitar-threshold', $thr, '--guitar-atten-db', $att)
        if ($ProbFloor -gt 0) { $args += @('--prob-floor', ($ProbFloor.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($EnergyThreshold -gt 0) { $args += @('--energy-threshold', ($EnergyThreshold.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($MinScale -gt 0) { $args += @('--min-scale', ($MinScale.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($DumpProbCsv) { $args += @('--dump-prob-csv', $DumpProbCsv) }
        if ($AdaptiveFactor -gt 0) { $args += @('--adaptive-factor', ($AdaptiveFactor.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($EmaAlpha -gt 0 -and $EmaAlpha -le 1) { $args += @('--ema-alpha', ($EmaAlpha.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($DebugFirstN -gt 0) { $args += @('--debug-first-n', ($DebugFirstN.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($ForceThreshold -ge 0 -and $ForceThreshold -le 1) { $args += @('--force-threshold', ($ForceThreshold.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
        if ($DumpProbHist) { $args += '--dump-prob-hist' }
        if ($SoftMask) { $args += '--soft-mask' }
        if ($Gamma -gt 0) { $args += @('--gamma', ($Gamma.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
    }
    $attemptedRebuild = $false
    for ($attempt=1; $attempt -le 2; $attempt++) {
        $execOutput = & "$onnxExe" @args 2>&1
        $exit = $LASTEXITCODE
        if ($execOutput) {
            $execOutput | ForEach-Object {
                $lineStr = $_
                if ($lineStr -is [System.Management.Automation.ErrorRecord]) { $lineStr = $lineStr.ToString() }
                if ($null -ne $lineStr) { $lineStr = [string]$lineStr }
                if ([string]::IsNullOrWhiteSpace($lineStr)) { return }
                # Always surface key summary / gating lines, ONNX debug, keep rest verbose
                if ($Diagnostics -and $lineStr -notmatch '^\[SUMMARY\]' -and $lineStr -notmatch '^\[GATING\]' -and $lineStr -notmatch '^\[RNNoise\]' -and $lineStr -notmatch '^\[ONNX\]\[DBG\]') {
                    Write-Host $lineStr -ForegroundColor DarkGray
                }
                if ($lineStr -match '^\[SUMMARY\]' -or $lineStr -match '^\[GATING\]' -or $lineStr -match '^\[RNNoise\]' -or $lineStr -match '^\[ONNX\]\[DBG\]' ) {
                    Write-Host $lineStr
                } else {
                    Write-Verbose "[onnx-exe] $lineStr"
                }
            }
        }
        $unknownAdaptive = ($execOutput -match 'Unknown option: --adaptive-factor') -or ($execOutput -match 'Unknown option: --ema-alpha')
        $pcmExists = Test-Path -LiteralPath $pcmOut
        if (-not $unknownAdaptive -and $pcmExists -and $exit -eq 0) { break }
        if ($unknownAdaptive -and $AutoBuild -and -not $attemptedRebuild) {
            Write-Warning "Detected legacy eks_rnnoise_demo_onnx.exe without adaptive flag support. Rebuilding (PURE_ONNX) ..."
            $attemptedRebuild = $true
            $buildDir = Join-Path $repoRoot 'build_pure'
            & cmake -S $repoRoot -B $buildDir -DPURE_ONNX=ON -DBUILD_EXAMPLES=ON -DBUILD_TOOLS=ON -DCMAKE_BUILD_TYPE=$BuildType 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "Reconfigure failed while rebuilding adaptive-capable binary." }
            & cmake --build $buildDir --config $BuildType --target eks_rnnoise_demo_onnx 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "Rebuild failed for eks_rnnoise_demo_onnx (adaptive support)." }
            $onnxExe = (Join-Path $buildDir "$BuildType\eks_rnnoise_demo_onnx.exe")
            if (-not (Test-Path -LiteralPath $onnxExe)) { Fail "Rebuilt binary not found at $onnxExe" }
            Write-Host "[AUTO-BUILD] Rebuilt adaptive-capable binary: $onnxExe" -ForegroundColor Green
            continue
        }
        if (-not $pcmExists -or $exit -ne 0) {
            Fail "ONNX demo execution failed (exit=$exit, pcmOut exists=$pcmExists). Output snippet: $($execOutput | Select-Object -First 3 | Out-String)"
        }
    }

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
