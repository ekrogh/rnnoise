<#
Downloads real audio from URL lists, extracts archives, and converts to 48 kHz mono WAV.

Examples
  .\fetch_real_data.ps1 -GuitarUrls .\scripts\urls_guitar.txt -NoiseUrls .\scripts\urls_noise.txt \
    -GuitarOut .\data\guitar_clean -NoiseOut .\data\interfere

Notes
- Provide plain text files where each non-empty, non-comment line is a URL to an audio file or zip archive.
- Supported inputs: wav, flac, mp3, ogg, m4a, aiff/aif, zip (contains audio). Tries tar for .tar.gz/.tgz if available.
- Requires: ffmpeg; optional: tar (for .tar.gz).
- Auto Medley mode: if BOTH of these appear in your guitar URL list during one run:
    • Medley-solos-DB.tar.gz (or .tgz)
    • Medley-solos-DB_metadata.csv
  then instrument filtering is automatically enabled (default allow: guitar, electric_guitar, acoustic_guitar),
  parallel conversion is auto-enabled, and ParallelJobs defaults to CPU count unless overridden.
 - Optional labels: You can prefix lines with 'Archive:' or 'Metadata:' to disambiguate. Labels are recognized for
   auto-detection but downloads use the URL after the label.
#>

param(
  [string]$GuitarUrls = '',
  [string]$NoiseUrls = '',
  [string]$GuitarOut = "",
  [string]$NoiseOut = "",
  [string]$TempDownloadDir = "",
  [switch]$AllowInsecure = $false,
  [switch]$UseParallel = $true,
  [int]$ParallelJobs = 4,
  [int]$FfmpegThreadsPerJob = 1,
  [switch]$PreferMedleyCsv = $true,
  [string[]]$InstrumentAllowList = @('guitar','electric_guitar','acoustic_guitar')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Track label hints from URL files (so we can infer missing extensions)
$script:ArchiveHints  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:MetadataHints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Command '$name' not found in PATH. Please install it."
  }
}

function New-TempDir([string]$prefix) {
  $d = Join-Path ([IO.Path]::GetTempPath()) ("$prefix-" + [guid]::NewGuid())
  return (New-Item -ItemType Directory -Path $d)
}

function Read-Urls([string]$file) {
  if (-not (Test-Path $file)) { return @() }
  $lines = Get-Content $file | Where-Object { $_ -and $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
  $urls = @()
  foreach ($line in $lines) {
    $t = $line.Trim()
    # Support optional labels like "Archive:" or "Metadata:" before the URL
    $m = [regex]::Match($t, '^(?:(?<label>Archive|Metadata)\s*:\s*)?(?<url>https?://.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { $urls += $m.Groups['url'].Value }
    else { $urls += $t }
    if ($m.Success -and $m.Groups['label'].Success) {
      $u = $m.Groups['url'].Value
      $lab = $m.Groups['label'].Value.ToLower()
      if ($lab -eq 'archive') { [void]$script:ArchiveHints.Add($u) }
      elseif ($lab -eq 'metadata') { [void]$script:MetadataHints.Add($u) }
    }
  }
  return $urls
}

# Build a safe local filename from a URL (strip query string, invalid chars)
function Get-SafeFileName([string]$url, [int]$index) {
  try {
    $uri = [Uri]$url
    $fname = [IO.Path]::GetFileName($uri.AbsolutePath)
  } catch { $fname = $null }
  if (-not $fname -or $fname.Trim() -eq '') { $fname = "file_$index" }
  # Decode percent-encoding, then remove invalid filename characters
  try { $fname = [Uri]::UnescapeDataString($fname) } catch {}
  $invalid = [IO.Path]::GetInvalidFileNameChars()
  foreach ($ch in $invalid) { $fname = $fname.Replace($ch, '_') }
  return $fname
}

Require-Cmd ffmpeg

# Prefer TLS 1.2 for HTTPS downloads (fixes many 403/SSL issues on older defaults)
try {
  $tls12 = [Net.SecurityProtocolType]::Tls12
  if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -eq 0) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
  }
  if ($AllowInsecure) {
    # As a last resort, trust all certs (older PowerShell versions don't support -SkipCertificateCheck)
    try {
      add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public static class TrustAllCertsPolicy {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object s, X509Certificate certificate, X509Chain chain, System.Net.Security.SslPolicyErrors sslPolicyErrors) { return true; };
    }
}
"@
      [TrustAllCertsPolicy]::Enable()
      Write-Warning "AllowInsecure enabled: SSL certificate validation is disabled for this process. Use only on trusted networks/sources."
    } catch {}
  }
} catch {}

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $GuitarOut -or $GuitarOut -eq '') { $GuitarOut = Join-Path $RepoRoot 'data/guitar_clean' }
if (-not $NoiseOut  -or $NoiseOut  -eq '') { $NoiseOut  = Join-Path $RepoRoot 'data/interfere' }
New-Item -ItemType Directory -Force -Path $GuitarOut | Out-Null
New-Item -ItemType Directory -Force -Path $NoiseOut  | Out-Null

