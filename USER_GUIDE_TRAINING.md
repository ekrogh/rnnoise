# RNNoise Guitar-Focused Training Pipeline Guide

This guide explains how to fetch real datasets, prepare features, train a guitar-preserving noise suppressor, and export the C weights for integration.

## TL;DR Normal Command
Typical one-shot end‑to‑end run (download real data if needed, apply duration filtering, generate dataset summaries, train 1 epoch, export weights):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\pipeline_guitar.ps1 \ 
  -FetchFromUrls # Fetch real-data.
```
The rest arguments are default
(See also `scripts/fetch_And_Train_In_One_Go.ps1`).


or

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\pipeline_guitar.ps1
```
All defaults. Uses cached data.

## Resulting files
 - features: D:\Users\eigil\projects\machineLearning\rnnoise\features.f32
 - checkpoints: D:\Users\eigil\projects\machineLearning\rnnoise\models\checkpoints
 - C weights: D:\Users\eigil\projects\machineLearning\rnnoise\models\c\rnnoise_data.[ch] copied into src/
 - built binaries in: D:\Users\eigil\projects\machineLearning\rnnoise\build\Release (includes rnnoise_demo.exe)

## When To Use Each Data Mode
- **Auto (default)**: Uses previously fetched WAVs in `data/guitar_clean` & `data/interfere` if present; otherwise synthesizes a small starter set.
- **Synthetic**: Always re-synthesizes small artificial datasets (useful for quick debugging or environment tests).
- **Real**: Requires `-GuitarDir` and `-InterfereDir` pointing to WAV folders you've curated; no synthesis fallback.

## Fetching Real Data (URL Lists)
Provide plain text URL list files (one per line, optional `#` comments) for guitar and noise:
- `scripts/urls_guitar.txt`
- `scripts/urls_noise.txt`

Optional labels per line (auto-detection only):
```
Archive: https://example.org/dataset
Metadata: https://example.org/dataset_metadata
```
The fetch script attempts archive/metadata suffix variants (`.tar.gz`, `.tgz`, `.zip`, `.csv`, `?download=1`) when needed.

### Multi-Connection Downloads (Option B)
If `aria2c` is installed it will be auto-detected when `-Downloader Auto`.
Install suggestions:
```
winget install aria2
# or
choco install aria2
```
Fallback chain: `aria2c` → builtin PowerShell `Invoke-WebRequest` → `curl.exe`.

### Integrity & Validation
- `.tar.gz` / `.tgz` validated by gzip header + `tar -tzf` listing; corrupt archives deleted & retried with variants.
- Empty or zero-length files skipped.
- Optional pre-probe of audio stream via `ffprobe` (always enabled when available) to detect no-audio containers.

## Conversion & Filtering
All audio is resampled to 48 kHz mono WAV.

Duration filters (applied before conversion):
- `-MinSeconds <float>`: Skip shorter than this (0 = disabled)
- `-MaxSeconds <float>`: Skip longer than this (0 = disabled)

Skip log files per output directory:
- `_skipped_no_audio.txt`
- `_skipped_invalid.txt` (probe/ffmpeg failures)
- `_skipped_duration.txt`

Set `-PerFileSkipWarnings` to re-enable verbose per-file warnings (normally aggregated).

macOS resource fork sidecars (`._*`) are ignored by default (`-IgnoreAppleResourceForks:$true`).

## Dataset Summary
If `-WriteDatasetSummary` is specified, each output directory (guitar/noise) gets:
- `dataset_summary.json`
- `dataset_summary.csv`

JSON fields: label, file_count, total_seconds, average_seconds, median_seconds, min_seconds, max_seconds, sample_rates, generated_utc.
CSV includes row per WAV (File, Duration, SampleRate, Bytes).
You can regenerate summaries later without redownloading:
```powershell
pwsh -File .\scripts\fetch_real_data.ps1 -WriteDatasetSummary -GuitarOut .\data\guitar_clean -NoiseOut .\data\interfere
```

## Feature Extraction & Caching
`pipeline_guitar.ps1` concatenates all WAVs into `speech.pcm` (guitar) and `noise.pcm` (noise), then uses `dump_features.exe` to create `features.f32`.
A cache signature (content, size, timestamps, FeatureCount) is stored in `features.cache.json`.
If unchanged on the next run, feature dumping is skipped:
```
Skipping feature dump (cache hit). Use -ForceRegenFeatures to override.
```
Force recompute:
```powershell
pwsh -File .\scripts\pipeline_guitar.ps1 -FeatureCount 200 -Epochs 1 -BatchSize 64 -ForceRegenFeatures
```

## Training
Training uses PyTorch (CPU by default). Pass `-CPUOnly:$false` to let Torch attempt CUDA.
Artifacts:
- `features.f32`
- `models/checkpoints/rnnoise_<epoch>.pth`
- Exported C weights in `models/c/rnnoise_data.[ch]` and copied to `src/`
- Rebuilt `rnnoise` static/shared library and `rnnoise_demo.exe` inside `build/Release`

## Recommended Iterative Workflow
1. First fetch + short train (sanity):
```powershell
pwsh -File .\scripts\pipeline_guitar.ps1 -FetchFromUrls -FeatureCount 200 -Epochs 1 -BatchSize 64 -MinSeconds 1 -MaxSeconds 10 -WriteDatasetSummary
```
2. Inspect summaries and skip logs.
3. Increase `FeatureCount`, `Epochs` once content looks good:
```powershell
pwsh -File .\scripts\pipeline_guitar.ps1 -FetchFromUrls -FeatureCount 5000 -Epochs 30 -BatchSize 128 -MinSeconds 1 -MaxSeconds 12
```
4. Later run (unchanged data) relies on feature cache; add more data or adjust duration bounds to regenerate.

## Medley-solos-DB Auto Handling
When both `Medley-solos-DB.tar.gz` (or `.tgz`) and `Medley-solos-DB_metadata.csv` are present in the guitar URL list:
- Instrument filter enabled (allow list defaults: guitar, electric_guitar, acoustic_guitar)
- Parallel conversion auto-enabled with job count = CPU cores (unless overridden)
- Non-matching instrument clips omitted.

## Troubleshooting
| Symptom | Cause | Action |
|---------|-------|--------|
| `Conversion produced zero output files` | All skipped (duration / invalid / no audio) | Inspect skip logs, adjust duration or URL list |
| Repeated archive re-downloads | Corrupt partial downloads | Check network stability; manual delete directory `data/_downloads` |
| Feature dump always recomputes | Signature mismatch | Confirm `speech.pcm` / `noise.pcm` not being touched by other processes |
| Slow downloads | aria2c missing | Install aria2 (`winget install aria2`) or force `-Downloader Aria2c` |
| 404 on base Medley URLs | Base URL missing extension | Provided variants auto-tried; ensure network not blocking Zenodo |

## Clean Re-Run (Full Reset)
Remove generated artifacts while keeping cached downloads:
```powershell
Remove-Item .\features.f32 -ErrorAction SilentlyContinue
Remove-Item .\features.cache.json -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force .\models\checkpoints -ErrorAction SilentlyContinue
```
(Do NOT delete `data/_downloads` if you want to retain archives.)

## Extending
Ideas:
- Add loudness (LUFS) to summaries using `ffmpeg -filter_complex ebur128` probing.
- Export ONNX variant of model for experimentation.
- Add histogram bucketing of durations.

## License
See `COPYING` (RNNoise base project license).

---
Generated: (auto doc) – Customize as needed.
