"""Designs Flatroom room-correction FIR filters from a measurement of your speakers.

Input, either:
  --measurement L.txt R.txt   frequency response at the listening position, one file per speaker,
                              as exported by REW (File > Export > Measurement as text) or any
                              "frequency dB" text/CSV. The correction is its inverse, normalised so
                              200 Hz-2 kHz sits at 0 dB.
  --correction L.csv R.csv    a ready-made correction curve per speaker (same formats), in dB.
Output: <out>/<name>/fir_<sr>.wav (float32, 2 channels: L, R) for every sample rate, meta.json and
        response.png. <out> defaults to Flatroom's filter folder, so the filter shows up in the app.

Usage:
  uv run python design_fir.py --measurement left.txt right.txt --name my-room
  uv run python design_fir.py --measurement left.txt right.txt --phase linear --max-cut 9 \\
      --bass-db 3 --hf-from 500 --hf-amount 0.5 --boost-min-hz 30 --name my-room-linear
"""

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.io import wavfile
from scipy.signal import windows

DEFAULT_OUT = Path.home() / "Library/Application Support/Flatroom/Filters"
SAMPLE_RATES = [44100, 48000, 88200, 96000, 176400, 192000]
FIR_SECONDS = 16384 / 48000  # ~341 ms (minimum phase); linear phase uses twice that, centred
FFT_SIZE = 1 << 19  # dense design grid (avoids time aliasing)
LOG_GRID = np.geomspace(5, 100000, 4000)  # working grid for smoothing in log-f


def read_curve(path):
    """Frequency (Hz) and level (dB) from the first two numeric columns; other lines are skipped."""
    freqs, dbs = [], []
    for line in Path(path).read_text(errors="replace").splitlines():
        cols = line.replace(",", " ").replace(";", " ").replace("\t", " ").split()
        try:
            f, db = float(cols[0]), float(cols[1])
        except (IndexError, ValueError):
            continue
        if f > 0:
            freqs.append(f)
            dbs.append(db)
    if len(freqs) < 10:
        raise SystemExit(f"{path}: no frequency/dB data found")
    order = np.argsort(freqs)
    return np.array(freqs)[order], np.array(dbs)[order]


def interp_log(freqs, curve_f, curve_db):
    """Interpolates in log-f; outside the measured range holds the edge value."""
    return np.interp(np.log10(np.clip(freqs, curve_f[0], curve_f[-1])), np.log10(curve_f), curve_db)


def octave_smooth(db, fraction):
    """Moving average 1/`fraction` octave wide over LOG_GRID."""
    per_octave = len(LOG_GRID) / np.log2(LOG_GRID[-1] / LOG_GRID[0])
    width = max(1, int(round(per_octave / fraction)))
    padded = np.pad(db, width, mode="edge")
    return np.convolve(padded, np.ones(width) / width, mode="same")[width:-width]


def correction_curve(curve_f, curve_db, args):
    """Final correction (without the common gain) over LOG_GRID."""
    corr = interp_log(LOG_GRID, curve_f, curve_db)
    if args.hf_from > 0:
        # Above `hf_from`: correct only the trend (1/3 oct), scaled by the requested amount.
        smooth = octave_smooth(corr, 3) * args.hf_amount
        w = np.clip(np.log2(LOG_GRID / (args.hf_from / 1.5)) / np.log2(1.5 * 1.5), 0, 1)
        corr = (1 - w) * corr + w * smooth
    # Target curve with extra bass: gentle shelf centred on `bass_hz`.
    corr = corr + args.bass_db / (1 + (LOG_GRID / args.bass_hz) ** 2)
    inside = (LOG_GRID >= args.boost_min_hz) & (LOG_GRID <= args.boost_max_hz)
    corr = np.minimum(corr, np.where(inside, args.max_boost, 0.0))
    return np.maximum(corr, -args.max_cut)


def on_grid(freqs, corr):
    return np.interp(np.log10(np.maximum(freqs, LOG_GRID[0])), np.log10(LOG_GRID), corr)


