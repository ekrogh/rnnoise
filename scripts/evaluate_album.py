#!/usr/bin/env python3
"""
Evaluate rnnoise model performance over a directory/UNC path of audio files.
Computes basic loudness / spectral statistics before & after denoising.

Usage:
  python scripts/evaluate_album.py \
      --input "\\\buffalo\Media\Music\iTunes\iTunes Media\Music\Eric Clapton_B.B. King\Riding with the King" \
      --output metrics_album.csv

Outputs:
  CSV with columns:
    file, samplerate, dur_s, rms_in, rms_out, rms_reduction_db, band_low_in_db, band_low_out_db, ...
    snr_like_db (ratio of retained energy to removed energy heuristic)

Notes:
  - rnnoise_demo works on 16-bit 48k mono raw PCM; we use ffmpeg to pipe.
  - This is a heuristic diagnostic, not a formal perceptual quality metric.
  - band_* are energies in frequency bands (0-300 Hz, 300-1500 Hz, 1.5-4 kHz, 4-8 kHz, 8-12 kHz, 12-24 kHz limited by Nyquist).
"""
import argparse, csv, subprocess, sys, math, tempfile, shutil, os, statistics, json
from pathlib import Path
import wave
import struct

BANDS = [(0,300),(300,1500),(1500,4000),(4000,8000),(8000,12000),(12000,24000)]

