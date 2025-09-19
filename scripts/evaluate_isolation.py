import argparse
import subprocess
import json
from pathlib import Path
import numpy as np

def rms(sig: np.ndarray):
    if sig.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(sig.astype(np.float64)**2) + 1e-12))

def load_wav(path: Path):
    import soundfile as sf
    data, sr = sf.read(str(path))
    if data.ndim > 1:
        data = np.mean(data, axis=1)
    return data, sr

def run_rnnoise_demo(demo_exe: Path, infile: Path, outfile: Path):
    # ffmpeg decode -> s16le pipe -> rnnoise_demo -> wav encode
    cmd = [
        'ffmpeg','-hide_banner','-loglevel','error','-i',str(infile),
        '-f','s16le','-ac','1','-ar','48000','-']
    p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    p2 = subprocess.Popen([str(demo_exe)], stdin=p1.stdout, stdout=subprocess.PIPE)
    p1.stdout.close()
    # capture raw s16le
    raw = p2.communicate()[0]
    pcm = np.frombuffer(raw, dtype=np.int16)
    # write wav
    import soundfile as sf
    sf.write(str(outfile), pcm.astype(np.float32)/32768.0, 48000)

def band_energy(sig: np.ndarray, sr: int, n_fft=1024, hop=480):
    import numpy.fft as fft
    win = np.hanning(n_fft)
    out = []
    for i in range(0, len(sig)-n_fft, hop):
        frame = sig[i:i+n_fft]*win
        spec = np.abs(fft.rfft(frame))
        out.append(spec)
    if not out:
        return np.zeros(1)
    return np.mean(np.stack(out, axis=0), axis=0)

def snr_db(clean_energy, noise_energy):
    return 10.0 * np.log10((clean_energy + 1e-12)/(noise_energy + 1e-12))

def main():
    ap = argparse.ArgumentParser("Evaluate guitar isolation effectiveness")
    ap.add_argument('--input-dir', required=True, help='Directory of test mixtures (or guitar+other audio)')
    ap.add_argument('--demo-exe', default='build/Release/rnnoise_demo.exe', help='Path to rnnoise_demo executable')
    ap.add_argument('--limit', type=int, default=20, help='Max files to evaluate')
    ap.add_argument('--ext', default='.wav', help='Audio extension filter')
    ap.add_argument('--report', default='isolation_report.txt')
    ap.add_argument('--json', default='isolation_report.json', help='Optional JSON structured output')
    ap.add_argument('--hist-bins', type=int, default=20, help='Bins for spectral attenuation histogram')
    args = ap.parse_args()

    in_dir = Path(args.input_dir)
    files = [p for p in in_dir.rglob(f'*{args.ext}') if p.is_file()]
    files = files[:args.limit]
    demo = Path(args.demo_exe)
    if not demo.exists():
        raise SystemExit(f"rnnoise_demo not found: {demo}")
    report_lines = []
    json_rows = []
    for f in files:
        out_wav = f.parent / (f.stem + '_rnnoise.wav')
        run_rnnoise_demo(demo, f, out_wav)
        orig, sr_o = load_wav(f)
        proc, sr_p = load_wav(out_wav)
        if sr_o != sr_p or orig.size == 0 or proc.size == 0:
            continue
        be_o = band_energy(orig, sr_o)
        be_p = band_energy(proc, sr_p)
        freqs = np.linspace(0, sr_o/2, be_o.shape[0])
        mid = (freqs >= 300) & (freqs <= 3500)
        high = (freqs >= 3500) & (freqs <= 8000)
        low = (freqs < 300)
        # Retention ratios (energy after / before)
        mid_ratio = (np.sum(be_p[mid])+1e-9)/(np.sum(be_o[mid])+1e-9)
        high_ratio = (np.sum(be_p[high])+1e-9)/(np.sum(be_o[high])+1e-9)
        low_ratio = (np.sum(be_p[low])+1e-9)/(np.sum(be_o[low])+1e-9)
        overall_rms_ratio = rms(proc) / (rms(orig) + 1e-9)
        # Per-band attenuation (dB)
        att_db = 10.0 * np.log10((be_p+1e-12)/(be_o+1e-12))
        # Suppression score: mean attenuation of top 25% most attenuated bins above 2 kHz
        mask_region = freqs >= 2000
        masked_vals = att_db[mask_region]
        if masked_vals.size:
            sorted_att = np.sort(masked_vals)  # ascending (more negative first)
            k = max(1, int(0.25 * sorted_att.size))
            suppression_score = float(np.mean(sorted_att[:k]))
        else:
            suppression_score = 0.0
        # Histogram of attenuation
        hist_counts, hist_edges = np.histogram(att_db, bins=args.hist_bins, range=(-40, 5))
        line = (f"{f.name}\tRMS_ratio={overall_rms_ratio:.3f}\tlow_retain={low_ratio:.3f}"
                f"\tmid_retain={mid_ratio:.3f}\thigh_retain={high_ratio:.3f}"
                f"\tsuppression_score={suppression_score:.2f}dB")
        print(line)
        report_lines.append(line)
        json_rows.append({
            'file': f.name,
            'rms_ratio': overall_rms_ratio,
            'retain_low': low_ratio,
            'retain_mid': mid_ratio,
            'retain_high': high_ratio,
            'suppression_score_db': suppression_score,
            'hist_counts': hist_counts.tolist(),
            'hist_edges': hist_edges.tolist(),
            'att_db_mean': float(np.mean(att_db)),
            'att_db_median': float(np.median(att_db))
        })
    Path(args.report).write_text('\n'.join(report_lines), encoding='utf-8')
    Path(args.json).write_text(json.dumps(json_rows, indent=2), encoding='utf-8')
    print(f"Reports written: {args.report}, {args.json}")

if __name__ == '__main__':
    main()
