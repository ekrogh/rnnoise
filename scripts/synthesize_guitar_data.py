"""
Synthesize small guitar-like and interference datasets at 48 kHz mono.

Outputs:
  data/guitar_clean/*.wav   # plucked-string tones (target)
  data/interfere/*.wav      # noise/sine mixtures (interference)

Usage:
  python scripts/synthesize_guitar_data.py

Then run:
  python scripts/make_mixes.py
"""
from __future__ import annotations

import math
import random
from pathlib import Path
from typing import List

import numpy as np
import soundfile as sf


SR = 48000
NUM_GUITAR = 24
NUM_INTERF = 24
MIN_DUR = 4.0
MAX_DUR = 8.0

ROOT = Path(__file__).resolve().parents[1]
DIR_GTR = ROOT / "data" / "guitar_clean"
DIR_INT = ROOT / "data" / "interfere"

random.seed(1234)
np.random.seed(1234)


def karplus_strong(freq: float, dur_s: float, sr: int = SR, decay: float = 0.996) -> np.ndarray:
    """Simple Karplus-Strong plucked-string synthesis."""
    n_samples = int(dur_s * sr)
    if freq < 20:
        freq = 20.0
    period = max(2, int(sr / float(freq)))
    # initial excitation noise
    buf = (np.random.rand(period).astype(np.float32) * 2 - 1) * 0.6
    y = np.zeros(n_samples, dtype=np.float32)
    # simple ring buffer
    idx = 0
    for n in range(n_samples):
        # moving average of two samples with decay
        next_val = decay * 0.5 * (buf[idx] + buf[(idx + 1) % period])
        buf[idx] = next_val
        y[n] = next_val
        idx = (idx + 1) % period
    # gentle envelope to avoid clicks
    t = np.linspace(0, 1, n_samples, dtype=np.float32)
    env = np.minimum(1.0, (t / 0.01)) * np.exp(-3.0 * t)
    return (y * env).astype(np.float32)


def make_guitar_like(duration: float) -> np.ndarray:
    # Standard guitar open-string freqs (Hz)
    base = [82.41, 110.00, 146.83, 196.00, 246.94, 329.63]
    # Build a short phrase of random plucks with small semitone offsets
    out: List[np.ndarray] = []
    t_left = duration
    while t_left > 0.3:
        f0 = random.choice(base) * (2 ** (random.randint(-2, 7) / 12.0))
        d = min(random.uniform(0.2, 1.2), t_left)
        out.append(karplus_strong(f0, d))
        # random short silence between plucks
        gap = min(random.uniform(0.02, 0.12), max(0, t_left - d))
        if gap > 0:
            out.append(np.zeros(int(gap * SR), dtype=np.float32))
        t_left -= (d + gap)
    x = np.concatenate(out) if out else np.zeros(int(duration * SR), dtype=np.float32)
    # mild drive
    x = np.tanh(1.6 * x)
    # normalize
    peak = float(np.max(np.abs(x))) or 1.0
    return (0.7 * x / peak).astype(np.float32)


def band_limited_noise(dur_s: float, f_lo: float, f_hi: float, sr: int = SR) -> np.ndarray:
    n = int(dur_s * sr)
    # white noise
    x = np.random.randn(n).astype(np.float32)
    # simple IIR band shaping via two first-order filters
    # crude but fine for interference
    # high-pass
    rc = 1.0 / (2 * math.pi * max(1.0, f_lo))
    alpha = rc / (rc + 1.0 / sr)
    y = np.zeros_like(x)
    prev_y = 0.0
    prev_x = 0.0
    for i in range(n):
        prev_y = alpha * (prev_y + x[i] - prev_x)
        y[i] = prev_y
        prev_x = x[i]
    # low-pass
    rc2 = 1.0 / (2 * math.pi * max(1.0, f_hi))
    alpha2 = 1.0 / (rc2 * sr + 1.0)
    z = np.zeros_like(y)
    prev = 0.0
    for i in range(n):
        prev += alpha2 * (y[i] - prev)
        z[i] = prev
    # normalize
    peak = float(np.max(np.abs(z))) or 1.0
    return (z / peak).astype(np.float32)


def make_interference(duration: float) -> np.ndarray:
    x = band_limited_noise(duration, 80.0, 12000.0)
    # add a few random sines (simulating musical clutter)
    t = np.arange(int(duration * SR), dtype=np.float32) / SR
    for _ in range(random.randint(1, 4)):
        f = random.uniform(90.0, 2000.0)
        amp = random.uniform(0.1, 0.4)
        x += amp * np.sin(2 * math.pi * f * t + random.uniform(0, 2 * math.pi)).astype(np.float32)
    # mild amplitude modulation to simulate dynamics
    mod_f = random.uniform(0.2, 2.0)
    x *= (0.5 + 0.5 * np.sin(2 * math.pi * mod_f * t + random.uniform(0, 2 * math.pi))).astype(np.float32)
    # normalize
    peak = float(np.max(np.abs(x))) or 1.0
    return (0.7 * x / peak).astype(np.float32)


def main() -> None:
    DIR_GTR.mkdir(parents=True, exist_ok=True)
    DIR_INT.mkdir(parents=True, exist_ok=True)

    # Guitar-like samples
    for i in range(NUM_GUITAR):
        dur = random.uniform(MIN_DUR, MAX_DUR)
        x = make_guitar_like(dur)
        sf.write(str(DIR_GTR / f"gtr_{i:03d}.wav"), x, SR)

    # Interference samples
    for i in range(NUM_INTERF):
        dur = random.uniform(MIN_DUR, MAX_DUR)
        n = make_interference(dur)
        sf.write(str(DIR_INT / f"noise_{i:03d}.wav"), n, SR)

    print("Synth data ready in data/guitar_clean and data/interfere")


if __name__ == "__main__":
    main()
