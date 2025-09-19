<#
Downloads real audio from URL lists, extracts archives, applies optional duration filtering, and converts to 48 kHz mono WAV.

Examples
  .\fetch_real_data.ps1 -GuitarUrls .\scripts\urls_guitar.txt -NoiseUrls .\scripts\urls_noise.txt \
    -GuitarOut .\data\guitar_clean -NoiseOut .\data\interfere

Notes
- Provide plain text files where each non-empty, non-comment line is a URL to an audio file or zip archive.
- Supported inputs: wav, flac, mp3, ogg, m4a, aiff/aif, zip (contains audio). Tries tar for .tar.gz/.tgz if available.
- Requires: ffmpeg; optional: tar (for .tar.gz).
- Caching: Archives are cached under %LOCALAPPDATA%\rnnoise_downloads and extracted into deterministic
  folders (untar_<archiveBase>, unzip_<archiveBase>) so repeated runs reuse the same directories.
  If you previously ran older versions that created hash-named folders, you can safely clean them with:
    Get-ChildItem "$env:LOCALAPPDATA\rnnoise_downloads" -Recurse -Directory -Filter 'untar_*' | Where-Object { $_.Name -match '^untar_\d+$' } | Remove-Item -Recurse -Force
    Get-ChildItem "$env:LOCALAPPDATA\rnnoise_downloads" -Recurse -Directory -Filter 'unzip_*' | Where-Object { $_.Name -match '^unzip_\d+$' } | Remove-Item -Recurse -Force
- Auto Medley mode: if BOTH of these appear in your guitar URL list during one run:
    • Medley-solos-DB.tar.gz (or .tgz)
    • Medley-solos-DB_metadata.csv
  then instrument filtering is automatically enabled (default allow: guitar, electric_guitar, acoustic_guitar),
  parallel conversion is auto-enabled, and ParallelJobs defaults to CPU count unless overridden.
 - Optional labels: You can prefix lines with 'Archive:' or 'Metadata:' to disambiguate. Labels are recognized for
   auto-detection but downloads use the URL after the label.

Key Parameters
  -GuitarUrls / -NoiseUrls            URL list files (one URL per line; supports optional labels 'Archive:' or 'Metadata:').
  -GuitarOut / -NoiseOut              Output directories for converted 48k mono WAVs (default: repo data/ subfolders).
  -Downloader Auto|Builtin|Aria2c     Auto uses aria2c if present, else builtin (Invoke-WebRequest -> curl fallback).
  -ShowDownloadProgress               Show aria2c live progress (otherwise quiet summary mode).
  -MinSeconds / -MaxSeconds           Duration filter (probed with ffprobe). 0 disables each bound.
  -WriteDatasetSummary                Emit dataset_summary.json & dataset_summary.csv per output directory after conversion.
  -IgnoreAppleResourceForks           Skip macOS resource fork files (._*). Default: true.
  -PerFileSkipWarnings                Re-enable per-file skip warnings (normally aggregated into logs).
  -AllowInsecure                      Disable SSL validation (only for trusted internal sources).

MUSAN Control
  -MusanMode All|NoiseOnly            All includes all MUSAN categories (music, speech, noise). NoiseOnly limits to noise/.

Downloader (aria2c) Tuning
  -AriaMaxConnections <int>           Max connections per server (default 16)
  -AriaSplit <int>                    Initial split count (default 16)
  -AriaMinSplitSizeMB <int>           Minimum size per split before further splitting (default 5)
  Install aria2c:  winget install aria2   OR   choco install aria2
  If aria2c fails or is unavailable the script falls back transparently to builtin.
#>