def run_ffmpeg_to_pcm(src: str, tmp_wav: Path):
    # Convert to mono 48k 16-bit wav for easier Python reading
    cmd = ["ffmpeg","-hide_banner","-nostdin","-y","-i",src,"-ac","1","-ar","48000",str(tmp_wav)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def wav_to_samples(wav_path: Path):
    with wave.open(str(wav_path), 'rb') as w:
        assert w.getnchannels()==1 and w.getsampwidth()==2 and w.getframerate()==48000
        frames = w.getnframes()
        raw = w.readframes(frames)
        samples = struct.unpack('<' + 'h'*frames, raw)
        return [s/32768.0 for s in samples], 48000

def run_rnnoise_demo(pcm_in: Path, pcm_out: Path, demo_exe: Path):
    subprocess.run([str(demo_exe), str(pcm_in), str(pcm_out)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def wav_to_pcm_raw(wav_path: Path, pcm_path: Path):
    subprocess.run(["ffmpeg","-hide_banner","-nostdin","-y","-i",str(wav_path),"-f","s16le","-ac","1","-ar","48000",str(pcm_path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def pcm_raw_to_wav(pcm_path: Path, wav_path: Path):
    subprocess.run(["ffmpeg","-hide_banner","-nostdin","-y","-f","s16le","-ac","1","-ar","48000","-i",str(pcm_path), str(wav_path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def rms(samples):
    if not samples: return 0.0
    return math.sqrt(sum(s*s for s in samples)/len(samples))

try:
    import numpy as np
except ImportError:
    print("Installing numpy locally required for evaluation...", file=sys.stderr)
    subprocess.run([sys.executable, '-m', 'pip', 'install', 'numpy'], check=True)
    import numpy as np

from numpy.fft import rfft, rfftfreq

def band_energies(samples, sr):
    if not samples: return [0.0]*len(BANDS)
    arr = np.array(samples, dtype=np.float32)
    # single FFT (no windowing for speed; acceptable for broad bands)
    spec = np.abs(rfft(arr))
    freqs = rfftfreq(len(arr), 1.0/sr)
    energies = []
    for lo,hi in BANDS:
        mask = (freqs>=lo) & (freqs<hi)
        val = float(np.sum(spec[mask]**2)) if np.any(mask) else 0.0
        energies.append(val + 1e-12)
    return energies

def to_db(x):
    return 20*math.log10(x) if x>0 else -120.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True, help='Directory or single file (UNC path ok)')
    ap.add_argument('--output', required=True, help='Output CSV path')
    ap.add_argument('--demo-exe', default='build/Release/rnnoise_demo.exe', help='Path to rnnoise_demo.exe')
    ap.add_argument('--limit', type=int, default=0, help='Optional max number of files to evaluate')
    args = ap.parse_args()

    demo = Path(args.demo_exe)
    if not demo.exists():
        print(f"rnnoise_demo not found: {demo}", file=sys.stderr)
        sys.exit(1)

    target = Path(args.input)
    files = []
    if target.is_file():
        files = [target]
    else:
        if not target.exists():
            print(f"Input path not found: {target}", file=sys.stderr)
            sys.exit(1)
        exts = {'.wav','.mp3','.flac','.m4a','.aac','.ogg'}
        for p in sorted(target.glob('*')):
            if p.suffix.lower() in exts:
                files.append(p)
    if args.limit>0:
        files = files[:args.limit]
    if not files:
        print("No audio files found.", file=sys.stderr)
        sys.exit(1)

    out_rows = []
    tmpdir = Path(tempfile.mkdtemp(prefix='rnnoise_eval_'))
    try:
        for f in files:
            try:
                tmp_wav_in = tmpdir / 'in.wav'
                tmp_pcm_in = tmpdir / 'in.pcm'
                tmp_pcm_out= tmpdir / 'out.pcm'
                run_ffmpeg_to_pcm(str(f), tmp_wav_in)
                samples_in, sr = wav_to_samples(tmp_wav_in)
                wav_to_pcm_raw(tmp_wav_in, tmp_pcm_in)
                run_rnnoise_demo(tmp_pcm_in, tmp_pcm_out, demo)
                # decode output pcm for analysis
                tmp_wav_out = tmpdir / 'out.wav'
                pcm_raw_to_wav(tmp_pcm_out, tmp_wav_out)
                samples_out,_ = wav_to_samples(tmp_wav_out)
                dur_s = len(samples_in)/sr if sr>0 else 0
                rms_in = rms(samples_in)
                rms_out= rms(samples_out)
                rms_red_db = to_db(rms_in+1e-12) - to_db(rms_out+1e-12)
                be_in = band_energies(samples_in, sr)
                be_out= band_energies(samples_out, sr)
                # crude snr-like ratio: preserved mid-band (300-4k) energy vs attenuation outside mid-band
                # mid bands index 1+2
                mid_in = sum(be_in[1:3]); mid_out = sum(be_out[1:3])
                non_in = sum(be_in) - mid_in; non_out = sum(be_out) - mid_out
                snr_like = (mid_out+1e-9)/(non_out+1e-9)
                row = {
                    'file': str(f),
                    'samplerate': sr,
                    'dur_s': f"{dur_s:.2f}",
                    'rms_in': f"{rms_in:.6f}",
                    'rms_out': f"{rms_out:.6f}",
                    'rms_reduction_db': f"{rms_red_db:.2f}",
                    'snr_like_db': f"{to_db(snr_like):.2f}",
                }
                for (lo,hi),vin,vout in zip(BANDS, be_in, be_out):
                    row[f'band_{lo}_{hi}_in_db'] = f"{to_db(math.sqrt(vin)):.2f}"
                    row[f'band_{lo}_{hi}_out_db']= f"{to_db(math.sqrt(vout)):.2f}"
                out_rows.append(row)
                print(f"Processed: {f.name} rms_in={row['rms_in']} rms_out={row['rms_out']} red_db={row['rms_reduction_db']}")
            except subprocess.CalledProcessError as e:
                print(f"WARN: Failed on {f}: {e}", file=sys.stderr)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # write CSV
    fieldnames = list(out_rows[0].keys()) if out_rows else []
    with open(args.output, 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames)
        w.writeheader(); w.writerows(out_rows)
    print(f"Wrote metrics: {args.output} ({len(out_rows)} files)")

if __name__ == '__main__':
    main()
