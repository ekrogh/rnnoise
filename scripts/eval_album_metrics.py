#!/usr/bin/env python3
import argparse, csv, os, sys, math
import wave
import statistics

def read_wav_mono_48k(path):
    with wave.open(path, 'rb') as w:
        if w.getnchannels() != 1 or w.getframerate() != 48000:
            raise ValueError(f"Expected mono 48k wav: {path}")
        frames = w.getnframes()
        audio = w.readframes(frames)
    import array
    data = array.array('h'); data.frombytes(audio)
    return data

def rms(samples):
    if not samples: return 0.0
    acc = 0.0
    for s in samples: acc += (s/32768.0)**2
    return math.sqrt(acc/len(samples))

# Metrics philosophy:
#  - Guitar retention proxy: RMS of first N seconds (assume start dominated by guitar) processed / original
#  - Global retention: overall RMS processed / original
#  - Suppression: ratio of tail RMS (last N seconds) processed to original (lower is better if tail assumed noise)
#  - Activity calibration: proportion of probability frames > 0.5
#  - Stability: stdev of probability differences of consecutive frames (lower is smoother)
# Provide composite score = (retention_mid * 0.4 + global_retention * 0.3 + (1 - suppression_tail) * 0.3) * (0.5 + 0.5*min(1, act_prop/0.6))

def load_prob_csv(path):
    probs = []
    with open(path, newline='') as f:
        r = csv.reader(f)
        header = next(r, None)
        for row in r:
            if len(row) < 2: continue
            try:
                probs.append(float(row[1]))
            except: pass
    return probs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--original', required=True, help='Original mono 48k wav (pre)')
    ap.add_argument('--processed', required=True, help='Processed mono 48k wav (post)')
    ap.add_argument('--probs', required=True, help='CSV with frame,guitar_prob')
    ap.add_argument('--track', help='Optional track name for CSV output')
    ap.add_argument('--head-sec', type=float, default=10.0, help='Seconds considered guitar-rich at start')
    ap.add_argument('--tail-sec', type=float, default=10.0, help='Seconds considered noise-rich at end')
    ap.add_argument('--frame-size', type=int, default=480)
    ap.add_argument('--out-csv', help='Optional output CSV row append path')
    args = ap.parse_args()

    orig = read_wav_mono_48k(args.original)
    proc = read_wav_mono_48k(args.processed)
    n = min(len(orig), len(proc))
    orig = orig[:n]; proc = proc[:n]

    head_samples = int(args.head_sec * 48000)
    tail_samples = int(args.tail_sec * 48000)

    mid_rms_retention = rms(proc[:head_samples]) / (rms(orig[:head_samples]) + 1e-9)
    global_retention = rms(proc) / (rms(orig) + 1e-9)
    suppression_tail = rms(proc[-tail_samples:]) / (rms(orig[-tail_samples:]) + 1e-9)

    probs = load_prob_csv(args.probs)
    act_prop = sum(p > 0.5 for p in probs) / (len(probs) + 1e-9)
    diffs = [abs(probs[i+1]-probs[i]) for i in range(len(probs)-1)]
    smooth = 1.0 / (1.0 + (statistics.mean(diffs) if diffs else 0.0))

    composite = (mid_rms_retention*0.4 + global_retention*0.3 + (1 - suppression_tail)*0.3) * (0.5 + 0.5*min(1.0, act_prop/0.6)) * smooth

    row = {}
    if args.track:
        row['track'] = args.track
    row.update({
        'mid_rms_retention': mid_rms_retention,
        'global_retention': global_retention,
        'suppression_tail': suppression_tail,
        'activity_prop': act_prop,
        'smooth_factor': smooth,
        'composite_score': composite
    })

    print("Metrics:")
    for k,v in row.items():
        print(f"  {k}: {v:.6f}")

    if args.out_csv:
        newfile = not os.path.exists(args.out_csv)
        # If file exists but header lacks 'track' while we provide it, create a migrated file.
        header_fields = list(row.keys())
        if not newfile:
            try:
                with open(args.out_csv, 'r', newline='') as f_in:
                    rdr = csv.reader(f_in)
                    old_header = next(rdr, [])
                if ('track' in header_fields) and ('track' not in old_header):
                    # Migrate: rename old file and start fresh with new header
                    bak = args.out_csv + '.pre_track.bak'
                    if not os.path.exists(bak):
                        os.replace(args.out_csv, bak)
                    newfile = True
            except Exception:
                pass
        with open(args.out_csv, 'a', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=header_fields)
            if newfile:
                writer.writeheader()
            writer.writerow(row)

if __name__ == '__main__':
    main()
