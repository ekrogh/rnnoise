# Fetch and convert datasets to E: and then run training from E: folders (no fetch)
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File .\run_full_e_drive_pipeline.ps1

$ErrorActionPreference = 'Stop'

# 1. Fetch and convert to E:
& .\scripts\fetch_real_data.ps1 `
  -GuitarUrls .\scripts\urls_guitar.txt `
  -NoiseUrls .\scripts\urls_noise.txt `
  -GuitarOut E:\rnnoise_data\guitar_clean `
  -NoiseOut E:\rnnoise_data\interfere `
  -TempDownloadDir E:\rnnoise_cache `
  -PreferMedleyCsv `
  -MusanMode All `
  -UseParallel `
  -ParallelJobs 8 `
  -FfmpegThreadsPerJob 1 `
  -ValidateBeforeConvert `
  -Downloader Auto `
  -ShowDownloadProgress `
  -WriteDatasetSummary

# 2. Run training from E: datasets (no fetch)
& .\scripts\run_unattended_train.ps1 `
  -DataMode Real `
  -GuitarDir E:\rnnoise_data\guitar_clean `
  -InterfereDir E:\rnnoise_data\interfere `
  -FeatureCount 10000 `
  -Epochs 15 `
  -BatchSize 32 `
  -SequenceLength 1500 `
  -GruSize 256 `
  -CondSize 128 `
  -CudaVisibleDevices 0 `
  -CPUOnly:$false `
  -BuildType Release
