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
  [string]$TempDownloadDir = ""
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

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $GuitarOut -or $GuitarOut -eq '') { $GuitarOut = Join-Path $RepoRoot 'data/guitar_clean' }
if (-not $NoiseOut  -or $NoiseOut  -eq '') { $NoiseOut  = Join-Path $RepoRoot 'data/interfere' }
New-Item -ItemType Directory -Force -Path $GuitarOut | Out-Null
New-Item -ItemType Directory -Force -Path $NoiseOut  | Out-Null

$dlRoot = if ($TempDownloadDir -and $TempDownloadDir -ne '') { New-Item -ItemType Directory -Force -Path $TempDownloadDir } else { New-TempDir 'rnnoise-dl' }

try {
  $audioExt = @('.wav','.flac','.mp3','.ogg','.m4a','.aiff','.aif','.aifc')
  $archiveExt = @('.zip','.tar.gz','.tgz')

  function Download-And-Collect([string[]]$urls, [string]$subset) {
    $outputs = @()
    $subsetDir = Join-Path $dlRoot.FullName $subset
    New-Item -ItemType Directory -Force -Path $subsetDir | Out-Null
    $i = 0
    foreach ($u in $urls) {
      $i++
      $fname = [IO.Path]::GetFileName(($u -replace '\\','/'))
      if (-not $fname) { $fname = "file_$i" }
      $dest = Join-Path $subsetDir $fname
      Write-Host "Downloading [$subset] $u"
      Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing

      $l = $dest.ToLower()
      if ($audioExt | Where-Object { $l.EndsWith($_) }) {
        $outputs += $dest
      } elseif ($l.EndsWith('.zip')) {
        $zipOut = Join-Path $subsetDir ("unzip_" + $i)
        New-Item -ItemType Directory -Force -Path $zipOut | Out-Null
        Expand-Archive -Path $dest -DestinationPath $zipOut -Force
        $outputs += (Get-ChildItem $zipOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
      } elseif ($l.EndsWith('.tar.gz') -or $l.EndsWith('.tgz')) {
        if (Get-Command tar -ErrorAction SilentlyContinue) {
          $tarOut = Join-Path $subsetDir ("untar_" + $i)
          New-Item -ItemType Directory -Force -Path $tarOut | Out-Null
          tar -xzf $dest -C $tarOut
          $outputs += (Get-ChildItem $tarOut -Recurse | Where-Object { $audioExt -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) } | Select-Object -ExpandProperty FullName)
        } else {
          Write-Warning "tar not available; skipping archive $dest"
        }
      } else {
        Write-Warning "Unsupported file type: $dest"
      }
    }
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
    $count = 0
    foreach ($f in $files) {
      $count++
      $base = [IO.Path]::GetFileNameWithoutExtension($f)
      $out = Join-Path $outDir ("$(Get-Date -Format yyyyMMddHHmmss)_$count.wav")
      ffmpeg -y -hide_banner -loglevel error -i $f -ac 1 -ar 48000 $out
    }
  }

  if ($gFiles) { Write-Host "Converting guitar files -> $GuitarOut"; Convert-To-48kMono $gFiles $GuitarOut }
  if ($nFiles) { Write-Host "Converting noise files -> $NoiseOut"; Convert-To-48kMono $nFiles $NoiseOut }

  Write-Host "Fetch complete. Output dirs:"
  Write-Host " - Guitar: $GuitarOut"
  Write-Host " - Noise:  $NoiseOut"
}
finally {
  if (-not $TempDownloadDir -or $TempDownloadDir -eq '') {
    if ($dlRoot -and (Test-Path $dlRoot.FullName)) { Remove-Item $dlRoot.FullName -Recurse -Force }
  }
}
