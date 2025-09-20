pwsh .\scripts\fetch_real_data.ps1 `
  -GuitarOut E:\rnnoise_data\guitar_clean `
  -NoiseOut  E:\rnnoise_data\interfere `
  -TempDownloadDir E:\rnnoise_cache `
  -GuitarUrls .\scripts\urls_guitar.txt `
  -NoiseUrls  .\scripts\urls_noise.txt `
  -Downloader Auto `
  -PreferMedleyCsv `
  -InstrumentAllowList guitar,electric_guitar,acoustic_guitar `
  -UseParallel `
  -ParallelJobs 6 `
  -FfmpegThreadsPerJob 1 `
  -IgnoreAppleResourceForks `
  -WriteDatasetSummary
  
  pwsh .\scripts\pipeline_guitar.ps1 `
  -DataMode Real `
  -GuitarDir E:\rnnoise_data\guitar_clean `
  -InterfereDir E:\rnnoise_data\interfere `
  -FeatureCount 3000 -Epochs 30 -BatchSize 64 `
  -EnableGuitarIsolation -RunEval -EvalLimit 4
  