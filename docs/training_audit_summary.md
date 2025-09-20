# Training Audit & Next Steps (Guitar Isolation)

## Current Pipeline Status
- Feature dump: working (`dump_features.exe`) with caching via `features.cache.json`.
- Training: PyTorch script `torch/rnnoise/train_rnnoise.py` updated with configurable `--activity-loss-weight` and `--disable-activity-head`.
- Background demo: `eks_rnnoise_demo.exe` exposes per-frame guitar probability + optional band gains mask output.
- Gating sweep: `sweep_guitar_gating.ps1` (+ `-Single`) produces `gating_sweeps/summary.csv`.

## Data / Label Semantics
Current feature layout (dim=98):
- 0:64  -> input features (65)
- 65:-1 -> target gains (32 bands) + trailing? (adjust per architecture) up to index -2
- -1     -> activity probability (originally speech VAD, repurposed for guitar activity)

Action: If a dedicated guitar-active flag differs from the original VAD logic, extend feature builder to compute explicit energy ratio based label and append as last channel (update dataset dim accordingly).

## Loss Function Update
```
loss = gain_loss + activity_weight * vad_loss
activity_weight = 0 if --disable-activity-head else --activity-loss-weight
```
Default: 0.0005 (legacy behavior). You can raise to emphasize probability calibration.

## Recommended Experiments
| Goal | Params |
|------|--------|
| Baseline (current) | `--activity-loss-weight 0.0005` |
| Stronger prob supervision | `--activity-loss-weight 0.002` |
| Disable probability head | `--disable-activity-head` |

Monitor: mean `vad_loss` trend and resulting gating quality (retain vs suppression) using small gating sweep after each trained model.

## Divergence Validation
Use `compare_sequential_vs_background.py` to ensure asynchronous path fidelity:
```
python scripts/compare_sequential_vs_background.py --input test.wav \
  --rnnoise-demo build/Release/rnnoise_demo.exe \
  --eks-demo build/Release/eks_rnnoise_demo.exe \
  --frames 600 --collect-mask --report compare_report.json
```
Target: `mean_diff_rms` < 1e-3 relative to average signal RMS for transparent background path.

## Suggested Next Improvements
1. Add explicit guitar activity label generation in feature dump phase (energy ratio + threshold + temporal smoothing).
2. Add early stopping / learning rate plateau scheduler (monitor moving average of validation set once added).
3. Introduce small validation split (e.g., last 5% sequences) to detect overfit and collect gating metrics mid-training.
4. Quantization-aware fine-tuning step prior to C weight export if we enlarge model.
5. Integrate MP3 album evaluation helper (batch convert & process) for subjective listening tests.

## MP3 Album Evaluation (Manual Steps)
```
$album='\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King'
$wavOut='album_wav_48k'
mkdir $wavOut -Force
Get-ChildItem $album -Filter *.mp3 | ForEach-Object {
  $base = [IO.Path]::GetFileNameWithoutExtension($_.Name)
  ffmpeg -y -hide_banner -loglevel error -i $_.FullName -ar 48000 -ac 1 "$wavOut/$base.wav"
}
# Process each wav with rnnoise_wav.ps1 (add gating env tuning as desired)
Get-ChildItem $wavOut -Filter *.wav | ForEach-Object {
  $o = "${_}.isolated.wav"
  pwsh ./scripts/rnnoise_wav.ps1 -Input $_.FullName -Output $o
}
```

## Checkpoint Naming Convention
Checkpoints saved as `rnnoise{suffix}_<epoch>.pth`. Ensure `--suffix` distinguishes experiments (e.g., `_actw2e3`).

## Retraining Template
```
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_unattended_train.ps1 \
  -DataMode Real -GuitarDir E:\rnnoise_data\guitar_clean -InterfereDir E:\rnnoise_data\interfere \
  -FeatureCount 10000 -Epochs 30 -BatchSize 32 -SequenceLength 1500 -GruSize 256 -CondSize 128 -CudaVisibleDevices 0 -CPUOnly:$false -BuildType Release
# After feature dump, manually re-run training with modified activity weight if needed:
python torch/rnnoise/train_rnnoise.py features.f32 models --epochs 30 --batch-size 32 \
  --sequence-length 1500 --gru-size 256 --cond-size 128 --activity-loss-weight 0.002 --suffix _actw2e3
```

## Success Criteria Summary
- Mean diff RMS (seq vs bg) < 1e-3 (scaled) ✔ when validated.
- Gating sweep shows high MidRetain (>0.94) while pushing SuppressionDB upward, tune threshold/exponent accordingly.
- Activity head calibration stable (vad_loss decreasing smoothly and not saturating at 0 or diverging).

---
Generated: automated assistant (2025-09-20)