$dlRoot = if ($TempDownloadDir -and $TempDownloadDir -ne '') { New-Item -ItemType Directory -Force -Path $TempDownloadDir } else { New-TempDir 'rnnoise-dl' }

try {
  $audioExt = @('.wav','.flac','.mp3','.ogg','.m4a','.aiff','.aif','.aifc')
  $archiveExt = @('.zip','.tar.gz','.tgz')

  function Get-UrlVariants([string]$u) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($u)
    # If ends with .tgz, also try .tar.gz
    if ($u.ToLower().EndsWith('.tgz')) {
      $candidates.Add($u.Substring(0, $u.Length-4) + '.tar.gz')
    }
    # If labeled Archive but missing known archive extension, try common archive suffixes (+ optional ?download=1)
    try {
      $uri = [Uri]$u
      $path = $uri.AbsolutePath
      $ext = [IO.Path]::GetExtension($path)
    } catch { $ext = '' }
    $isArchiveHint = $script:ArchiveHints.Contains($u)
    $isMetadataHint = $script:MetadataHints.Contains($u)
    if ($isArchiveHint -and -not ($ext -match '(?i)\.(zip|tar\.gz|tgz)$')) {
      foreach ($suf in @('.tar.gz','.tgz','.zip')) {
        $base = $u
        if ($u -notmatch '\.(zip|tar\.gz|tgz)($|\?)') { $base = $u + $suf }
        $candidates.Add($base)
        if ($base -notmatch '\?') { $candidates.Add($base + '?download=1') }
      }
    }
    # If labeled Metadata but missing .csv, try adding it (+ optional ?download=1)
    if ($isMetadataHint -and -not ($ext -match '(?i)\.csv$')) {
      $base = $u
      if ($u -notmatch '\.csv($|\?)') { $base = $u + '.csv' }
      $candidates.Add($base)
      if ($base -notmatch '\?') { $candidates.Add($base + '?download=1') }
    }
    # NSynth host variants
    if ($u -match 'https?://download\.magenta\.tensorflow\.org/datasets/nsynth/(?<fname>nsynth-(train|valid|test)\.jsonwav\.(tgz|tar\.gz))') {
      $fname = $Matches['fname']
      $candidates.Add("https://storage.googleapis.com/magentadata/datasets/nsynth/$fname")
    }
    if ($u -match 'https?://storage\.googleapis\.com/magentadata/datasets/nsynth/(?<fname>nsynth-(train|valid|test)\.jsonwav\.(tgz|tar\.gz))') {
      $fname = $Matches['fname']
      $candidates.Add("https://download.magenta.tensorflow.org/datasets/nsynth/$fname")
    }
    # Deduplicate while preserving order
    return [string[]]([System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::Distinct($candidates)))
  }

  function Invoke-Download([string]$u, [string]$dest) {
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    try {
      $iwrParams = @{ Uri = $u; OutFile = $dest; UseBasicParsing = $true; UserAgent = $ua; MaximumRedirection = 10 }
      # PowerShell 7+: -SkipCertificateCheck exists; older versions will ignore this splat entry
      if ($AllowInsecure) { $iwrParams['SkipCertificateCheck'] = $true }
      Invoke-WebRequest @iwrParams
      return $true
    } catch {
      Write-Warning "Invoke-WebRequest failed: $u ($($_.Exception.Message)). Trying curl.exe..."
      if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
          $curlArgs = @('-L','--fail','-o',"$dest", "$u")
          if ($AllowInsecure) { $curlArgs = @('--insecure') + $curlArgs }
          & curl.exe @curlArgs
          return $true
        } catch {
          Write-Warning "curl failed: $u ($($_.Exception.Message))"
        }
      } else {
        Write-Warning "curl.exe not found; skipping $u"
      }
    }
    return $false
  }

  function Download-And-Collect([string[]]$urls, [string]$subset) {
  $outputs = @()
  $okCount = 0
  $failCount = 0
    $subsetDir = Join-Path $dlRoot.FullName $subset
    New-Item -ItemType Directory -Force -Path $subsetDir | Out-Null
    $i = 0
    foreach ($u in $urls) {
      $i++
      $fname = Get-SafeFileName $u $i
      $dest = Join-Path $subsetDir $fname
      Write-Host "Downloading [$subset] $u"
      $variants = Get-UrlVariants $u
      $ok = $false
      foreach ($cand in $variants) {
        if ($cand -ne $u) { Write-Warning "Trying alternate: $cand" }
        $dest = Join-Path $subsetDir (Get-SafeFileName $cand $i)
        # Reuse existing downloaded file if present and non-empty
        if (Test-Path $dest -PathType Leaf) {
          try { $sz = (Get-Item $dest).Length } catch { $sz = 0 }
          if ($sz -gt 0) { Write-Host "Reusing existing: $dest"; $ok = $true; break }
        }
        if (Invoke-Download $cand $dest) { $ok = $true; break }
      }
      if (-not $ok) { $failCount++; continue }

      $l = $dest.ToLower()
      if ($audioExt | Where-Object { $l.EndsWith($_) }) {
        $outputs += $dest; $okCount++
      } elseif ($l.EndsWith('.zip')) {
        # Use deterministic extraction dir per source file to support reuse across runs
        $zipHash = [Math]::Abs(($dest).GetHashCode())
        $zipOut = Join-Path $subsetDir ("unzip_" + $zipHash)
        New-Item -ItemType Directory -Force -Path $zipOut | Out-Null
        # If already extracted and audio present, reuse; else extract
        $found = @()
        if (Test-Path $zipOut) {
          $found = (Get-ChildItem $zipOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        }
        if (-not $found -or $found.Count -eq 0) {
          Expand-Archive -Path $dest -DestinationPath $zipOut -Force
          $found = (Get-ChildItem $zipOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        }
        if ($found) { $outputs += $found; $okCount++ } else { $failCount++ }
      } elseif ($l.EndsWith('.tar.gz') -or $l.EndsWith('.tgz')) {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
          # Deterministic extraction dir per source file
          $tarHash = [Math]::Abs(($dest).GetHashCode())
          $tarOut = Join-Path $subsetDir ("untar_" + $tarHash)
          New-Item -ItemType Directory -Force -Path $tarOut | Out-Null
          # If already extracted and audio present, reuse; else extract
          $found = @()
          if (Test-Path $tarOut) {
            $found = (Get-ChildItem $tarOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
          }
          if (-not $found -or $found.Count -eq 0) {
            tar -xzf $dest -C $tarOut
            $found = (Get-ChildItem $tarOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
          }
          if ($found) { $outputs += $found; $okCount++ } else { $failCount++ }
        } else {
          Write-Warning "tar not available; skipping archive $dest"; $failCount++
        }
      } elseif ($l.EndsWith('.csv')) {
        # Metadata CSV (e.g., Medley-solos-DB). Keep it for later filtering but do not count as failure.
        Write-Host "Metadata CSV detected (not audio): $dest"
      } else {
        Write-Warning "Unsupported file type: $dest"; $failCount++
      }
    }
    Write-Host "[$subset] successful items: $okCount, failed/empty: $failCount"
    return $outputs
  }

  $gUrls = if ($GuitarUrls) { Read-Urls $GuitarUrls } else { @() }
  $nUrls = if ($NoiseUrls)  { Read-Urls $NoiseUrls }  else { @() }

  # Auto-detect Medley-solos-DB (archive + metadata CSV) in the guitar URL list and set sensible defaults
  if ($gUrls -and $gUrls.Count -gt 0) {
    # gUrls already have labels stripped by Read-Urls, so match by URL
    $hasMedleyArchive = ($gUrls | Where-Object { $_ -match '(?i)Medley-solos-DB\.(tar\.gz|tgz)(\?|$)' })
    $hasMedleyCsv     = ($gUrls | Where-Object { $_ -match '(?i)Medley-solos-DB_metadata\.csv(\?|$)' })
    if ($hasMedleyArchive -and $hasMedleyCsv) {
      if (-not $PSBoundParameters.ContainsKey('PreferMedleyCsv')) { $PreferMedleyCsv = $true }
      if (-not $PSBoundParameters.ContainsKey('InstrumentAllowList')) { $InstrumentAllowList = @('guitar','electric_guitar','acoustic_guitar') }
      if (-not $PSBoundParameters.ContainsKey('UseParallel')) { $UseParallel = $true }
      if ($UseParallel -and -not $PSBoundParameters.ContainsKey('ParallelJobs')) { $ParallelJobs = [Environment]::ProcessorCount }
      if (-not $PSBoundParameters.ContainsKey('FfmpegThreadsPerJob')) { $FfmpegThreadsPerJob = 1 }
      Write-Host "Medley archive + metadata detected; enabling instrument filter and parallel conversion (Jobs=$ParallelJobs, Threads/job=$FfmpegThreadsPerJob)."
    }
  }

  if (-not $gUrls -and -not $nUrls) {
    Write-Host "No URLs provided; nothing to fetch."
    return
  }

  $gFiles = if ($gUrls) { Download-And-Collect $gUrls 'guitar' } else { @() }
  $nFiles = if ($nUrls) { Download-And-Collect $nUrls 'noise' } else { @() }

  # If Medley-solos-DB metadata CSV is present, filter guitar files by allowed instruments
  if ($PreferMedleyCsv -and $gFiles -and $gFiles.Count -gt 0) {
    try {
      $csvs = Get-ChildItem $dlRoot.FullName -Recurse -Filter 'Medley-solos-DB_metadata.csv' -ErrorAction SilentlyContinue
      if ($csvs) {
        Write-Host "Medley metadata detected; filtering instruments: $($InstrumentAllowList -join ', ')"
        function Get-MedleyAllowedNames([string[]]$csvPaths, [string[]]$allow) {
          $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
          foreach ($csv in $csvPaths) {
            $rows = Import-Csv $csv
            foreach ($r in $rows) {
              $cols = @()
              if ($r.PSObject.Properties.Name -contains 'instrument') { $cols += $r.instrument }
              if ($r.PSObject.Properties.Name -contains 'instrument_family') { $cols += $r.instrument_family }
              if ($r.PSObject.Properties.Name -contains 'instrument_category') { $cols += $r.instrument_category }
              $match = $false
              foreach ($a in $allow) { if ($cols -match $a) { $match = $true; break } }
              if (-not $match) { continue }
              $cand = $null
              foreach ($k in @('path','audio_filename','filename','file_name','clip_name')) {
                if ($r.PSObject.Properties.Name -contains $k -and $r.$k) { $cand = $r.$k; break }
              }
              if ($cand) {
                $set.Add([IO.Path]::GetFileName($cand)) | Out-Null
              }
            }
          }
          return $set
        }
        $allowed = Get-MedleyAllowedNames ($csvs | Select-Object -ExpandProperty FullName) $InstrumentAllowList
        # Limit filtering to files inside the same extraction roots as the metadata CSVs
        $csvRoots = @(); foreach ($c in $csvs) { $csvRoots += (Split-Path -Parent $c.FullName) }
        function Is-UnderAnyRoot([string]$path, [string[]]$roots) {
          $lp = $path.ToLower(); foreach ($r in $roots) { if ($lp.StartsWith($r.ToLower())) { return $true } } return $false
        }
        if ($allowed -and $allowed.Count -gt 0) {
          $before = $gFiles.Count
          $medleyFiles = @(); $otherFiles = @()
          foreach ($gf in $gFiles) { if (Is-UnderAnyRoot $gf $csvRoots) { $medleyFiles += $gf } else { $otherFiles += $gf } }
          $filteredMedley = $medleyFiles | Where-Object { $allowed.Contains([IO.Path]::GetFileName($_)) }
          $gFiles = @() + $otherFiles + $filteredMedley
          $keptMedley = ($filteredMedley | Measure-Object).Count
          $medleyCount = ($medleyFiles | Measure-Object).Count
          Write-Host "Medley CSV filter kept $keptMedley/$medleyCount Medley files; total guitar files now $($gFiles.Count) (was $before)."
        } else {
          Write-Host "Medley CSV found but no matching filenames; skipping Medley filter."
        }
      }
    } catch {
      Write-Warning "Medley CSV filtering failed: $($_.Exception.Message). Proceeding without filter."
    }
  }

  function Convert-To-48kMono([string[]]$files, [string]$outDir) {
    $ffCommon = @('-hide_banner','-loglevel','error','-nostdin','-threads',"$FfmpegThreadsPerJob")
    $ts = Get-Date -Format yyyyMMddHHmmss
    if ($UseParallel -and $PSVersionTable.PSVersion.Major -ge 7) {
      $throttle = if ($ParallelJobs -gt 0) { $ParallelJobs } else { 4 }
      $files | ForEach-Object -Parallel {
        $f = $_
        if (-not (Test-Path $f -PathType Leaf)) { Write-Warning "Skip (missing): $f"; return }
        try { $len = (Get-Item $f).Length } catch { $len = 0 }
        if (-not $len -or $len -le 0) { Write-Warning "Skip (empty): $f"; return }
        # generate a unique index per file using its hash and a random salt
        $salt = Get-Random -Minimum 1000 -Maximum 9999
        $name = [IO.Path]::GetFileNameWithoutExtension($f)
        $idx  = [Math]::Abs(("$name$salt").GetHashCode())
        $out = Join-Path $using:outDir ("$($using:ts)_$idx.wav")
        $args = @('-y') + $using:ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        try {
          & ffmpeg @args | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "ffmpeg exit code $LASTEXITCODE" }
        } catch {
          Write-Warning "ffmpeg failed on: $f ($_). Skipping."
          if (Test-Path $out) { try { Remove-Item $out -Force -ErrorAction SilentlyContinue } catch {} }
        }
      } -ThrottleLimit $throttle
    } else {
      $count = 0
      foreach ($f in $files) {
        $count++
        if (-not (Test-Path $f -PathType Leaf)) { Write-Warning "Skip (missing): $f"; continue }
        try { $len = (Get-Item $f).Length } catch { $len = 0 }
        if (-not $len -or $len -le 0) { Write-Warning "Skip (empty): $f"; continue }
        $out = Join-Path $outDir ("${ts}_$count.wav")
        $args = @('-y') + $ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        try {
          & ffmpeg @args | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "ffmpeg exit code $LASTEXITCODE" }
        } catch {
          Write-Warning "ffmpeg failed on: $f ($_). Skipping."
          if (Test-Path $out) { try { Remove-Item $out -Force -ErrorAction SilentlyContinue } catch {} }
        }
      }
    }
  }

  if ($gFiles -and $gFiles.Count -gt 0) { Write-Host "Converting guitar files -> $GuitarOut (Parallel=$UseParallel, Jobs=$ParallelJobs, Threads/job=$FfmpegThreadsPerJob)"; Convert-To-48kMono $gFiles $GuitarOut } else { Write-Host "No guitar files downloaded." }
  if ($nFiles -and $nFiles.Count -gt 0) { Write-Host "Converting noise files -> $NoiseOut (Parallel=$UseParallel, Jobs=$ParallelJobs, Threads/job=$FfmpegThreadsPerJob)"; Convert-To-48kMono $nFiles $NoiseOut } else { Write-Host "No noise files downloaded." }

  Write-Host "Fetch complete. Output dirs:"
  Write-Host " - Guitar: $GuitarOut"
  Write-Host " - Noise:  $NoiseOut"
}
finally {
  if (-not $TempDownloadDir -or $TempDownloadDir -eq '') {
    if ($dlRoot -and (Test-Path $dlRoot.FullName)) { Remove-Item $dlRoot.FullName -Recurse -Force }
  }
}