def minimum_phase_fir(mag_db, length):
    """Minimum-phase FIR with magnitude `mag_db` (rfft grid of FFT_SIZE), by the cepstral method."""
    log_mag = np.log(10.0 ** (mag_db / 20.0))
    cep = np.fft.irfft(log_mag, FFT_SIZE)
    fold = np.zeros(FFT_SIZE)
    fold[0] = cep[0]
    fold[1 : FFT_SIZE // 2] = 2 * cep[1 : FFT_SIZE // 2]
    fold[FFT_SIZE // 2] = cep[FFT_SIZE // 2]
    h = np.fft.irfft(np.exp(np.fft.rfft(fold)), FFT_SIZE)[:length]
    fade = length // 4
    h[-fade:] *= 0.5 * (1 + np.cos(np.linspace(0, np.pi, fade)))
    return h


def linear_phase_fir(mag_db, length):
    """Linear-phase (symmetric) FIR: `length // 2` samples of delay, no phase distortion."""
    h = np.fft.irfft(10.0 ** (mag_db / 20.0), FFT_SIZE)
    h = np.roll(h, length // 2)[:length]
    return h * windows.tukey(length, 0.5)


def response_db(h, sr, freqs):
    w = np.exp(-2j * np.pi * np.outer(freqs / sr, np.arange(len(h))))
    return 20 * np.log10(np.abs(w @ h) + 1e-12)


def main():
    ap = argparse.ArgumentParser()
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--measurement", nargs=2, metavar=("LEFT", "RIGHT"), help="measured response per speaker")
    source.add_argument("--correction", nargs=2, metavar=("LEFT", "RIGHT"), help="correction curve per speaker")
    ap.add_argument("--smoothing", type=float, default=6.0, help="measurement smoothing, 1/N octave")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="folder for the filter")
    ap.add_argument("--phase", choices=["minimum", "linear"], default="minimum")
    ap.add_argument("--max-boost", type=float, default=6.0, help="maximum boost in dB")
    ap.add_argument("--max-cut", type=float, default=np.inf, help="maximum cut in dB")
    ap.add_argument("--bass-db", type=float, default=0.0, help="target: extra bass in dB")
    ap.add_argument("--bass-hz", type=float, default=120.0, help="target: bass shelf frequency")
    ap.add_argument("--hf-from", type=float, default=0.0, help="smoothed correction from here up (0 = off)")
    ap.add_argument("--hf-amount", type=float, default=1.0, help="share of the correction above --hf-from")
    ap.add_argument("--margin", type=float, default=0.5, help="extra anti-clipping headroom in dB")
    ap.add_argument("--boost-min-hz", type=float, default=25.0, help="no boost below")
    ap.add_argument("--boost-max-hz", type=float, default=20000.0, help="no boost above")
    ap.add_argument("--name", required=True, help="filter name shown in Flatroom")
    args = ap.parse_args()

    out_dir = args.out / args.name
    out_dir.mkdir(parents=True, exist_ok=True)
    check_f = np.geomspace(15, 22000, 600)
    measured, corrections = {}, {}
    for name, path in zip("LR", args.measurement or args.correction):
        curve_f, curve_db = read_curve(path)
        if args.measurement:
            level = interp_log(LOG_GRID, curve_f, curve_db)
            level = octave_smooth(level, args.smoothing)
            band = (LOG_GRID >= 200) & (LOG_GRID <= 2000)
            level -= level[band].mean()
            curve_f, curve_db = LOG_GRID, -level
        corrections[name] = correction_curve(curve_f, curve_db, args)
        measured[name] = on_grid(check_f, -interp_log(LOG_GRID, curve_f, curve_db))
    audible = (LOG_GRID >= 20) & (LOG_GRID <= 20000)

    # Common gain so that no channel exceeds 0 dB at any frequency.
    gain_db = -(max(c[audible].max() for c in corrections.values()) + args.margin)

    # Bypass gain for matched loudness: the filter's mean power on pink noise (equal energy
    # per octave) between 40 Hz and 16 kHz, averaged over L and R.
    pink_f = np.geomspace(40, 16000, 400)
    bypass_db = 10 * np.log10(np.mean([10 ** ((on_grid(pink_f, c) + gain_db) / 10) for c in corrections.values()]))

    linear = args.phase == "linear"
    meta = {"type": "linear phase" if linear else "minimum phase", "max_boost_db": args.max_boost,
            "max_cut_db": None if np.isinf(args.max_cut) else args.max_cut,
            "bass_db": args.bass_db, "bass_hz": args.bass_hz,
            "hf_from_hz": args.hf_from, "hf_amount": args.hf_amount,
            "boost_band_hz": [args.boost_min_hz, args.boost_max_hz],
            "gain_db": round(gain_db, 2), "bypass_gain_db": round(float(bypass_db), 2),
            "source": " + ".join(Path(p).name for p in (args.measurement or args.correction)), "files": {}}
    report = []

    for sr in SAMPLE_RATES:
        length = int(round(FIR_SECONDS * sr)) * (2 if linear else 1)
        grid = np.fft.rfftfreq(FFT_SIZE, 1 / sr)
        firs = []
        for name, corr in corrections.items():
            mag = on_grid(grid, corr) + gain_db
            h = linear_phase_fir(mag, length) if linear else minimum_phase_fir(mag, length)
            firs.append(h)
            if sr == 48000:
                report.append((name, on_grid(check_f, corr) + gain_db, response_db(h, sr, check_f)))
        path = out_dir / f"fir_{sr}.wav"
        wavfile.write(path, sr, np.stack(firs, axis=1).astype(np.float32))
        meta["files"][str(sr)] = {"file": path.name, "taps": length,
                                  "latency_samples": length // 2 if linear else 0}

    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")

    fig, axes = plt.subplots(2, 1, figsize=(11, 8), sharex=True)
    for name, want, got in report:
        err = np.abs(want - got)[(check_f >= 30) & (check_f < 20000)]
        print(f"{name}: FIR vs target error (30 Hz-20 kHz) max {err.max():.2f} dB, mean {err.mean():.3f} dB")
        axes[0].semilogx(check_f, want, "--", label=f"{name} requested")
        axes[0].semilogx(check_f, got, label=f"{name} FIR 48 kHz")
        axes[1].semilogx(check_f, measured[name], ":", label=f"{name} measured")
        axes[1].semilogx(check_f, measured[name] + got, label=f"{name} corrected (predicted)")
    target = args.bass_db / (1 + (check_f / args.bass_hz) ** 2) + gain_db
    axes[1].semilogx(check_f, target, "k--", lw=1, label="target")
    axes[0].set_title(f"Filter ({meta['type']}, max boost {args.max_boost:+.0f} dB, "
                      f"max cut {args.max_cut:.0f} dB, gain {gain_db:+.1f} dB)")
    axes[1].set_title("Response at the listening position: measured vs. predicted with the filter")
    for ax in axes:
        ax.set_ylabel("dB")
        ax.grid(True, which="both", alpha=0.3)
        ax.legend(fontsize=8)
    axes[1].set_xlabel("Hz")
    axes[1].set_xlim(20, 22000)
    plot = out_dir / "response.png"
    fig.tight_layout()
    fig.savefig(plot, dpi=110)
    print(f"gain {gain_db:+.2f} dB, matched bypass {bypass_db:+.2f} dB -> {out_dir}")


if __name__ == "__main__":
    main()
