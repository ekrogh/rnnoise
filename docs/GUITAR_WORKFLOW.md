# Guitar Isolation End-to-End Workflow

This document expands the README summary with a detailed, reproducible pipeline for unattended guitar-isolation model improvement using the extended RNNoise fork.

## 1. Smoke Training (Fast Sanity Check)
Use aggressive truncation to ensure the entire cycle (feature dump -> short train -> export -> rebuild) works before longer runs.

```powershell
pwsh ./scripts/run_unattended_train.ps1 `
  -DataMode Real `
  -GuitarDir E:\rnnoise_data\guitar_clean `
  -InterfereDir E:\rnnoise_data\interfere `
  -FeatureCount 4000 `
  -Epochs 2 `
  -BatchSize 32 `
  -SequenceLength 800 `
  -MaxConcatSecondsSpeech 120 `
  -MaxConcatSecondsNoise 120 `
  -UseGuitarActivityLabel `
  -ActivityLossWeight 0.5 `
  -Suffix smoke
```
Artifacts: checkpoints under `models/checkpoints/`, exported C weights under `models/c/` then copied into `src/` and rebuilt.

## 2. Full Training (Baseline)
Scale parameters once smoke passes.

```powershell
pwsh ./scripts/run_unattended_train.ps1 `
  -DataMode Real `
  -GuitarDir E:\rnnoise_data\guitar_clean `
  -InterfereDir E:\rnnoise_data\interfere `
  -FeatureCount 120000 `
  -Epochs 30 `
  -BatchSize 48 `
  -SequenceLength 1500 `
  -GruSize 256 `
  -CondSize 128 `
  -UseGuitarActivityLabel `
  -ActivityLossWeight 0.7 `
  -BuildType Release
```

### Optional: Combined Train + Album Evaluation
Run training and the album evaluation automatically in one step:

```powershell
pwsh ./scripts/full_train_and_eval.ps1 `
  -GuitarDir E:\rnnoise_data\guitar_clean `
  -InterfereDir E:\rnnoise_data\interfere `
  -AlbumDir "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" `
  -FeatureCount 120000 -Epochs 30 -BatchSize 48 -SequenceLength 1500 -GruSize 256 -CondSize 128 -ActivityLossWeight 0.7 -UseCuda -VerboseEval
```

## 3. Album / Single Track Evaluation
Converts MP3 (and optional WAV) -> mono 48k WAV -> raw -> runs isolation -> metrics. Auto-detects if the demo binary supports `--prob-out`; if not, falls back to `--guitar-mask` and derives probability CSV.

Single track example:
```powershell
pwsh ./scripts/album_eval.ps1 -AlbumDir "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King\\01 Riding With the King.mp3" -Verbose
```
Whole directory:
```powershell
pwsh ./scripts/album_eval.ps1 -AlbumDir "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" -IncludeWav -Verbose
```
Outputs: `build/album_eval_temp/*` intermediates and aggregated `build/album_metrics.csv` (now includes `track` column).

Metrics (per track):
- `mid_rms_retention` – head retention ratio (signal preservation early)
- `global_retention` – overall RMS ratio
- `suppression_tail` – tail ratio (lower is better for noise suppression)
- `activity_prop` – fraction of frames with guitar probability > 0.5
- `smooth_factor` – stability of probability evolution
- `composite_score` – weighted composite (higher better)

## 4. Iterative Refinement Loop
Use `scripts/iterate_guitar_refine.ps1` (added earlier) to:
1. Train (short run or partial epochs)
2. Export & rebuild
3. Evaluate album & parse latest composite score
4. Adjust `--activity-loss-weight` and/or gating environment variables
5. Repeat until score plateaus or max iterations reached.

Pseudocode invocation (example):
```powershell
pwsh ./scripts/iterate_guitar_refine.ps1 `
  -AlbumDir "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" `
  -BaseFeatureCount 20000 `
  -EpochsPerIter 5 `
  -MaxIters 6 `
  -InitActivityWeight 0.6
```
(See script header for actual params if they differ.)

Adaptive strategy inside the script (conceptual):
- If composite improves significantly: slightly increase activity weight to encourage sharper discrimination.
- If retention drops or activity_prop saturates (>0.97): decrease weight and/or reduce gating aggressiveness.

## 5. Metrics Interpretation & Tuning Guidelines
| Metric | Desired Direction | Notes |
| ------ | ----------------- | ----- |
| mid_rms_retention | Higher | Avoid >0.95 with poor suppression (may be under-masking) |
| global_retention | Moderate-High | Balance vs suppression; extreme high may mean little filtering |
| suppression_tail | Lower | <0.40 often indicates meaningful noise reduction |
| activity_prop | ~0.6–0.95 | ~1.0 suggests probability head is overconfident |
| smooth_factor | Higher | <0.96 may indicate jitter; consider temporal smoothing |
| composite_score | Higher | Overall proxy for trade-offs |

Adjust levers:
- Increase `--activity-loss-weight` if guitar is being over-suppressed (retention too low) and probabilities seem noisy.
- Decrease it if `activity_prop` saturates and suppression suffers.
- Tune environment gating vars: `RN_GUITAR_THRESHOLD`, `RN_GUITAR_MIN_SCALE`, `RN_GUITAR_EXPONENT`, `RN_GUITAR_DAMPING`.

## 6. Capability Detection & Backwards Compatibility
`album_eval.ps1` inspects demo usage to detect `--prob-out` flag. If absent:
- Uses `--guitar-mask <file>` (extended CSV with band gains) and derives a probability-only CSV.
- Logs demo output per track (`*.demo.log` / `*.retry.demo.log`).
- Retries with sanitized filenames if the first attempt fails (spaces or special chars).

## 7. Common Failure Modes
| Symptom | Cause | Fix |
| ------- | ----- | --- |
| Demo fails "Unknown argument: --prob-out" | Older binary lacking flag | Auto-handled; no action needed |
| Metrics CSV missing track column | Pre-change file exists | Script migrates (backs up `.pre_track.bak`) |
| Activity_prop ~1.0 consistently | Overweighted activity loss | Reduce `--activity-loss-weight` |
| suppression_tail high | Gating too lenient | Increase threshold / exponent or reduce min scale |
| mid/global retention very low | Over-suppression | Lower threshold, raise min scale, or reduce activity loss weight |

## 8. Environment Variables Summary
| Variable | Purpose |
| -------- | ------- |
| RN_GUITAR_THRESHOLD | Base probability threshold for gating curve |
| RN_GUITAR_MIN_SCALE | Minimum applied gain in suppressed bands |
| RN_GUITAR_EXPONENT | Non-linear shaping exponent of gating function |
| RN_GUITAR_DAMPING | Temporal damping / smoothing factor |
| RN_GUITAR_BYPASS | Set to 1 to disable gating for debugging |
| RN_GUITAR_ACTIVITY_WEIGHT | Mirrors activity loss weight for downstream tools (optional) |

## 9. Next Extensions (Roadmap)
- Add probability temporal smoothing kernel in C for lower jitter.
- Implement band-wise evaluation metrics (retain guitar spectral centroid energy).
- Export ONNX for cross-platform inference tests.

---
Feel free to extend this guide as new scripts or metrics emerge.
