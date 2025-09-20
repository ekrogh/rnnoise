rnnoise — CMake instructions for Visual Studio 2022 and Windows

**Work in progress**

This repo now includes a `CMakeLists.txt` to generate a Visual Studio 2022 solution or to build using Unix toolchains.

Quick checklist
- Get rnnoise from https://github.com/xiph/rnnoise
- Copy the content in this repository to the root dir. of your copy of https://github.com/xiph/rnnoise
- Generate VS2022 solution and build Release x64
- Enable/disable x86-optimized sources (SSE4.1 / AVX2)
- Build in Android Studio
- Build on WSL / Unix toolchains
- Troubleshoot common MSVC issues (intrinsics / inline asm / missing macros)

Generate a Visual Studio 2022 solution (recommended on Windows)
1. Open "x64 Native Tools Command Prompt for VS 2022" (or Developer PowerShell for VS 2022).
2. From the project root run:

```powershell
mkdir build
cd build
cmake -G "Visual Studio 17 2022" -A x64 -DBUILD_EXAMPLES=ON -DBUILD_TOOLS=ON -DENABLE_AVX2=OFF ..
cmake --build . --config Release
```

- To enable AVX2-optimized sources (if your CPU and MSVC support it):
```powershell
cmake -G "Visual Studio 17 2022" -A x64 -DENABLE_AVX2=ON -DBUILD_EXAMPLES=ON ..
cmake --build . --config Release
```

Notes for MSVC
- `CMakeLists.txt` now sets `/arch:AVX2` for AVX2 when `ENABLE_AVX2=ON`, and defines `__AVX2__` / `__SSE4_1__` for MSVC so the `src/x86/*` compile-time checks pass.
- If compilation fails in `src/x86/*` due to compiler-specific intrinsics or inline assembly, disable x86 optimization options and build the generic code path (set `-DENABLE_AVX2=OFF -DENABLE_SSE4_1=OFF`). I can help adapt the code for MSVC if you want.
- The CMake file adds `_CRT_SECURE_NO_WARNINGS` to reduce CRT warnings.

 Build in Android Studio
 - Install NDK and CMake in Adnroid Studio (SDK Manager)
 - Open the folder ...rnnoise\android in Android Studio
 
Build on WSL / Unix toolchains
- Install a C compiler and make (e.g., `sudo apt install build-essential cmake`), then from project root:

```bash
mkdir build
cd build
cmake -G "Unix Makefiles" ..
make -j$(nproc)
```

- If CMake fails with `CMAKE_MAKE_PROGRAM is not set` or `CMAKE_C_COMPILER not set`, install the system build tools (see above). I tried configuring in WSL earlier and saw that your environment didn't have a build toolchain configured.

Troubleshooting tips
- Linker errors for math functions on MinGW: ensure libm is linked; CMake currently links `m` on non-MSVC toolchains.
- CPU feature detection: `src/x86/x86cpu.c` performs runtime detection; building optimized sources is optional.


*Made by CoPilot GPT-5*
## Guitar Isolation Pipeline (Experimental)

End-to-end unattended training (real data example) which dumps features, trains, exports weights, and rebuilds the demo:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_unattended_train.ps1 `
	-DataMode Real `
	-GuitarDir E:\rnnoise_data\guitar_clean `
	-InterfereDir E:\rnnoise_data\interfere `
	-FeatureCount 10000 -Epochs 15 -BatchSize 32 -SequenceLength 1500 -GruSize 256 -CondSize 128 -CudaVisibleDevices 0 -CPUOnly:$false -BuildType Release
