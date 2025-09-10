"""
Generate noisy/clean pairs for RNNoise training where the target is guitar.

Input folders (create them and put 48k mono WAVs inside):
  data/guitar_clean   -> clean guitar stems (target)
  data/interfere      -> everything else (non-guitar)

Outputs:
  data/train/{noisy,clean}
  data/val/{noisy,clean}

Usage (PowerShell):
  py -3.12 scripts/make_mixes.py
  # or: python scripts/make_mixes.py

Notes:
  - All audio must be 48 kHz mono. Resample beforehand if needed.
  - Adjust N_TRAIN/N_VAL and SNR_RANGE below as desired.
"""
from __future__ import annotations

import glob
import math
import random
from pathlib import Path
from typing import Tuple

import numpy as np
import soundfile as sf


random.seed(1234)
np.random.seed(1234)

ROOT = Path(__file__).resolve().parents[1]
CLEAN_DIR = ROOT / "data" / "guitar_clean"
INTERFERE_DIR = ROOT / "data" / "interfere"
OUT_TRAIN_NOISY = ROOT / "data" / "train" / "noisy"
OUT_TRAIN_CLEAN = ROOT / "data" / "train" / "clean"
OUT_VAL_NOISY = ROOT / "data" / "val" / "noisy"
OUT_VAL_CLEAN = ROOT / "data" / "val" / "clean"

SAMPLE_RATE = 48000
N_TRAIN = 4000  # adjust to your dataset size
N_VAL = 400     # adjust to your dataset size
SNR_RANGE = (-5.0, 15.0)  # dB


def ensure_dirs() -> None:
    for p in [OUT_TRAIN_NOISY, OUT_TRAIN_CLEAN, OUT_VAL_NOISY, OUT_VAL_CLEAN]:
        p.mkdir(parents=True, exist_ok=True)


def load_mono_48k(path: Path) -> np.ndarray:
    x, sr = sf.read(str(path), always_2d=False)
    if x.ndim > 1:
        x = np.mean(x, axis=1)
    if sr != SAMPLE_RATE:
        raise RuntimeError(f"{path} is {sr} Hz; resample to 48k mono before running.")
    return x.astype(np.float32)


def rms(x: np.ndarray) -> float:
    return math.sqrt(max(1e-12, float(np.mean(x ** 2))))


def mix_at_snr(target: np.ndarray, inter: np.ndarray, snr_db: float) -> Tuple[np.ndarray, np.ndarray]:
    # match lengths by tiling or trimming interference
    if len(inter) < len(target):
        reps = int(np.ceil(len(target) / len(inter)))
        inter = np.tile(inter, reps)
    inter = inter[: len(target)]

    t_rms = rms(target)
    i_rms = rms(inter)
    if i_rms < 1e-9:
        scale_i = 0.0
    else:
        desired_i_rms = t_rms / (10.0 ** (snr_db / 20.0))
        scale_i = desired_i_rms / i_rms
    noisy = target + inter * scale_i

    # avoid clipping; scale both identically
    m = float(np.max(np.abs(noisy))) if noisy.size else 0.0
    if m > 0.99:
        noisy = noisy / m * 0.99
        target = target / m * 0.99
    return noisy.astype(np.float32), target.astype(np.float32)


def main() -> None:
    ensure_dirs()
    clean_files = sorted(glob.glob(str(CLEAN_DIR / "**" / "*.wav"), recursive=True))
    inter_files = sorted(glob.glob(str(INTERFERE_DIR / "**" / "*.wav"), recursive=True))

    if not clean_files or not inter_files:
        raise SystemExit(
            "Put WAVs into data/guitar_clean and data/interfere (must be 48k mono)."
        )

    def gen_set(n: int, out_noisy: Path, out_clean: Path, prefix: str) -> None:
        for i in range(n):
            c = Path(random.choice(clean_files))
            itf = Path(random.choice(inter_files))
            snr = random.uniform(*SNR_RANGE)
            tgt = load_mono_48k(c)
            inf = load_mono_48k(itf)
            if len(inf) > len(tgt):
                start = random.randint(0, len(inf) - len(tgt))
                inf = inf[start : start + len(tgt)]
            noisy, clean = mix_at_snr(tgt, inf, snr)
            base = f"{prefix}_{i:06d}"
            sf.write(str(out_noisy / f"{base}_noisy.wav"), noisy, SAMPLE_RATE)
            sf.write(str(out_clean / f"{base}_clean.wav"), clean, SAMPLE_RATE)

    gen_set(N_TRAIN, OUT_TRAIN_NOISY, OUT_TRAIN_CLEAN, "train")
    gen_set(N_VAL, OUT_VAL_NOISY, OUT_VAL_CLEAN, "val")
    print("Done. Outputs in data/train and data/val.")


if __name__ == "__main__":
    main()
