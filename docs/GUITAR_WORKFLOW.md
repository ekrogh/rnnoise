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

## 10. ONNX Export & Streaming Inference

Two paths:
1. Inline at end of training: add `--export-onnx models/rnnoise.onnx [--onnx-opset 17]` to `train_rnnoise.py` invocation.
2. Standalone: `python ./torch/rnnoise/export_onnx.py --checkpoint models/checkpoints/rnnoise_30.pth --out models/rnnoise.onnx`.

Exported graph inputs/outputs (dynamic by default):
Inputs:
- `features` : (batch, frames, 65)
- `state1|state2|state3` : (1, batch, gru_size)
Outputs:
- `gain` : (batch, frames, 32)
- `vad` : (batch, frames, 1)
- `out_state1|2|3` : updated recurrent states

Disable dynamic axes with `--onnx-no-dynamic` (or `--no-dynamic` in standalone script) if you need fixed shapes for constrained runtimes (will freeze batch=1, frames=`--dummy-seq`).

### Streaming (Frame-by-Frame) Loop
1. Maintain three GRU state buffers (float[gru_size]) initialized to zero.
2. For each decoded 20 ms frame (RNNoise default 480 samples @ 48 kHz):
  - Compute / replicate 65-dim feature vector (must match training pipeline features ordering).
  - Feed `features` with shape (1,1,65) + current states.
  - Receive `gain` (1,1,32) & new states; overwrite local state buffers.
  - Apply per-band gain mapping to spectrum -> inverse transform -> overlap-add.

### Parity Validation Steps
Quick numerical comparison (see README snippet) ensures exported ONNX matches PyTorch reference for a random slice of frames. Accept tiny <1e-4 absolute differences.

Additional recommended checks:
- Deterministic seed: run identical feature sequence through PyTorch & ONNX => compare final GRU states L2 norm.
- End-to-end audio: run a short WAV through both pipelines (C vs ONNX) and compute SNR difference of outputs.

### Deployment Decision Matrix
| Requirement | Choose C Weights | Choose ONNX |
| ----------- | ---------------- | ----------- |
| Minimal binary size | ✓ |  |
| Rapid model iteration (hot-swap) |  | ✓ |
| Hardware acceleration (CoreML/NNAPI) | (via manual port) | ✓ (convert) |
| Easiest debugging with Python tools |  | ✓ |

### JUCE Integration Sketch
Use ONNX Runtime C++ API (ship `onnxruntime` shared lib). Provide fallback to existing C RNNoise path:

Pseudo flow:
```cpp
bool useOnnx = tryInitOnnx();
if(!useOnnx) initCRnnoise();

for(each audio block){
  while(framesRemaining){
    extractFrameFeatures(frameBuf, featureVec); // reuse existing feature code or mirror it
    if(useOnnx){ runOnnx(featureVec, states, gains, prob); }
    else { runCRnnoise(frameBuf, gains, prob); }
    applyGains(frameBuf, gains);
  }
}
```

State lifetimes must persist across audio callback invocations (store in member variables, not stack).

### Known Limitations
- Export currently relies on externally duplicating the 65-dim feature pipeline in your runtime; we do not export feature extraction graph.
- Gradient-sparsification masks are baked into weights after training; pruning structure remains static in exported model.
- Activity head optional loss weighting does not change ONNX interface (still outputs `vad`).

### Future Enhancements
- Provide auxiliary ONNX with feature extraction front-end.
- Add temporal smoothing node (1D conv) fused into exported graph.
- Quantization recipe (dynamic or QAT) to shrink runtime memory.

---
Feel free to extend this guide as new scripts or metrics emerge.
