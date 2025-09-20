[CmdletBinding()] # enables common parameters like -Verbose without redefining them
param(
    [Parameter(Mandatory=$true)][string]$AlbumDir,
    [string]$TempDir = "$PSScriptRoot/../build/album_eval_temp",
    [string]$DemoExe = "$PSScriptRoot/../build/Release/eks_rnnoise_demo.exe",
    [string]$Ffmpeg = 'ffmpeg',
    [string]$MetricsCsv = "$PSScriptRoot/../build/album_metrics.csv",
    [switch]$IncludeWav,
    [int]$Limit = 0,
    [switch]$NoRetry
)

# Ensures directory exists
function Ensure-Dir($d) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

Ensure-Dir $TempDir

function Resolve-Python {
    # Priority order:
    # 1) Existing venv used by training (look for rnnoise* under D:\venvs or local 'venv')
    # 2) 'python' on PATH
    $candidates = @()
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $localVenv = Join-Path $repoRoot 'venv/ Scripts/python.exe'
    if (Test-Path $localVenv) { $candidates += $localVenv }
    $globalVenvRoot = 'D:\venvs'
    if (Test-Path $globalVenvRoot) {
        $candidates += (Get-ChildItem $globalVenvRoot -Directory -Filter 'rnnoise*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'Scripts/python.exe' })
    }
    $candidates = $candidates | Where-Object { $_ -and (Test-Path $_) }
    foreach ($c in $candidates) { return $c }
    return 'python'
}
$PythonExe = Resolve-Python

# Detect demo feature support (whether current binary understands --prob-out)
if (-not (Test-Path -LiteralPath $DemoExe)) { Write-Error "Demo exe not found: $DemoExe"; exit 1 }
$demoUsage = & $DemoExe 2>&1 | Out-String
$SupportsProbOut = $false
if ($demoUsage -match '--prob-out') { $SupportsProbOut = $true }
if ($PSBoundParameters.ContainsKey('Verbose')) {
    Write-Host "Demo capability: --prob-out supported = $SupportsProbOut" -ForegroundColor DarkCyan
}

# Allow a single file path as input
if (Test-Path -LiteralPath $AlbumDir -PathType Leaf) {
    $ext = [IO.Path]::GetExtension($AlbumDir).ToLowerInvariant()
    if ($ext -notin @('.mp3','.wav')) { Write-Error "Unsupported file extension: $ext"; exit 1 }
    $audioFiles = @(Get-Item -LiteralPath $AlbumDir)
} else {
    $patterns = @('*.mp3')
    if ($IncludeWav) { $patterns += '*.wav' }
    $tempList = @()
    foreach ($pat in $patterns) {
            $temp = Get-ChildItem -LiteralPath $AlbumDir -Filter $pat -Recurse -ErrorAction SilentlyContinue
            if ($temp) { $tempList += $temp }
    }
    $audioFiles = $tempList | Sort-Object Name -Unique
}
if (-not $audioFiles -or $audioFiles.Count -eq 0) { Write-Error "No audio files found under $AlbumDir"; exit 1 }
if ($Limit -gt 0 -and $audioFiles.Count -gt $Limit) { $audioFiles = $audioFiles | Select-Object -First $Limit }
$formats = 'mp3'
if ($IncludeWav) { $formats += '/wav' }
Write-Host "Found $($audioFiles.Count) audio tracks ($formats)." -ForegroundColor Cyan

$results = @()
$trackIndex = 0
foreach ($m in $audioFiles) {
    $trackIndex++
    $base = [IO.Path]::GetFileNameWithoutExtension($m.Name)
    $wavOrig = Join-Path $TempDir "$base.orig.wav"
    $rawIn = Join-Path $TempDir "$base.in.raw"
    $rawOut = Join-Path $TempDir "$base.out.raw"
    $wavOut = Join-Path $TempDir "$base.proc.wav"
    $probCsv = Join-Path $TempDir "$base.prob.csv"
    $demoLog = Join-Path $TempDir "$base.demo.log"

    if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Converting to wav: $($m.FullName)" -ForegroundColor Yellow }
    & $Ffmpeg -y -i $m.FullName -ac 1 -ar 48000 -f wav $wavOrig 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "ffmpeg failed for $($m.FullName), skipping"; continue }

    # Convert WAV to raw 16-bit little endian
        if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Converting wav to raw" }
    & $Ffmpeg -y -i $wavOrig -f s16le -acodec pcm_s16le $rawIn 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "ffmpeg raw conversion failed for $wavOrig, skipping"; continue }

    if (-not (Test-Path -LiteralPath $DemoExe)) { Write-Error "Demo exe not found: $DemoExe"; exit 1 }

    if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Running demo" -ForegroundColor Green }
    $maskCsv = $null
    if (-not $SupportsProbOut) {
        # We'll produce a mask CSV (frame,guitar_prob,g0..gN) then derive a prob-only CSV
        $maskCsv = Join-Path $TempDir "$base.mask.csv"
        $demoCmdArgs = @($rawIn, $rawOut, '--guitar-mask', $maskCsv)
    } else {
        $demoCmdArgs = @($rawIn, $rawOut, '--prob-out', $probCsv)
    }
    $demoOutput = & $DemoExe @demoCmdArgs *>&1
    $demoExit = $LASTEXITCODE
    if ($demoExit -ne 0) {
        $demoOutput | Out-File -Encoding utf8 -FilePath $demoLog
        Write-Warning "Demo failed for $base (exit $demoExit). Logged to $demoLog"
        if (-not $NoRetry) {
            # Retry with sanitized short filenames (removes spaces/special chars)
            $sanitized = ($base -replace '[^A-Za-z0-9_]','_')
            if (-not $sanitized) { $sanitized = "track_$trackIndex" }
            $shortIn = Join-Path $TempDir ("{0}.retry.in.raw" -f $sanitized)
            $shortOut = Join-Path $TempDir ("{0}.retry.out.raw" -f $sanitized)
            $shortProb = Join-Path $TempDir ("{0}.retry.prob.csv" -f $sanitized)
            Copy-Item -LiteralPath $rawIn -Destination $shortIn -Force -ErrorAction SilentlyContinue
            if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Retrying demo with sanitized names: $sanitized" -ForegroundColor DarkYellow }
            if (-not $SupportsProbOut) {
                $shortMask = Join-Path $TempDir ("{0}.retry.mask.csv" -f $sanitized)
                $retryArgs = @($shortIn, $shortOut, '--guitar-mask', $shortMask)
            } else {
                $retryArgs = @($shortIn, $shortOut, '--prob-out', $shortProb)
            }
            $retryOutput = & $DemoExe @retryArgs *>&1
            $retryExit = $LASTEXITCODE
            if ($retryExit -ne 0) {
                $retryLog = Join-Path $TempDir ("{0}.retry.demo.log" -f $sanitized)
                $retryOutput | Out-File -Encoding utf8 -FilePath $retryLog
                Write-Warning "Retry demo failed for $base (exit $retryExit). Logged to $retryLog"
                continue
            } else {
                if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Retry succeeded" -ForegroundColor Green }
                # Use retry outputs for downstream steps
                $rawOut = $shortOut
                $probCsv = $shortProb
                if (-not $SupportsProbOut) { $maskCsv = $shortMask }
            }
        } else {
            continue
        }
    }

    # If we only have mask CSV, derive probability-only CSV for metrics
    if (-not $SupportsProbOut) {
        if (-not (Test-Path -LiteralPath $maskCsv)) { Write-Warning "Mask CSV missing after demo for $base"; continue }
        try {
            $lines = Get-Content -LiteralPath $maskCsv
            if ($lines.Count -gt 0) {
                $outLines = @('frame,guitar_prob')
                for ($li=1; $li -lt $lines.Count; $li++) {
                    $parts = $lines[$li].Split(',')
                    if ($parts.Length -ge 2) { $outLines += ("{0},{1}" -f $parts[0], $parts[1]) }
                }
                $outLines | Set-Content -LiteralPath $probCsv -Encoding utf8
                if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Derived prob CSV from mask: $(Split-Path -Leaf $probCsv)" -ForegroundColor DarkGreen }
            } else {
                Write-Warning "Mask CSV empty for $base"
                continue
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-Warning ("Failed to derive prob CSV for {0}: {1}" -f $base, $errMsg)
            continue
        }
    }

    # Convert processed raw back to wav for metrics
    & $Ffmpeg -y -f s16le -ar 48000 -ac 1 -i $rawOut $wavOut 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "ffmpeg raw->wav failed for $base"; continue }

    if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "[$trackIndex] Computing metrics" }
    # Ensure metrics CSV header supports 'track' if we are adding it (migrate old file if needed)
    if (Test-Path -LiteralPath $MetricsCsv) {
        try {
            $firstLine = Get-Content -LiteralPath $MetricsCsv -TotalCount 1
            if ($firstLine -and $firstLine -notmatch '^track,') {
                $bak = "$MetricsCsv.pre_track.bak"
                if (-not (Test-Path -LiteralPath $bak)) { Rename-Item -LiteralPath $MetricsCsv -NewName (Split-Path -Leaf $bak) }
                if ($PSBoundParameters.ContainsKey('Verbose')) { Write-Host "Migrated existing metrics CSV to add track column (backup: $bak)" -ForegroundColor DarkCyan }
            }
        } catch {}
    }
    & $PythonExe $PSScriptRoot/eval_album_metrics.py --original $wavOrig --processed $wavOut --probs $probCsv --out-csv $MetricsCsv --track $base
    if ($LASTEXITCODE -ne 0) { Write-Warning "Metrics failed for $base"; continue }
}

Write-Host "Album evaluation complete. Metrics aggregated at $MetricsCsv" -ForegroundColor Cyan
