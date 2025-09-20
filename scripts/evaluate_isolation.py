#!/usr/bin/env python3
"""
Quick-and-dirty evaluation for guitar isolation sweeps.
Given an input directory of WAV files that are assumed to be (mostly) guitar, we:
 1. Run a few seconds (or up to --limit files) through rnnoise_demo with optional env gating params already set by caller.
 2. Treat original file as reference and processed output as retained signal; compute simple RMS retain metrics on mid/high bands via FFT.
 3. (No pure noise reference available here) Provide a pseudo suppression score based on relative attenuation of low-energy bands.
Outputs per-file JSON list with: file, retain_mid, retain_high, suppression_score_db.
This is intentionally lightweight to allow parameter sweeps; not a rigorous audio quality metric.
"""

import argparse, json, math, os, subprocess, tempfile, wave, contextlib, sys
import numpy as np

FRAME = 480

def read_wav_mono_48k(path):
	with contextlib.closing(wave.open(path, 'rb')) as w:
		if w.getframerate() != 48000:
			raise RuntimeError(f"Expected 48k sample rate: {path}")
		if w.getnchannels() != 1:
			raise RuntimeError(f"Expected mono wav: {path}")
		pcm = w.readframes(w.getnframes())
		data = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
	return data

def write_raw16(path, data):
	q = np.clip(np.round(data * 32768.0), -32768, 32767).astype('<i2')
	with open(path, 'wb') as f:
		f.write(q.tobytes())

def process_with_demo(demo_exe, wav_path):
	# rnnoise_demo expects raw 16-bit in/out. We'll create temp raw, run, capture output raw, then return float array.
	x = read_wav_mono_48k(wav_path)
	# Pad to multiple of FRAME
	if len(x) % FRAME:
		pad = FRAME - (len(x) % FRAME)
		x = np.concatenate([x, np.zeros(pad, dtype=np.float32)])
	with tempfile.TemporaryDirectory() as td:
		in_raw = os.path.join(td, 'in.raw')
		out_raw = os.path.join(td, 'out.raw')
		write_raw16(in_raw, x)
		cmd = [demo_exe, in_raw, out_raw]
		try:
			subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
		except subprocess.CalledProcessError as e:
			raise RuntimeError(f"demo failed on {wav_path}: {e}")
		with open(out_raw, 'rb') as f:
			y = np.frombuffer(f.read(), dtype='<i2').astype(np.float32) / 32768.0
	return x, y

def band_rms(x, sr=48000, mid=(500,2000), high=(2000,6000)):
	# Simple FFT-based band RMS
	win = np.hanning(len(x))
	X = np.fft.rfft(x * win)
	freqs = np.fft.rfftfreq(len(x), 1/sr)
	def rms_band(lo, hi):
		idx = (freqs >= lo) & (freqs < hi)
		if not np.any(idx):
			return 0.0
		power = np.mean(np.abs(X[idx])**2)
		return math.sqrt(power)
	return rms_band(*mid), rms_band(*high)

def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('--input-dir', required=True)
	ap.add_argument('--demo-exe', required=True)
	ap.add_argument('--limit', type=int, default=5)
	ap.add_argument('--ext', default='.wav')
	ap.add_argument('--report', required=True)
	ap.add_argument('--json', required=True)
	args = ap.parse_args()

	wavs = [os.path.join(args.input_dir, f) for f in os.listdir(args.input_dir) if f.lower().endswith(args.ext.lower())]
	wavs.sort()
	wavs = wavs[:args.limit]
	if not wavs:
		print("No wav files found for evaluation", file=sys.stderr)
		open(args.json,'w').write('[]')
		open(args.report,'w').write('Empty dataset')
		return

	rows = []
	for wpath in wavs:
		try:
			orig, proc = process_with_demo(args.demo_exe, wpath)
			mid_o, high_o = band_rms(orig)
			mid_p, high_p = band_rms(proc)
			retain_mid = (mid_p / (mid_o + 1e-9))
			retain_high = (high_p / (high_o + 1e-9))
			# Pseudo suppression: average attenuation outside mid/high bands (0-300 Hz & 6-8 kHz slice) vs inside
			# Simplistic: ratio of overall RMS difference.
			rms_o = np.sqrt(np.mean(orig**2))
			rms_p = np.sqrt(np.mean(proc**2))
			suppression_db = 20*math.log10((rms_o+1e-9)/(rms_p+1e-9)) if rms_p < rms_o else 0.0
			rows.append({
				'file': os.path.basename(wpath),
				'retain_mid': float(retain_mid),
				'retain_high': float(retain_high),
				'suppression_score_db': float(suppression_db)
			})
		except Exception as ex:
			rows.append({'file': os.path.basename(wpath), 'error': str(ex)})

	with open(args.json,'w') as f:
		json.dump(rows, f, indent=2)
	# Write simple text report
	good = [r for r in rows if 'retain_mid' in r]
	if good:
		mid_avg = sum(r['retain_mid'] for r in good)/len(good)
		high_avg = sum(r['retain_high'] for r in good)/len(good)
		supp_avg = sum(r['suppression_score_db'] for r in good)/len(good)
	else:
		mid_avg = high_avg = supp_avg = 0.0
	with open(args.report,'w') as f:
		f.write(f"Files evaluated: {len(rows)}\n")
		f.write(f"Avg retain_mid: {mid_avg:.4f}\n")
		f.write(f"Avg retain_high: {high_avg:.4f}\n")
		f.write(f"Avg suppression_db: {supp_avg:.2f}\n")
	print(f"Evaluation complete: {args.json}")

if __name__ == '__main__':
	main()