param(
  [string]$GuitarUrls,
  [string]$NoiseUrls,
  [string]$GuitarOut = (Join-Path (Resolve-Path .).Path 'data/guitar_clean'),
  [string]$NoiseOut  = (Join-Path (Resolve-Path .).Path 'data/interfere'),
  [ValidateSet('All','NoiseOnly')][string]$MusanMode = 'All',
  # If set, include NON-guitar instrument families from NSynth archives as interference (noise) sources.
  [switch]$IncludeNSynthNonGuitar,
  [ValidateSet('Auto','Builtin','Aria2c')][string]$Downloader = 'Auto',
  [switch]$ShowDownloadProgress,
  [int]$MinSeconds = 0,
  [int]$MaxSeconds = 0,
  [switch]$WriteDatasetSummary,
  [switch]$IgnoreAppleResourceForks = $true,
  [switch]$PerFileSkipWarnings,
  [switch]$AllowInsecure,
  [int]$AriaMaxConnections = 16,
  [int]$AriaSplit = 16,
  [int]$AriaMinSplitSizeMB = 5,
  [switch]$LenientArchiveValidation,
  [switch]$TrustGzipIfLarge,
  [int]$LargeArchiveTrustMB = 900,  # trust very large tarballs if gzip header ok
  [switch]$ValidateBeforeConvert,
  [switch]$UseParallel,
  [int]$ParallelJobs = 0,
  [int]$FfmpegThreadsPerJob = 1,
  [switch]$PreferMedleyCsv,
  [string[]]$InstrumentAllowList,
  [string]$TempDownloadDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

try {
  # ---------------------------------------------------------------------------
  # Initial setup
  # ---------------------------------------------------------------------------
  # Default download/cache directory moved to per-user AppData to avoid polluting repo and survive clean/re-clones
  if (-not $TempDownloadDir) {
    $userAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $TempDownloadDir = Join-Path $userAppData 'rnnoise_downloads'
  }
  if (-not (Test-Path $TempDownloadDir)) { New-Item -ItemType Directory -Path $TempDownloadDir -Force | Out-Null }
  $dlRoot = Get-Item $TempDownloadDir

  if (-not (Test-Path $GuitarOut)) { New-Item -ItemType Directory -Force -Path $GuitarOut | Out-Null }
  if (-not (Test-Path $NoiseOut)) { New-Item -ItemType Directory -Force -Path $NoiseOut | Out-Null }

  # Audio extensions recognized as single audio files (lowercase compare)
  $audioExt = @('.wav','.flac','.mp3','.ogg','.m4a','.aiff','.aif','.aac')

  # Hint sets for variant generation
  $script:ArchiveHints  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  $script:MetadataHints = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

  function Get-SafeFileName([string]$url,[int]$index) {
    $raw = $url
    try {
      $uObj = [Uri]$url
      $raw = $uObj.Segments[-1]
      if (-not $raw) { $raw = $uObj.AbsolutePath.Trim('/') }
    } catch {}
    if (-not $raw -or $raw.Trim() -eq '') { $raw = "f$index" }
    # Strip query
    if ($raw -match '^(?<base>[^?]+)') { $raw = $Matches['base'] }
    # Replace invalid chars
    $raw = ($raw -replace '[^A-Za-z0-9_.-]','_')
    if ($raw.Length -gt 160) { $raw = $raw.Substring(0,160) }
    return $raw
  }

  function Read-Urls([string]$file) {
    if (-not (Test-Path $file -PathType Leaf)) { throw "URL list not found: $file" }
    $lines = Get-Content $file | Where-Object { $_ -and $_.Trim() -ne '' -and -not ($_.Trim().StartsWith('#')) }
    $urls = @()
    $i = 0
    foreach ($l in $lines) {
      $i++
      $label = $null; $u = $l.Trim()
      if ($u -match '^(?i)(Archive|Metadata):\s*(?<rest>.+)$') {
        $label = $Matches[1]; $u = $Matches['rest'].Trim()
      }
      if ($label -eq 'Archive') { $script:ArchiveHints.Add($u)   | Out-Null }
      if ($label -eq 'Metadata') { $script:MetadataHints.Add($u) | Out-Null }
      $urls += $u
    }
    return ,$urls
  }

  # Downloader mode resolution
  if ($Downloader -eq 'Auto') {
    if (Get-Command aria2c -ErrorAction SilentlyContinue) { $script:DownloaderMode = 'Aria2c' } else { $script:DownloaderMode = 'Builtin' }
  } elseif ($Downloader -eq 'Aria2c') {
    $script:DownloaderMode = 'Aria2c'
  } else { $script:DownloaderMode = 'Builtin' }

  # Debug log init AFTER $dlRoot is known
  $debugLog = Join-Path $dlRoot.FullName '_download_debug.log'
  "# Download debug (`$(Get-Date -Format o)`)" | Out-File -FilePath $debugLog -Encoding UTF8 -Force
  function Log([string]$tag,[string]$msg='') { try { Add-Content -Path $debugLog -Value ("{0}`t{1}`t{2}" -f (Get-Date -Format o),$tag,$msg) } catch {} }

  Write-Host "Downloader mode: $script:DownloaderMode"

  # ---------------------------------------------------------------------------
  # CORE IMPLEMENTATION (existing functions follow)
  # ---------------------------------------------------------------------------

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
    # Zenodo record vs records path toggling & ?download=1 normalization
    if ($u -match '^https?://zenodo\.org/(?<rec>record|records)/(?<id>\d+)/(?:files/)?(?<rest>[^?]+)(?<query>\?download=1)?$') {
      $id = $Matches['id']; $rest = $Matches['rest']; $query = $Matches['query']
      $restVariants = New-Object System.Collections.Generic.List[string]
      $restVariants.Add($rest)
      # If filename has no extension (e.g. DEMAND_Real_World_Noise_Dataset) assume .zip as a common archive
      if ($rest -notmatch '\.[A-Za-z0-9]{2,4}$') { $restVariants.Add($rest + '.zip') }
      $bases = @("https://zenodo.org/record/$id/files/$rest","https://zenodo.org/records/$id/files/$rest")
      foreach ($rv in $restVariants) {
        $bases = @("https://zenodo.org/record/$id/files/$rv","https://zenodo.org/records/$id/files/$rv")
        foreach ($b in $bases) {
          if (-not ($candidates -contains $b)) { $candidates.Add($b) }
          $dl = $b + '?download=1'
          if (-not ($candidates -contains $dl)) { $candidates.Add($dl) }
        }
      }
      # Also allow without /files/ segment (some older Zenodo URLs omit it)
      foreach ($rv in $restVariants) {
        $altBases = @("https://zenodo.org/record/$id/$rv","https://zenodo.org/records/$id/$rv")
        foreach ($b in $altBases) {
          if (-not ($candidates -contains $b)) { $candidates.Add($b) }
          $dl = $b + '?download=1'
          if (-not ($candidates -contains $dl)) { $candidates.Add($dl) }
        }
      }
    }

    # Generic fallback for ANY URL lacking a recognized extension: attempt common archive and metadata variants.
    try {
      $uri2 = [Uri]$u
      $path2 = $uri2.AbsolutePath.TrimEnd('/')
      $leaf = if ($path2.Contains('/')) { $path2.Substring($path2.LastIndexOf('/')+1) } else { $path2 }
      if (-not [string]::IsNullOrWhiteSpace($leaf)) {
        $leafCore = $leaf
        if ($leafCore -match '^(?<core>[^?]+)') { $leafCore = $Matches['core'] }
        $lowerLeaf = $leafCore.ToLower()
        $knownEndings = @('.wav','.flac','.mp3','.ogg','.m4a','.aiff','.aif','.aac','.zip','.tar.gz','.tgz','.csv')
        $hasKnown = $false
        foreach ($e in $knownEndings) { if ($lowerLeaf.EndsWith($e)) { $hasKnown = $true; break } }
        # crude extension detection (dot + 2-5 alnum chars) unless .tar.gz
        $simpleExt = ($lowerLeaf -match '\.[A-Za-z0-9]{2,5}$') -or $lowerLeaf.EndsWith('.tar.gz')
        if (-not $hasKnown -and -not $simpleExt) {
          foreach ($suf in @('.tar.gz','.tgz','.zip')) {
            $cand = $u + $suf
            if (-not ($candidates -contains $cand)) { $candidates.Add($cand) }
            if ($u -notmatch '\?') {
              $candDl = $cand + '?download=1'
              if (-not ($candidates -contains $candDl)) { $candidates.Add($candDl) }
            }
          }
          # Medley-specific heuristic: add metadata CSV
          if ($lowerLeaf -match 'medley-solos-db$') {
            $meta = $u + '_metadata.csv'
            if (-not ($candidates -contains $meta)) { $candidates.Add($meta) }
            if ($u -notmatch '\?') {
              $metaDl = $meta + '?download=1'
              if (-not ($candidates -contains $metaDl)) { $candidates.Add($metaDl) }
            }
          }
        }
        # If looks like metadata base without .csv
        if ($lowerLeaf -match 'medley-solos-db_metadata$' -and (-not $lowerLeaf.EndsWith('.csv'))) {
          $csvCand = $u + '.csv'
          if (-not ($candidates -contains $csvCand)) { $candidates.Add($csvCand) }
          if ($u -notmatch '\?') {
            $csvCandDl = $csvCand + '?download=1'
            if (-not ($candidates -contains $csvCandDl)) { $candidates.Add($csvCandDl) }
          }
        }
      }
    } catch {}
    # Deduplicate while preserving order
    return [string[]]([System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::Distinct($candidates)))
  }

  function Invoke-DownloadBuiltin([string]$u, [string]$dest) {
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

  function Invoke-DownloadAria2c([string]$u, [string]$dest) {
    if (-not (Get-Command aria2c -ErrorAction SilentlyContinue)) { return $false }
    # aria2c writes to current directory by default; use --dir and --out
    $dir = Split-Path -Parent $dest
    $file = Split-Path -Leaf $dest
    $conn = if ($AriaMaxConnections -gt 0) { $AriaMaxConnections } else { 16 }
    $split = if ($AriaSplit -gt 0) { $AriaSplit } else { 16 }
    $minSplit = if ($AriaMinSplitSizeMB -gt 0) { "$AriaMinSplitSizeMB" + 'M' } else { '5M' }
    $summaryInterval = if ($ShowDownloadProgress) { '1' } else { '0' }
    $consoleLevel = if ($ShowDownloadProgress) { 'notice' } else { 'warn' }
    $args = @("--console-log-level=$consoleLevel","--summary-interval=$summaryInterval","--allow-overwrite=true", '--auto-file-renaming=false',` 
      "--max-connection-per-server=$conn","--split=$split","--min-split-size=$minSplit",` 
      '--file-allocation=none','--max-tries=5','--retry-wait=3','--dir', $dir,'--out',$file,$u)
    if ($AllowInsecure) { $args = @('--check-certificate=false','--allow-insecure=true') + $args }
    try {
      if ($ShowDownloadProgress) { & aria2c @args } else { & aria2c @args | Out-Null }
      if ($LASTEXITCODE -eq 0 -and (Test-Path $dest)) { return $true }
      Write-Warning "aria2c non-zero exit ($LASTEXITCODE) for $u"
    } catch {
      Write-Warning "aria2c failed: $u ($($_.Exception.Message))"
    }
    return $false
  }

  function Invoke-Download([string]$u, [string]$dest) {
    if ($script:DownloaderMode -eq 'Aria2c') {
      $ok = Invoke-DownloadAria2c $u $dest
      if ($ok) { return $true }
      Write-Warning "Falling back to builtin for $u"
    }
    return (Invoke-DownloadBuiltin $u $dest)
  }

  function Download-And-Collect([string[]]$urls, [string]$subset) {
    $outputs        = @()
    $okCount        = 0
    $failCount      = 0
    $reusedCount    = 0
    $downloadedCount= 0
    $subsetDir = Join-Path $dlRoot.FullName $subset
    New-Item -ItemType Directory -Force -Path $subsetDir | Out-Null
    $badArchiveLog = Join-Path $subsetDir '_invalid_archives.txt'
    if (Test-Path $badArchiveLog) { Remove-Item $badArchiveLog -Force -ErrorAction SilentlyContinue }

    function Get-BaseNameFromFile([string]$fileName) {
      $n = $fileName
      $lower = $n.ToLower()
      if ($lower.EndsWith('.tar.gz')) { return $n.Substring(0, $n.Length - 7) }
      if ($lower.EndsWith('.tgz'))    { return $n.Substring(0, $n.Length - 4) }
      if ($lower.EndsWith('.zip'))    { return $n.Substring(0, $n.Length - 4) }
      return [IO.Path]::GetFileNameWithoutExtension($n)
    }

    function Collect-AudioFromExtract([string]$rootDir, [string]$sourceTag) {
      if (-not (Test-Path $rootDir -PathType Container)) { return @() }
      $found = (Get-ChildItem $rootDir -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
      if (-not $found -or $found.Count -eq 0) { return @() }
      # Apply dataset-specific filters
      $result = $found
      if ($MusanMode -eq 'NoiseOnly' -and ($sourceTag -match '(?i)musan')) {
        $result = $result | ForEach-Object {
          try { $rel = $_.Substring($rootDir.Length).Replace('\\','/').ToLower(); if ($rel -match '/noise/') { $_ } } catch {}
        }
      }
      if ($sourceTag -match '(?i)nsynth') {
        $result = $result | ForEach-Object {
          try { $rel = $_.Substring($rootDir.Length).Replace('\\','/').ToLower(); if ($rel -match '/guitar/') { $_ } } catch {}
        }
      }
      if ($IgnoreAppleResourceForks) { $result = $result | Where-Object { -not ([IO.Path]::GetFileName($_).StartsWith('._')) } }
      return $result
    }

    function Try-ReuseExtract([string]$url, [int]$index) {
      # Based on deterministic folder naming: unzip_<base> / untar_<base>
      $fname   = Get-SafeFileName $url $index
      $base    = Get-BaseNameFromFile $fname
      $untar   = Join-Path $subsetDir ("untar_" + ($base -replace '[^A-Za-z0-9_.-]','_'))
      $unzip   = Join-Path $subsetDir ("unzip_" + ($base -replace '[^A-Za-z0-9_.-]','_'))
      $agg     = @()
      foreach ($candRoot in @($untar, $unzip)) {
        $files = Collect-AudioFromExtract $candRoot $url
        if ($files -and $files.Count -gt 0) { $agg += $files }
      }
      return ,$agg
    }

    function Test-GzipHeader([string]$file) {
      $i = 0
        if (-not (Test-Path $file -PathType Leaf)) { return $false }
        $fs = [IO.File]::OpenRead($file)
        try {
          if ($fs.Length -lt 32) { return $false }
          $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte();
          return ($b1 -eq 0x1f -and $b2 -eq 0x8b)
        $variants = Get-UrlVariants $u

        # Fast path: if a deterministic extracted folder already exists with audio, reuse it and skip downloading
        $preReuse = Try-ReuseExtract $u $i
        if ($preReuse -and $preReuse.Count -gt 0) {
          Write-Host "Reusing extracted content for [$subset]: $u"
          $outputs += $preReuse
          $okCount++
          $reusedCount++
          Log 'REUSE_EXTRACT_OK' "$subset`t$u`t$count=$($preReuse.Count)"
          continue
        }
      } catch { return $false }
    }

    function Test-TarList([string]$file, [switch]$lenient) {
      if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { return $true }
      try {
        $outLines = & tar -tzf $file 2>&1
        $exitCode = $LASTEXITCODE
        $hasEntry = $false
        foreach ($l in $outLines) {
          if ($l -match '^(tar:|bsdtar:)') { continue }
          if ($l -match '/') { $hasEntry = $true; break }
          if ($l -match '\\.') { $hasEntry = $true; break }
          if ($l -match '[A-Za-z0-9]') { $hasEntry = $true; break }
        }
        if ($exitCode -eq 0) { return $true }
        if ($lenient -and $hasEntry) { return $true }
        return $false
      } catch { return $false }
    }

    $i = 0
    foreach ($u in $urls) {
      $i++
      if (-not $u -or $u.Trim() -eq '') { continue }
      $fname = Get-SafeFileName $u $i
      $dest  = Join-Path $subsetDir $fname
      Write-Host "Downloading [$subset] $u"
      $variants = Get-UrlVariants $u
      $ok = $false
      foreach ($cand in $variants) {
        if ($cand -ne $u) { Write-Warning "Trying alternate: $cand" }
        Log 'VARIANT' "$subset`t$cand"
        $dest = Join-Path $subsetDir (Get-SafeFileName $cand $i)
        if (Test-Path $dest -PathType Leaf) {
          $reuseOk = $true
          try { $sz = (Get-Item $dest).Length } catch { $sz = 0 }
          if ($sz -gt 0) {
            $dl = $dest.ToLower()
            if ($dl.EndsWith('.tar.gz') -or $dl.EndsWith('.tgz')) {
              $gzipOk = Test-GzipHeader $dest
              $tarOk  = Test-TarList $dest -lenient:$LenientArchiveValidation
              if ($gzipOk -and -not $tarOk -and $TrustGzipIfLarge) {
                try { $sizeMB = [math]::Round(((Get-Item $dest).Length/1MB),2) } catch { $sizeMB = 0 }
                if ($sizeMB -ge $LargeArchiveTrustMB) {
                  Write-Host "Trusting large gzip archive without successful tar listing (cached, size=${sizeMB}MB >= $LargeArchiveTrustMB MB): $dest"
                  Log 'TRUST_LARGE_GZIP_CACHE' "$dest`t${sizeMB}MB"
                  $tarOk = $true
                }
              }
              if (-not $gzipOk -or -not $tarOk) {
                $reason = @(); if (-not $gzipOk) { $reason += 'gzip-header' }; if (-not $tarOk) { $reason += 'tar-listing' }
                Write-Warning "Cached archive failed validation ($($reason -join '+')) -> deleting and redownloading: $dest"
                try { Remove-Item $dest -Force -ErrorAction SilentlyContinue } catch {}
                Log 'CACHE_INVALIDATE' "$dest`t$($reason -join '+')"
                $reuseOk = $false
              }
            }
            if ($reuseOk) { Write-Host "Reusing existing archive: $dest"; Log 'REUSE_OK' "$dest"; $ok = $true; $reusedCount++; break }
          }
        }
        if (Invoke-Download $cand $dest) {
          $dl = $dest.ToLower(); $archiveOk = $true
          if ($dl.EndsWith('.tar.gz') -or $dl.EndsWith('.tgz')) {
            $gzipOk = Test-GzipHeader $dest
            $tarOk  = Test-TarList $dest -lenient:$LenientArchiveValidation
            if ($gzipOk -and -not $tarOk -and $TrustGzipIfLarge) {
              try { $sizeMB = [math]::Round(((Get-Item $dest).Length/1MB),2) } catch { $sizeMB = 0 }
              if ($sizeMB -ge $LargeArchiveTrustMB) {
                Write-Host "Trusting large gzip archive without successful tar listing (fresh, size=${sizeMB}MB >= $LargeArchiveTrustMB MB): $dest"
                Log 'TRUST_LARGE_GZIP_FRESH' "$dest`t${sizeMB}MB"
                $tarOk = $true
              }
            }
            if (-not $gzipOk -or -not $tarOk) {
              $reason = @(); if (-not $gzipOk) { $reason += 'gzip-header' }; if (-not $tarOk) { $reason += 'tar-listing' }
              Write-Warning "Downloaded archive failed validation ($($reason -join '+')): $dest"
              Add-Content -Path $badArchiveLog -Value "$dest`t$($reason -join '+')"
              Log 'DOWNLOAD_INVALID' "$dest`t$($reason -join '+')"
              try { Remove-Item $dest -Force -ErrorAction SilentlyContinue } catch {}
              $archiveOk = $false
            }
          }
          if ($archiveOk) { Log 'DOWNLOAD_OK' "$dest"; $ok = $true; $downloadedCount++; break }
        } else { Log 'DOWNLOAD_FAIL' "$cand" }

        # If this variant failed to download, but its deterministic extract folder exists, reuse it
        if (-not $ok) {
          $reuseAfterFail = Try-ReuseExtract $cand $i
          if ($reuseAfterFail -and $reuseAfterFail.Count -gt 0) {
            Write-Host "Reusing extracted content for [$subset] after download failure: $cand"
            $outputs += $reuseAfterFail
            $ok = $true
            $okCount++
            $reusedCount++
            Log 'REUSE_EXTRACT_OK_AFTER_FAIL' "$subset`t$cand`t$count=$($reuseAfterFail.Count)"
            break
          }
        }
      }
      if (-not $ok) { $failCount++; continue }
      $l = $dest.ToLower()
      if ($audioExt | Where-Object { $l.EndsWith($_) }) {
        if ($IgnoreAppleResourceForks -and ([IO.Path]::GetFileName($dest)).StartsWith('._')) { } else { $outputs += $dest; $okCount++ }
      } elseif ($l.EndsWith('.zip')) {
        # Reuse a deterministic unzip folder per archive name to avoid creating new folders on each run
        $zipBase = [IO.Path]::GetFileNameWithoutExtension($dest)
        $zipSafe = ($zipBase -replace '[^A-Za-z0-9_.-]','_')
        $zipOut = Join-Path $subsetDir ("unzip_" + $zipSafe)
        if (-not (Test-Path $zipOut)) { New-Item -ItemType Directory -Force -Path $zipOut | Out-Null }
        $found = @()
        if (Test-Path $zipOut) {
          $found = (Get-ChildItem $zipOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        }
        if (-not $found -or $found.Count -eq 0) {
          $expanded = $false
          try { Expand-Archive -Path $dest -DestinationPath $zipOut -Force; $expanded = $true } catch { Write-Warning "Expand-Archive failed: $dest ($($_.Exception.Message))"; Log 'ZIP_EXPAND_FAIL' "$dest`t$($_.Exception.Message)" }
          # If Expand-Archive failed or yielded nothing, try tar as a fallback (bsdtar supports zip)
          if (-not $expanded) {
            if (Get-Command tar -ErrorAction SilentlyContinue) {
              try { tar -xf "$dest" -C "$zipOut"; $expanded = $true; Write-Host "tar fallback succeeded for ZIP: $dest"; Log 'ZIP_TAR_FALLBACK_OK' "$dest" } catch { Write-Warning "tar fallback failed for ZIP: $dest ($($_.Exception.Message))"; Log 'ZIP_TAR_FALLBACK_FAIL' "$dest`t$($_.Exception.Message)" }
            }
          }
          # If tar also failed or unavailable, try 7z if present
          if (-not $expanded) {
            if (Get-Command 7z -ErrorAction SilentlyContinue) {
              try { & 7z x -y "$dest" -o"$zipOut" | Out-Null; $expanded = $true; Write-Host "7z fallback succeeded for ZIP: $dest"; Log 'ZIP_7Z_FALLBACK_OK' "$dest" } catch { Write-Warning "7z fallback failed for ZIP: $dest ($($_.Exception.Message))"; Log 'ZIP_7Z_FALLBACK_FAIL' "$dest`t$($_.Exception.Message)" }
            } elseif (Get-Command 7z.exe -ErrorAction SilentlyContinue) {
              try { & 7z.exe x -y "$dest" -o"$zipOut" | Out-Null; $expanded = $true; Write-Host "7z.exe fallback succeeded for ZIP: $dest"; Log 'ZIP_7Z_FALLBACK_OK' "$dest" } catch { Write-Warning "7z.exe fallback failed for ZIP: $dest ($($_.Exception.Message))"; Log 'ZIP_7Z_FALLBACK_FAIL' "$dest`t$($_.Exception.Message)" }
            }
          }
          if (-not $expanded) { Write-Warning "All ZIP extraction methods failed: $dest"; Log 'ZIP_ALL_EXTRACT_FAIL' "$dest" }
          $found = (Get-ChildItem $zipOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        }
        # If this is MUSAN and NoiseOnly mode, keep only files within the noise/ category
        if ($found -and ($dest -match '(?i)musan') -and $MusanMode -eq 'NoiseOnly') {
          $found = $found | ForEach-Object {
            try {
              $rel = $_.Substring($zipOut.Length)
              $rel = $rel.Replace('\\','/').ToLower()
              if ($rel -match '/noise/') { $_ } 
            } catch { }
          }
        }
        # If this is NSynth, keep only guitar family files (jsonwav archives include instrument family in path)
        if ($found -and ($dest -match '(?i)nsynth')) {
          $found = $found | ForEach-Object {
            try {
              $rel = $_.Substring($zipOut.Length)
              $rel = $rel.Replace('\\','/').ToLower()
              if ($rel -match '/guitar/') { $_ }
              elseif ($IncludeNSynthNonGuitar) { $_ }
            } catch { }
          }
        }
        if ($found) { if ($IgnoreAppleResourceForks) { $found = $found | Where-Object { -not ([IO.Path]::GetFileName($_).StartsWith('._')) } }; if ($found -and $found.Count -gt 0) { $outputs += $found; $okCount++ } else { $failCount++ } } else { $failCount++ }
      } elseif ($l.EndsWith('.tar.gz') -or $l.EndsWith('.tgz')) {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
          # Reuse a deterministic untar folder per archive name to avoid creating new folders on each run
          $tarName = [IO.Path]::GetFileName($dest)
          if ($tarName.ToLower().EndsWith('.tar.gz')) { $tarBase = $tarName.Substring(0, $tarName.Length - 7) }
          elseif ($tarName.ToLower().EndsWith('.tgz')) { $tarBase = $tarName.Substring(0, $tarName.Length - 4) }
          else { $tarBase = [IO.Path]::GetFileNameWithoutExtension($tarName) }
          $tarSafe = ($tarBase -replace '[^A-Za-z0-9_.-]','_')
          $tarOut = Join-Path $subsetDir ("untar_" + $tarSafe)
          if (-not (Test-Path $tarOut)) { New-Item -ItemType Directory -Force -Path $tarOut | Out-Null }
            $found = @()
            if (Test-Path $tarOut) {
              $found = (Get-ChildItem $tarOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
            }
            if (-not $found -or $found.Count -eq 0) {
              try { tar -xzf $dest -C $tarOut } catch { Write-Warning "tar extract failed: $dest ($($_.Exception.Message))"; Log 'TAR_EXTRACT_FAIL' "$dest`t$($_.Exception.Message)" }
              $found = (Get-ChildItem $tarOut -Recurse -ErrorAction SilentlyContinue | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
            }
            # If this is MUSAN and NoiseOnly mode, keep only files within the noise/ category
            if ($found -and ($dest -match '(?i)musan') -and $MusanMode -eq 'NoiseOnly') {
              $found = $found | ForEach-Object {
                try {
                  $rel = $_.Substring($tarOut.Length)
                  $rel = $rel.Replace('\\','/').ToLower()
                  if ($rel -match '/noise/') { $_ }
                } catch { }
              }
            }
            # If this is NSynth, keep only guitar family files (jsonwav archives include instrument family in path)
            if ($found -and ($dest -match '(?i)nsynth')) {
              $found = $found | ForEach-Object {
                try {
                  $rel = $_.Substring($tarOut.Length)
                  $rel = $rel.Replace('\\','/').ToLower()
                  if ($rel -match '/guitar/') { $_ }
                  elseif ($IncludeNSynthNonGuitar) { $_ }
                } catch { }
              }
            }
            if ($found) { if ($IgnoreAppleResourceForks) { $found = $found | Where-Object { -not ([IO.Path]::GetFileName($_).StartsWith('._')) } }; if ($found -and $found.Count -gt 0) { $outputs += $found; $okCount++ } else { $failCount++ } } else { $failCount++ }
        } else { Write-Warning "tar not available; skipping archive $dest"; $failCount++ }
      } elseif ($l.EndsWith('.csv')) {
        Write-Host "Metadata CSV detected (not audio): $dest"
      } else {
        Write-Warning "Unsupported file type: $dest"; $failCount++
      }
    }
    Write-Host "[$subset] successful items: $okCount (downloaded=$downloadedCount, reused=$reusedCount), failed/empty: $failCount"
    # Ensure an array is always returned (even for 0 or 1 element) to make .Count safe
    return ,$outputs
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

  $gFiles = if ($gUrls) { @(Download-And-Collect $gUrls 'guitar') } else { @() }
  $nFiles = if ($nUrls) { @(Download-And-Collect $nUrls 'noise') } else { @() }

  # If Medley-solos-DB metadata CSV is present, filter guitar files by allowed instruments
  if ($PreferMedleyCsv -and $gFiles -and $gFiles.Count -gt 0) {
    try {
      $csvs = Get-ChildItem $dlRoot.FullName -Recurse -Filter 'Medley-solos-DB_metadata.csv' -ErrorAction SilentlyContinue
      if ($csvs) {
        Write-Host "Medley metadata detected; filtering instruments: $($InstrumentAllowList -join ', ')"
        function Import-CsvSmart([string]$path) {
          $first = (Get-Content -LiteralPath $path -TotalCount 1)
          $delim = ','
          if ($first -and ($first.Split(';').Length -gt $first.Split(',').Length)) { $delim = ';' }
          return Import-Csv -LiteralPath $path -Delimiter $delim
        }
        function Get-MedleyAllowedSpec([string[]]$csvPaths, [string[]]$allow) {
          $result = [pscustomobject]@{
            BaseNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            Suffixes  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            UUIDs     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
          }
          foreach ($csv in $csvPaths) {
            $rows = Import-CsvSmart $csv
            $rowCount = 0; $matchCount = 0
            foreach ($r in $rows) {
              $rowCount++
              $cols = @()
              foreach ($candCol in @('instrument','instrument_family','instrument_category','instrument_source','instrument_class')) {
                if ($r.PSObject.Properties.Name -contains $candCol) { $cols += [string]$r.$candCol }
              }
              $match = $false
              foreach ($a in $allow) { if ($cols -match [Regex]::Escape($a)) { $match = $true; break } }
              if (-not $match) { continue }
              $matchCount++
              $cand = $null
              foreach ($k in @('path','audio_filename','filename','file_name','clip_name','slice_file_name','raw_filename')) {
                if ($r.PSObject.Properties.Name -contains $k -and $r.$k) { $cand = [string]$r.$k; break }
              }
              if ($cand) {
                # Normalize CSV path (it usually contains forward slashes even on Windows)
                $candNorm = $cand.Trim().Replace('\\','/')
                if ($candNorm.StartsWith('./')) { $candNorm = $candNorm.Substring(2) }
                try {
                  $bn = [IO.Path]::GetFileName($candNorm)
                  if ($bn) { $null = $result.BaseNames.Add($bn) }
                } catch {}
                # Also store a lower-cased suffix for robust endswith matching against extracted paths
                $candLower = $candNorm.ToLower()
                if (-not [string]::IsNullOrWhiteSpace($candLower)) { $null = $result.Suffixes.Add($candLower) }
              }
              # Capture UUIDs (authoritative mapping according to dataset docs)
              $uuid = $null
              foreach ($uCol in @('uuid4','uuid','uuid_4')) { if ($r.PSObject.Properties.Name -contains $uCol) { $uuid = [string]$r.$uCol; if ($uuid) { break } } }
              if ($uuid) {
                $uuid = $uuid.Trim().ToLower()
                if ($uuid -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { $null = $result.UUIDs.Add($uuid) }
              }
            }
            Write-Host "  Parsed CSV: $csv (rows=$rowCount, matched_rows=$matchCount)"
          }
          return $result
        }
        $spec = Get-MedleyAllowedSpec ($csvs | Select-Object -ExpandProperty FullName) $InstrumentAllowList
        # Limit filtering to files inside the same extraction roots as the metadata CSVs
        $csvRoots = @(); foreach ($c in $csvs) { $csvRoots += (Split-Path -Parent $c.FullName) }
        function Is-UnderAnyRoot([string]$path, [string[]]$roots) {
          $lp = $path.ToLower(); foreach ($r in $roots) { if ($lp.StartsWith($r.ToLower())) { return $true } } return $false
        }
        if ($spec.UUIDs.Count -gt 0 -or $spec.BaseNames.Count -gt 0 -or $spec.Suffixes.Count -gt 0) {
          $before = $gFiles.Count
          $medleyFiles = @(); $otherFiles = @()
          foreach ($gf in $gFiles) { if (Is-UnderAnyRoot $gf $csvRoots) { $medleyFiles += $gf } else { $otherFiles += $gf } }
          $filteredMedley = @()
          foreach ($mf in $medleyFiles) {
            $mfNorm = $mf.Replace('\\','/').ToLower()
            $bn = [IO.Path]::GetFileName($mf)
            $keep = $false
            # Prefer UUID-based match
            if (-not $keep -and $spec.UUIDs.Count -gt 0) {
              $nameNoExt = [IO.Path]::GetFileNameWithoutExtension($bn)
              if ($nameNoExt -like '._*') { $nameNoExt = $nameNoExt.Substring(2) }
              $uuidMatch = Select-String -InputObject $nameNoExt -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -AllMatches | ForEach-Object { $_.Matches } | Select-Object -First 1
              if ($uuidMatch -and $uuidMatch.Value -and $spec.UUIDs.Contains($uuidMatch.Value.ToLower())) {
                # Optional extra safety: ensure filename encodes instrument id "-1_"
                if ($nameNoExt -match '-1_') { $keep = $true } else { $keep = $true }
              }
            }
            if (-not $keep -and $bn -and $spec.BaseNames.Contains($bn)) { $keep = $true }
            if (-not $keep) {
              foreach ($suf in $spec.Suffixes) { if ($mfNorm.EndsWith($suf)) { $keep = $true; break } }
            }
            if ($keep) { $filteredMedley += $mf }
          }
          $gFiles = @() + $otherFiles + $filteredMedley
          $keptMedley = ($filteredMedley | Measure-Object).Count
          $medleyCount = ($medleyFiles | Measure-Object).Count
          $mode = if ($spec.UUIDs.Count -gt 0) { 'UUID' } elseif ($spec.BaseNames.Count -gt 0 -or $spec.Suffixes.Count -gt 0) { 'name/suffix' } else { 'unknown' }
          Write-Host "Medley CSV filter ($mode) kept $keptMedley/$medleyCount Medley files; total guitar files now $($gFiles.Count) (was $before)."
          if ($keptMedley -eq 0 -and $medleyCount -gt 0) {
            Write-Warning "Medley CSV present but no files matched allowed instruments. Checked by UUID, basename, and suffix. Verify archive naming and CSV mapping."
          }
        } else {
          # Fallback: derive instrument tokens from CSV and filter by directory segments
          function Sanitize-Token([string]$s) { if (-not $s) { return '' } return ($s.ToLower() -replace '[^a-z0-9]','') }
          $csvRows = Import-CsvSmart ($csvs[0].FullName)
          $allowedTokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
          foreach ($r in $csvRows) {
            $cols = @()
            foreach ($candCol in @('instrument','instrument_family','instrument_category','instrument_source','instrument_class')) {
              if ($r.PSObject.Properties.Name -contains $candCol) { $cols += [string]$r.$candCol }
            }
            $match = $false
            foreach ($a in $InstrumentAllowList) { if ($cols -match [Regex]::Escape($a)) { $match = $true; break } }
            if (-not $match) { continue }
            foreach ($c in $cols) { $null = $allowedTokens.Add((Sanitize-Token $c)) }
          }
          if ($allowedTokens.Count -eq 0) { foreach ($a in $InstrumentAllowList) { $null = $allowedTokens.Add((Sanitize-Token $a)) } }
          Write-Host ("Medley token filter using tokens: {0}" -f ([string]::Join(', ', $allowedTokens)))
          $before = $gFiles.Count
          $medleyFiles = @(); $otherFiles = @()
          foreach ($gf in $gFiles) { if (Is-UnderAnyRoot $gf $csvRoots) { $medleyFiles += $gf } else { $otherFiles += $gf } }
          $filteredMedley = @()
          foreach ($mf in $medleyFiles) {
            $segs = $mf.Replace('\\','/').ToLower().Split('/') | ForEach-Object { ($_ -replace '[^a-z0-9]','') }
            $keep = $false
            foreach ($tok in $allowedTokens) { if ($segs -contains $tok) { $keep = $true; break } }
            if ($keep) { $filteredMedley += $mf }
          }
          $gFiles = @() + $otherFiles + $filteredMedley
          $keptMedley = ($filteredMedley | Measure-Object).Count
          $medleyCount = ($medleyFiles | Measure-Object).Count
          Write-Host "Medley path-token filter kept $keptMedley/$medleyCount Medley files; total guitar files now $($gFiles.Count) (was $before)."
        }
      }
    } catch {
      Write-Warning "Medley CSV filtering failed: $($_.Exception.Message). Proceeding without filter."
    }
  }

  function Convert-To-48kMono([string[]]$files, [string]$outDir) {
    $ffCommon = @('-hide_banner','-loglevel','error','-nostdin','-threads',"$FfmpegThreadsPerJob")
    $ts = Get-Date -Format yyyyMMddHHmmss
    $validated = 0
    $canProbe = $ValidateBeforeConvert -and (Get-Command ffprobe -ErrorAction SilentlyContinue)
  $skipLog = Join-Path $outDir "_skipped_invalid.txt"
  $skipDurationLog = Join-Path $outDir "_skipped_duration.txt"
  $skipNoAudioLog = Join-Path $outDir "_skipped_no_audio.txt"
  if (Test-Path $skipLog) { Remove-Item $skipLog -Force -ErrorAction SilentlyContinue }
  if (Test-Path $skipDurationLog) { Remove-Item $skipDurationLog -Force -ErrorAction SilentlyContinue }
  if (Test-Path $skipNoAudioLog) { Remove-Item $skipNoAudioLog -Force -ErrorAction SilentlyContinue }
    if ($ValidateBeforeConvert -and -not $canProbe) { Write-Host "Validation requested but ffprobe not found; proceeding without pre-validation." }
  # Concurrent bag only used for potential future metadata capture; keep placeholder
  $converted = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    if ($UseParallel -and $PSVersionTable.PSVersion.Major -ge 7) {
      $throttle = if ($ParallelJobs -gt 0) { $ParallelJobs } else { 4 }
      $files | ForEach-Object -Parallel {
        $f = $_
        if (-not (Test-Path $f -PathType Leaf)) { Write-Warning "Skip (missing): $f"; return }
        try { $len = (Get-Item $f).Length } catch { $len = 0 }
        if (-not $len -or $len -le 0) { Write-Warning "Skip (empty): $f"; return }
        if ($using:ValidateBeforeConvert -and $using:canProbe) {
          try {
            $probe = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of default=nk=1:nw=1 "$f" 2>$null
            if (-not $probe -or $probe.Trim() -eq '') { Add-Content -Path $using:skipNoAudioLog -Value $f; return }
          } catch { Write-Warning "Skip (probe failed): $f"; Add-Content -Path $using:skipLog -Value $f; return }
        }
        if (($using:MinSeconds -gt 0 -or $using:MaxSeconds -gt 0) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
          try {
            $dur = & ffprobe -v error -select_streams a:0 -show_entries stream=duration -of default=nk=1:nw=1 "$f" 2>$null
            [double]$durVal = 0; [double]::TryParse($dur, [ref]$durVal) | Out-Null
            if ($using:MinSeconds -gt 0 -and $durVal -lt $using:MinSeconds) { Add-Content -Path $using:skipDurationLog -Value $f; return }
            if ($using:MaxSeconds -gt 0 -and $durVal -gt $using:MaxSeconds) { Add-Content -Path $using:skipDurationLog -Value $f; return }
          } catch { }
        }
        # generate a unique index per file using its hash and a random salt
        $salt = Get-Random -Minimum 1000 -Maximum 9999
        $name = [IO.Path]::GetFileNameWithoutExtension($f)
        $idx  = [Math]::Abs(("$name$salt").GetHashCode())
        $out = Join-Path $using:outDir ("$($using:ts)_$idx.wav")
        $args = @('-y') + $using:ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        try {
          & ffmpeg @args | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "ffmpeg exit code $LASTEXITCODE" }
          Add-Content -Path (Join-Path $using:outDir '_converted_files.txt') -Value $out
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
        if ($ValidateBeforeConvert -and $canProbe) {
          try {
            $probe = & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of default=nk=1:nw=1 "$f" 2>$null
            if (-not $probe -or $probe.Trim() -eq '') { Add-Content -Path $skipNoAudioLog -Value $f; continue }
          } catch { Write-Warning "Skip (probe failed): $f"; Add-Content -Path $skipLog -Value $f; continue }
        }
        if (($MinSeconds -gt 0 -or $MaxSeconds -gt 0) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
          try {
            $dur = & ffprobe -v error -select_streams a:0 -show_entries stream=duration -of default=nk=1:nw=1 "$f" 2>$null
            [double]$durVal = 0; [double]::TryParse($dur, [ref]$durVal) | Out-Null
            if ($MinSeconds -gt 0 -and $durVal -lt $MinSeconds) { Add-Content -Path $skipDurationLog -Value $f; continue }
            if ($MaxSeconds -gt 0 -and $durVal -gt $MaxSeconds) { Add-Content -Path $skipDurationLog -Value $f; continue }
          } catch {}
        }
        $out = Join-Path $outDir ("${ts}_$count.wav")
        $args = @('-y') + $ffCommon + @('-i', $f, '-ac','1','-ar','48000', $out)
        try {
          & ffmpeg @args | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "ffmpeg exit code $LASTEXITCODE" }
          Add-Content -Path (Join-Path $outDir '_converted_files.txt') -Value $out
        } catch {
          Write-Warning "ffmpeg failed on: $f ($_). Skipping."
          if (Test-Path $out) { try { Remove-Item $out -Force -ErrorAction SilentlyContinue } catch {} }
        }
      }
    }
    $convertedCount = 0
    if (Test-Path (Join-Path $outDir '_converted_files.txt')) {
      $convertedLines = @(Get-Content (Join-Path $outDir '_converted_files.txt'))
      $convertedCount = $convertedLines.Count
    }
    $noAudioCount = 0
  if (Test-Path $skipNoAudioLog) { $noAudioCount = @(Get-Content $skipNoAudioLog | Sort-Object -Unique).Count }
  $invalidCount = 0
  $durationSkipCount = 0
    $invalidList = @()
    if ($ValidateBeforeConvert -and $canProbe) {
      if (Test-Path $skipLog) { $invalidList = Get-Content $skipLog | Sort-Object -Unique; $invalidCount = $invalidList.Count }
    }
  if (Test-Path $skipDurationLog) { $durationSkipCount = @(Get-Content $skipDurationLog | Sort-Object -Unique).Count }
    if ($ValidateBeforeConvert -and $canProbe) {
      Write-Host "Validation summary: converted=$convertedCount, skipped_invalid=$invalidCount, skipped_no_audio=$noAudioCount"
      if ($invalidCount -gt 0) { Write-Host "First invalid (up to 5):"; $invalidList | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" } }
      if ($noAudioCount -gt 0) {
        Write-Warning "Some input files had no audio stream (count=$noAudioCount). See $skipNoAudioLog"
      }
      if ($durationSkipCount -gt 0) { Write-Warning "Duration filter skipped files (count=$durationSkipCount). See $skipDurationLog" }
    } elseif ($noAudioCount -gt 0) {
      Write-Warning "Some input files had no audio stream (count=$noAudioCount). See $skipNoAudioLog"
      if ($durationSkipCount -gt 0) { Write-Warning "Duration filter skipped files (count=$durationSkipCount). See $skipDurationLog" }
    }
    if ($convertedCount -eq 0) {
      $reason = "all inputs skipped"
      if ($noAudioCount -gt 0 -and $invalidCount -eq 0) { $reason = "no files had an audio stream (noAudio=$noAudioCount)" }
      elseif ($invalidCount -gt 0 -and $noAudioCount -eq 0) { $reason = "all files invalid/corrupt (invalid=$invalidCount)" }
      elseif ($invalidCount -gt 0 -and $noAudioCount -gt 0) { $reason = "no valid audio (noAudio=$noAudioCount, invalid=$invalidCount)" }
      throw "Conversion produced zero output files: $reason. See logs in $outDir (_skipped_no_audio.txt / _skipped_invalid.txt)."
    }
  }

  $gCount = if ($null -ne $gFiles -and ($gFiles -is [System.Collections.ICollection])) { $gFiles.Count } elseif ($gFiles) { ($gFiles | Measure-Object).Count } else { 0 }
  $nCount = if ($null -ne $nFiles -and ($nFiles -is [System.Collections.ICollection])) { $nFiles.Count } elseif ($nFiles) { ($nFiles | Measure-Object).Count } else { 0 }
  if ($gCount -gt 0) { Write-Host "Converting guitar files -> $GuitarOut (Parallel=$UseParallel, Jobs=$ParallelJobs, Threads/job=$FfmpegThreadsPerJob)"; Convert-To-48kMono $gFiles $GuitarOut } else { Write-Host "No guitar files downloaded." }
  if ($nCount -gt 0) { Write-Host "Converting noise files -> $NoiseOut (Parallel=$UseParallel, Jobs=$ParallelJobs, Threads/job=$FfmpegThreadsPerJob)"; Convert-To-48kMono $nFiles $NoiseOut } else { Write-Host "No noise files downloaded." }

  if ($WriteDatasetSummary) {
    function Write-Summary([string]$dir,[string]$label) {
      if (-not (Test-Path $dir)) { return }
      $wavFiles = Get-ChildItem $dir -Filter *.wav -File -ErrorAction SilentlyContinue
      if (-not $wavFiles -or $wavFiles.Count -eq 0) { return }
      $rows = @()
      $durations = New-Object System.Collections.Generic.List[double]
      $srSet = New-Object 'System.Collections.Generic.HashSet[int]' ([System.Collections.Generic.EqualityComparer[int]]::Default)
      foreach ($w in $wavFiles) {
        $dur = $null; $sr = $null
        try {
          $ff = & ffprobe -v error -select_streams a:0 -show_entries stream=duration,sample_rate -of csv=p=0 "$($w.FullName)" 2>$null
          if ($ff) {
            $parts = $ff.Split(',')
            if ($parts.Length -ge 2) { [double]::TryParse($parts[0],[ref]$dur) | Out-Null; [int]::TryParse($parts[1],[ref]$sr) | Out-Null }
          }
        } catch {}
        if ($dur -ne $null) { $durations.Add([double]$dur) }
        if ($sr -ne $null) { $srSet.Add($sr) | Out-Null }
        $rows += [pscustomobject]@{ File=$w.FullName; Duration=$dur; SampleRate=$sr; Bytes=$w.Length }
      }
      if ($durations.Count -eq 0) { return }
      $sorted = $durations.ToArray(); [Array]::Sort($sorted)
      $count = $sorted.Length
      $total = ($sorted | Measure-Object -Sum).Sum
      $avg = if ($count -gt 0) { $total / $count } else { 0 }
      $median = if ($count -gt 0) { if ($count % 2 -eq 1) { $sorted[[int]($count/2)] } else { ($sorted[$count/2-1] + $sorted[$count/2]) / 2 } } else { 0 }
      $min = $sorted[0]; $max = $sorted[$count-1]
      $jsonObj = [pscustomobject]@{
        label = $label
        file_count = $count
        total_seconds = [math]::Round($total,3)
        average_seconds = [math]::Round($avg,3)
        median_seconds = [math]::Round($median,3)
        min_seconds = [math]::Round($min,3)
        max_seconds = [math]::Round($max,3)
        sample_rates = $(
          try {
            if ($srSet -and ($srSet -is [System.Collections.IEnumerable]) -and ($srSet.GetType().Name -ne 'Int32')) {
              @($srSet.ToArray())
            } elseif ($srSet -is [int]) {
              @($srSet)
            } else { @() }
          } catch { @() }
        )
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
      }
      $jsonPath = Join-Path $dir 'dataset_summary.json'
      $csvPath  = Join-Path $dir 'dataset_summary.csv'
      $jsonObj | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
      $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath
  # Use ${label} to avoid PowerShell interpreting "$label:" as a scoped variable token
  Write-Host "Dataset summary written for ${label}: $jsonPath; $csvPath"
    }
    Write-Summary $GuitarOut 'guitar'
    Write-Summary $NoiseOut  'noise'
  }

  Write-Host "Fetch complete. Output dirs:"
  Write-Host " - Guitar: $GuitarOut"
  Write-Host " - Noise:  $NoiseOut"
}
finally {
  # Intentionally keep download directory ($TempDownloadDir) to allow reuse / caching.
  # No cleanup performed here.
}