```

Artifacts produced:
- `features.f32` (feature matrix)
- `models/checkpoints/rnnoise_<epoch>.pth` (PyTorch checkpoints)
- `models/c/rnnoise_data.[ch]` exported then copied into `src/`
- Updated binaries in `build/Release/`

### Quick Gating Sweep

Minimal single-point sweep (sanity metrics):
```powershell
pwsh ./scripts/sweep_guitar_gating.ps1 -Single -Limit 2
```
Generates `gating_sweeps/summary.csv` with columns:
`Threshold,MinScale,Exponent,UpDamp,MidRetain,HighRetain,SuppressionDB`

Full grid sweep:
```powershell
pwsh ./scripts/sweep_guitar_gating.ps1 -Limit 20
```

Parameters controlled per iteration via environment vars:
- `RN_GUITAR_GATE_THRESH`
- `RN_GUITAR_MIN_SCALE`
- `RN_GUITAR_SCALE_EXP`
- `RN_GUITAR_UP_DAMP`

Bypass gating entirely (debugging):
```powershell
$env:RN_GUITAR_BYPASS=1; pwsh ./scripts/rnnoise_wav.ps1 -Input input.wav -Output out.wav
```

### Background Isolation Demo
Asynchronous processing + guitar probability + optional per-band gains CSV:
```powershell
build/Release/eks_rnnoise_demo.exe in.raw out.raw --guitar-mask mask.csv --background
```

Simple probability-only logging (lighter than full mask gains):
```powershell
build/Release/eks_rnnoise_demo.exe in.raw out.raw --prob-out probs.csv
```

CSV format: `frame,guitar_prob`

### Album Evaluation (MP3 -> Metrics)

Given an album directory of `.mp3` tracks (will recurse), convert each to mono 48k WAV, run isolation, and compute retention/suppression metrics:
```powershell
pwsh ./scripts/album_eval.ps1 -AlbumDir "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" -Verbose
```
Outputs:
- Temporary converted WAV/RAW/prob files under `build/album_eval_temp/`
- Aggregated metrics appended to `build/album_metrics.csv`

Metrics columns (from `eval_album_metrics.py`):
- `mid_rms_retention`  RMS(processed head) / RMS(original head)
- `global_retention`   RMS(processed full) / RMS(original full)
- `suppression_tail`   RMS(processed tail) / RMS(original tail) (lower better)
- `activity_prop`      Fraction of frames with prob > 0.5
- `smooth_factor`      1/(1+mean|Δprob|) (higher smoother)
- `composite_score`    Weighted composite (higher better)

### Automated Hyperparameter Optimization

Iterate over small grids of activity loss weight + gating parameters (threshold, min scale, exponent, damping), retrain quickly, rebuild, and score on the album metrics:
```powershell
pwsh ./scripts/auto_optimize_guitar.ps1 `
	-AlbumDir "\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" `
	-FeatureCount 6000 -Epochs 6 -BatchSize 32 -SequenceLength 1200 -GruSize 256 -CondSize 128 -BuildType Release
```

Environment variables set per combo (inside the script) map to gating logic (`RN_GUITAR_THRESHOLD`, `RN_GUITAR_MIN_SCALE`, `RN_GUITAR_EXPONENT`, `RN_GUITAR_DAMPING`) plus `RN_GUITAR_ACTIVITY_WEIGHT` (mirrors training CLI weight). Best composite score + config summarized in `build/auto_opt_logs/summary.txt`.

### Workflow Recommendation for Unattended Optimization
1. Run a baseline unattended train (`run_unattended_train.ps1`).
2. Evaluate album: `album_eval.ps1 -AlbumDir <album>`.
3. Launch `auto_optimize_guitar.ps1` for iterative tuning.
4. Inspect `album_metrics.csv` & `auto_opt_logs/summary.txt` for best config.
5. Optionally rerun full (longer) training with selected hyperparameters.

Unified one-shot pipeline (train + album evaluation):
```powershell
pwsh ./scripts/full_train_and_eval.ps1 `
	-GuitarDir E:\rnnoise_data\guitar_clean `
	-InterfereDir E:\rnnoise_data\interfere `
	-AlbumDir "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" `
	-FeatureCount 120000 -Epochs 30 -BatchSize 48 -SequenceLength 1500 -GruSize 256 -CondSize 128 -ActivityLossWeight 0.7 -UseCuda -VerboseEval
```

### Probability Head Weight Tuning
Training flag `--activity-loss-weight` (or set through pipeline script) controls influence of guitar probability calibration. Setting it to 0 disables gradient impact (but still forwards the head), or use `--disable-activity-head` to fully zero its loss contribution.

---
For additional deep-dive notes, see `docs/training_audit_summary.md`.

### Planned Validation
`compare_sequential_vs_background.py` (to be added) will verify divergence between sequential and background modes stays below a tight threshold.

## Extended Guitar Workflow Documentation
For a step-by-step smoke → full training → evaluation → iterative refinement process (including capability detection fallback, metrics interpretation, and tuning heuristics) see:

`docs/GUITAR_WORKFLOW.md`

That document covers:
1. Smoke training with truncation flags
2. Full baseline training
3. Album / single-track evaluation & `--prob-out` fallback mechanism
4. Iterative refinement loop usage
5. Metrics definitions & tuning guidelines
6. Capability detection and backwards compatibility behavior
7. Common failure modes & fixes
8. Environment variable summary