# Guitar Isolation Strategy (RNNoise Adaptation + ONNX Path)

## Objectives
- Suppress all non‑guitar content while retaining guitar tone, dynamics, and transient articulation.
- Maintain real‑time feasibility comparable to original RNNoise (<= 10 ms incremental latency, lightweight CPU footprint) for Path A.
- Provide scalable alternative (Path B) when higher separation accuracy is required and modest extra compute is acceptable.

## Paths Overview
| Path | Description | When to Prefer | Risk | Current Status |
|------|-------------|----------------|------|----------------|
| A | Adapt existing RNNoise (band gain + repurposed VAD as guitar activity → gating) | Low-latency, embedded/edge, incremental improvements | Limited model capacity may cap separation | Active: IRM loss + gating implemented |
| B | New lightweight separation network (Conv/TCN) exported to ONNX, future integration | Higher fidelity separation, more flexible masking (time/freq) | Integration complexity; possibly higher CPU | Prototype model stub + export script added |

## Data & Target Formation
- Mixtures: Guitar (clean/stem) + Interference (ambient noise + non-guitar musical sources (NSynth non‑guitar, MUSAN, DEMAND, optionally FSD50K subsets)).
- Target Mask: Ideal Ratio Mask per RNNoise band: g = sqrt(E_guitar / E_mix).
  - Negative or undefined (edge) values ignored in loss (valid_mask).
  - Dual gamma weighting (gamma vs gamma_low) emphasizes perceptual proportionality while not over‑penalizing low-energy residual guitar.
- Optional mid-mask emphasis (mask_focus) to sharpen discrimination in ambiguous partial overlaps (0.3 < mask < 0.7 region).

## Current RNNoise Modifications (Path A)
1. Training (`train_rnnoise.py`):
   - Added `--gamma-low`, `--low-threshold`, `--mask-focus`.
   - Loss: (pred^gamma - target^gamma)^2 with region-specific gamma & mid-region weight.
   - Negative target gains masked out (retain semantics of IRM >= 0 only).
2. Inference (`denoise.c`):
   - Gating repurposes VAD probability as guitar activity probability.
   - Parameter set (compile or runtime via env):
     - `RN_GUITAR_GATE_THRESH` (activity pivot)
     - `RN_GUITAR_MIN_SCALE` (floor attenuation scale)
     - `RN_GUITAR_SCALE_EXP` (curve exponent)
     - `RN_GUITAR_UP_DAMP` (damp upward surges during low activity)
     - `RN_GUITAR_SMOOTH_ALPHA` (post-gate smoothing floor)
   - Silence decay: historical gains decay when no energy to prevent stale leakage.
3. Evaluation (`evaluate_isolation.py`):
   - Outputs textual & JSON metrics: retention ratios (low/mid/high), suppression score (mean of most attenuated high-frequency quartile), attenuation histogram.
4. Sweep Script (`scripts/sweep_guitar_gating.ps1`):
   - Automates grid search over gating parameters with aggregated CSV summary.

## Proposed Enhancements (Short Term)
| Priority | Item | Rationale |
|----------|------|-----------|
| High | Add ground-truth aligned evaluation (if guitar-only stems available) computing true SNR delta | More reliable metric than proxy energy retention |
| High | Integrate early stopping / validation loss logging separated by mask regions | Prevent overfitting high-mask easy zones |
| Med | Adaptive gating: use short-term variance of predicted gains to modulate up_damp dynamically | Reduce pumping at transitions |
| Med | Add light harmonic enhancer (post-filter) restricted to bands where mask>0.8 & activity high | Recover brightness lost to conservative smoothing |
| Low | Quantize model weights (int8) after stability | Edge deployment size/power benefits |

## Escalation Criteria to Path B (ONNX)
Trigger migration if ANY of:
- Suppression score plateau despite parameter sweeps (< -8 dB average high-band attenuation for strong interference).
- Mid retain < 0.70 while high retain already suppressed (indicating model capacity limiting separation selectivity).
- Transient smear complaints: pick attack audibly dulled even after harmonic enhancer attempts.
- Latency budget allows modest increase (up to ~30 ms window) for temporal context improvement.

## Path B Outline
1. Architecture: Depthwise separable Conv encoder + causal TCN blocks + mask head (already stubbed in `torch/guitar_sep/model.py`).
2. Input Representation: Either reuse RNNoise band energies + pitch features OR switch to STFT magnitude (256–512 window, 50% hop) with per-band grouping.
3. Output: Frame-aligned mask (linear magnitude or power) applied then overlap-add.
4. Export: ONNX with dynamic frame axis; runtime: onnxruntime (inference) or custom C++ minimal op subset.
5. Integration: Replace RNNoise compute_rnn path with optional ONNX session branch behind build flag.

## Long-Term Ideas
- Multi-head output: (guitar mask, broad-band noise mask, harmonic residue mask) with joint regularization.
- Confidence metric derived from ensemble of small subnetworks (Monte Carlo dropout variant) to adapt gating aggressiveness.
- Learned activity probability (replace current VAD-repurposed output) trained with weak labels from guitar presence heuristics.

## Parameter Tuning Workflow (Path A)
1. Train base model (capture checkpoint with validation metrics).
2. Run `sweep_guitar_gating.ps1` over chosen grid.
3. Inspect `summary.csv` focusing on tuple maximizing: high suppression (more negative better) while keeping mid retain >= 0.80 and high retain <= 0.50.
4. Narrow grid around best combination; optionally adjust exponent & smoothing separately.
5. Rebuild or just re-run with env overrides for final candidate set.

## Metrics Interpretation
- retain_mid (~0.8–0.9 desirable): strong preservation of guitar fundamentals & body.
- retain_high (0.3–0.6): indicates selective suppression of non-guitar brightness; extremely low (<0.2) may dull articulation.
- suppression_score_db (target <= -10 dB for challenging interference): more negative indicates better removal.

## Risks & Mitigations
| Risk | Impact | Mitigation |
|------|--------|-----------|
| Over-suppression removing harmonics | Dull tone | Tune `RN_GUITAR_MIN_SCALE` upward slightly (0.10→0.15) and increase `smooth_alpha` |
| Pumping artifacts | Audible breathing | Increase `up_damp`, add adaptive smoothing window |
| Slow improvement with more data | Diminishing returns | Introduce curriculum: start with clear SNR mixes, gradually add difficult blends |
| Model drift across retrains | Inconsistent results | Version gating parameters + store evaluation JSON alongside checkpoint |

## Immediate Next Steps
1. (Optional) Add guitar-reference evaluation if stems accessible.
2. Perform first sweep and select candidate gating tuple.
3. Implement optional harmonic enhancement stage (if brightness loss observed).
4. Decide if Path B escalation criteria are met after two iterations.

---
Generated: (autonomous assistant) — Rev 1
