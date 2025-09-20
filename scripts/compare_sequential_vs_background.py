#!/usr/bin/env python3
"""
Compare sequential rnnoise_demo vs background (eks_rnnoise_demo --background) processing on the same 16-bit 48k mono WAV (or raw) input.
Outputs a JSON report with per-frame RMS difference and optional guitar probability divergence if mask CSV is emitted.
Usage:
  python compare_sequential_vs_background.py --input input.wav \
    --rnnoise-demo build/Release/rnnoise_demo.exe \
    --eks-demo build/Release/eks_rnnoise_demo.exe \
    --frames 400 --report compare_report.json

Notes:
 - We convert WAV to raw s16le if needed using ffmpeg (must be in PATH).
 - eks demo guitar mask collected when --collect-mask specified; divergence
   is computed on probability series if both paths produce probabilities.
"""
import argparse, subprocess, os, json, tempfile, shutil, struct, math
from statistics import mean

def run(cmd, check=True):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode!=0:
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\nSTDERR:\n{proc.stderr.decode(errors='ignore')}")
    return proc

def wav_to_raw(path, out_raw):
    # Convert any wav to s16le mono 48k raw
    cmd = ['ffmpeg','-y','-hide_banner','-loglevel','error','-i',path,'-f','s16le','-acodec','pcm_s16le','-ac','1','-ar','48000',out_raw]
    run(cmd)

def read_pcm_s16(raw_path):
    with open(raw_path,'rb') as f:
        data = f.read()
    samples = struct.unpack('<' + 'h'*(len(data)//2), data)
    return samples

def rms(a):
    if not a: return 0.0
    return math.sqrt(sum(x*x for x in a)/len(a))

def frame_iter(samples, frame=480):
    for i in range(0, len(samples)-frame+1, frame):
        yield samples[i:i+frame]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True, help='Input WAV or raw s16le 48k mono file')
    ap.add_argument('--rnnoise-demo', default='build/Release/rnnoise_demo.exe')
    ap.add_argument('--eks-demo', default='build/Release/eks_rnnoise_demo.exe')
    ap.add_argument('--frames', type=int, default=0, help='Limit number of frames processed (0=all)')
    ap.add_argument('--report', default='compare_report.json')
    ap.add_argument('--collect-mask', action='store_true', help='Collect guitar mask CSV from eks demo for probability divergence metrics')
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix='cmp_rnnoise_')
    try:
        raw_in = os.path.join(work,'in.raw')
        # Detect if already raw (heuristic: extension .raw)
        if args.input.lower().endswith('.raw'):
            shutil.copyfile(args.input, raw_in)
        else:
            wav_to_raw(args.input, raw_in)

        seq_out = os.path.join(work,'seq.raw')
        bg_out = os.path.join(work,'bg.raw')
        mask_csv = os.path.join(work,'mask.csv') if args.collect_mask else None

        # Sequential path: standard rnnoise_demo (reads raw, writes raw)
        run([args.rnnoise_demo, raw_in, seq_out])
        # Background path: eks demo; for fairness run in foreground but with --background to exercise ring path
        cmd_bg = [args.eks_demo, raw_in, bg_out, '--background']
        if mask_csv:
            cmd_bg += ['--guitar-mask', mask_csv]
        run(cmd_bg)

        seq_samples = read_pcm_s16(seq_out)
        bg_samples = read_pcm_s16(bg_out)
        n = min(len(seq_samples), len(bg_samples))
        seq_samples = seq_samples[:n]
        bg_samples = bg_samples[:n]

        frame = 480
        frame_diffs = []
        frame_rms_seq = []
        frame_rms_bg = []
        diff_rms = []
        count_frames = 0
        for f_idx, (fa, fb) in enumerate(zip(frame_iter(seq_samples, frame), frame_iter(bg_samples, frame))):
            if args.frames and f_idx >= args.frames: break
            da = rms(fa)
            db = rms(fb)
            frame_rms_seq.append(da)
            frame_rms_bg.append(db)
            diff = [fa[i]-fb[i] for i in range(len(fa))]
            d_rms = rms(diff)
            diff_rms.append(d_rms)
            frame_diffs.append({'frame': f_idx, 'seq_rms': da, 'bg_rms': db, 'diff_rms': d_rms})
            count_frames += 1

        report = {
            'frames_compared': count_frames,
            'mean_seq_rms': mean(frame_rms_seq) if frame_rms_seq else 0.0,
            'mean_bg_rms': mean(frame_rms_bg) if frame_rms_bg else 0.0,
            'mean_diff_rms': mean(diff_rms) if diff_rms else 0.0,
            'max_diff_rms': max(diff_rms) if diff_rms else 0.0,
            'frame_stats': frame_diffs[:50]  # truncate for brevity
        }

        if mask_csv and os.path.exists(mask_csv):
            # Parse probabilities
            probs = []
            with open(mask_csv,'r') as f:
                header = f.readline()
                for line in f:
                    parts = line.strip().split(',')
                    if len(parts) >= 2:
                        try:
                            probs.append(float(parts[1]))
                        except:
                            pass
            if probs:
                report['guitar_prob'] = {
                    'frames_logged': len(probs),
                    'mean_prob': mean(probs),
                    'max_prob': max(probs),
                    'min_prob': min(probs)
                }

        with open(args.report,'w') as f:
            json.dump(report, f, indent=2)
        print(f"Report written: {args.report}\nMean diff RMS: {report['mean_diff_rms']:.6f}")
    finally:
        # Keep artifacts for inspection? Comment out next line to keep temp dir
        shutil.rmtree(work, ignore_errors=True)

if __name__ == '__main__':
    main()
