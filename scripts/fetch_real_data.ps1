<#
Downloads real audio from URL lists, extracts archives, and converts to 48 kHz mono WAV.

Examples
  .\fetch_real_data.ps1 -GuitarUrls .\scripts\urls_guitar.txt -NoiseUrls .\scripts\urls_noise.txt \
    -GuitarOut .\data\guitar_clean -NoiseOut .\data\interfere

Notes
- Provide plain text files where each non-empty, non-comment line is a URL to an audio file or zip archive.
- Supported inputs: wav, flac, mp3, ogg, m4a, aiff/aif, zip (contains audio). Tries tar for .tar.gz/.tgz if available.
- Requires: ffmpeg; optional: tar (for .tar.gz).
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
  [int]$FfmpegThreadsPerJob = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

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
  return $lines
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
      $fname = [IO.Path]::GetFileName(($u -replace '\\','/'))
      if (-not $fname) { $fname = "file_$i" }
      $dest = Join-Path $subsetDir $fname
      Write-Host "Downloading [$subset] $u"
      $variants = Get-UrlVariants $u
      $ok = $false
      foreach ($cand in $variants) {
        if ($cand -ne $u) { Write-Warning "Trying alternate: $cand" }
        $dest = Join-Path $subsetDir ([IO.Path]::GetFileName(($cand -replace '\\','/')))
        if (Invoke-Download $cand $dest) { $ok = $true; break }
      }
      if (-not $ok) { $failCount++; continue }

      $l = $dest.ToLower()
      if ($audioExt | Where-Object { $l.EndsWith($_) }) {
        $outputs += $dest; $okCount++
      } elseif ($l.EndsWith('.zip')) {
        $zipOut = Join-Path $subsetDir ("unzip_" + $i)
        New-Item -ItemType Directory -Force -Path $zipOut | Out-Null
        Expand-Archive -Path $dest -DestinationPath $zipOut -Force
        $found = (Get-ChildItem $zipOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        if ($found) { $outputs += $found; $okCount++ } else { $failCount++ }
      } elseif ($l.EndsWith('.tar.gz') -or $l.EndsWith('.tgz')) {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
          $tarOut = Join-Path $subsetDir ("untar_" + $i)
          New-Item -ItemType Directory -Force -Path $tarOut | Out-Null
          tar -xzf $dest -C $tarOut
          $found = (Get-ChildItem $tarOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
          if ($found) { $outputs += $found; $okCount++ } else { $failCount++ }
        } else {
          Write-Warning "tar not available; skipping archive $dest"; $failCount++
        }
      } else {
        Write-Warning "Unsupported file type: $dest"; $failCount++
      }
    }
    Write-Host "[$subset] successful items: $okCount, failed/empty: $failCount"
    return $outputs
  }

  $gUrls = if ($GuitarUrls) { Read-Urls $GuitarUrls } else { @() }
  $nUrls = if ($NoiseUrls)  { Read-Urls $NoiseUrls }  else { @() }

  if (-not $gUrls -and -not $nUrls) {
    Write-Host "No URLs provided; nothing to fetch."
    return
  }

  $gFiles = if ($gUrls) { Download-And-Collect $gUrls 'guitar' } else { @() }
  $nFiles = if ($nUrls) { Download-And-Collect $nUrls 'noise' } else { @() }

  function Convert-To-48kMono([string[]]$files, [string]$outDir) {
    $ffCommon = @('-hide_banner','-loglevel','error','-threads',"$FfmpegThreadsPerJob")
    $ts = Get-Date -Format yyyyMMddHHmmss
    if ($UseParallel -and $PSVersionTable.PSVersion.Major -ge 7) {
      $throttle = if ($ParallelJobs -gt 0) { $ParallelJobs } else { 4 }
      $files | ForEach-Object -Parallel {
        $f = $_
        # generate a unique index per file using its hash and a random salt
        $salt = Get-Random -Minimum 1000 -Maximum 9999
        $name = [IO.Path]::GetFileNameWithoutExtension($f)
        $idx  = [Math]::Abs(("$name$salt").GetHashCode())
        $out = Join-Path $using:outDir ("$($using:ts)_$idx.wav")
        $args = @('-y') + $using:ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        & ffmpeg @args
      } -ThrottleLimit $throttle
    } else {
      $count = 0
      foreach ($f in $files) {
        $count++
        $out = Join-Path $outDir ("${ts}_$count.wav")
        $args = @('-y') + $ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        & ffmpeg @args
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
