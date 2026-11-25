"""
Replay a CSV recorded by the app (Device > Recordings > share) or captured from the
ESP32 serial monitor, through the reference engine. Use it to tune thresholds on real data.

    python3 tools/replay_csv.py smartbell-20261120-101500.csv [--plot out.png]

If the file has no "# calibration:" line (e.g. a serial-monitor capture), the script
calibrates itself: the first 2 s of stillness are used as the arm-hanging step, and the
next three curls as the calibration curls. So start such a capture with the arm hanging
still, then do 3 slow curls, then the set.
"""
from __future__ import annotations

import argparse
import json
import sys

from smartbell_motion import Calibration, Calibrator, MotionEngine, Params


# Read a recording: optional '# calibration: {json}' line plus ax..dt_s rows.
# Returns (Calibration or None, list of rows).
def load(path):
    cal, rows = None, []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("# calibration:"):
                d = json.loads(line[len("# calibration:"):])
                v = lambda k: (d[k]["x"], d[k]["y"], d[k]["z"])
                cal = Calibration(forearm=v("forearm"), hinge=v("hinge"), gyro_bias=v("gyroBias"),
                                  gravity=d["gravity"], bottom_deg=d["bottomDeg"], top_deg=d["topDeg"],
                                  twist_ref=d["twistRef"], sway_ref=d["swayRef"], template=d["template"])
                continue
            if not line or line.startswith("#") or line.startswith("ax"):
                continue
            parts = line.split(",")
            if len(parts) != 7:
                continue
            try:
                r = [float(x) for x in parts]
            except ValueError:
                continue
            if 0 < r[6] <= 1:
                rows.append(r)
    return cal, rows


# For files without a calibration line: find the first 2 s still, then use the
# following curls as calibration (see the module docstring).
def auto_calibrate(rows):
    c = Calibrator()
    k = 0
    while k < len(rows) and c.push_hang(rows[k][0:3], rows[k][3:6], rows[k][6]) < 1.0:
        k += 1
    if k >= len(rows):
        sys.exit("no 2 s still period found for calibration")
    cal = c.finish_hang()
    probe = MotionEngine(Calibration(**{**cal.__dict__, "bottom_deg": 8.0, "top_deg": 120.0, "template": []}))
    seen, end = 0, k
    for j in range(k, len(rows)):
        c.push_curl(rows[j])
        for ev in probe.push(*rows[j]):
            if ev[0] == "result" and ev[1].counted:
                seen += 1
        if seen >= 3 and probe.detector.state == probe.detector.IDLE:
            end = j + 1
            break
    cal, found = c.finish_curls(cal)
    print(f"auto-calibrated from samples {k}-{end}: {found} curls, range {cal.bottom_deg:.0f}-{cal.top_deg:.0f} deg")
    return cal, end


# Parse args, calibrate (from the file or automatically), replay, print each rep,
# optionally plot the forearm angle.
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--plot")
    a = ap.parse_args()
    cal, rows = load(a.csv)
    start = 0
    if cal is None:
        cal, start = auto_calibrate(rows)
    eng = MotionEngine(cal, Params())
    ts, betas, results = [], [], []
    for r in rows[start:]:
        for ev in eng.push(*r):
            if ev[0] == "result":
                results.append(ev[1])
        ts.append(eng.t)
        betas.append(eng.beta)
    dur = ts[-1] if ts else 0
    print(f"{len(rows) - start} samples, {dur:.1f} s, {(len(rows) - start) / max(dur, 1e-9):.0f} Hz average")
    print(f"reps counted: {eng.detector.count}   partials: {sum(1 for r in results if not r.counted)}")
    for r in results:
        iss = ", ".join(k for k, _ in r.issues) or "good"
        print(f"  {r.start_t:7.2f}s {'rep' if r.counted else 'partial':7s} {r.bottom_deg:5.1f}->{r.top_deg:5.1f} deg  "
              f"lift {r.concentric_s:.2f}s lower {r.eccentric_s:.2f}s  twist {r.twist_range:4.1f} sway {r.sway_range:4.1f} "
              f"swing {r.swing:3.1f}  score {r.score:3d}  [{iss}]")
    if a.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(12, 4))
        ax.plot(ts, betas, lw=1)
        for r in results:
            ax.axvspan(r.start_t, r.end_t, color="#2e7d32" if r.counted else "#f9a825", alpha=.15)
        for y, lab in [(cal.start_deg, "start"), (cal.top_thresh_deg, "count"), (cal.return_deg, "return")]:
            ax.axhline(y, ls=":", lw=.8, color="#666")
            ax.text(ts[0] if ts else 0, y, lab, fontsize=7, va="bottom")
        ax.set_ylabel("forearm angle (deg)"); ax.set_xlabel("s")
        fig.tight_layout(); fig.savefig(a.plot, dpi=110)
        print("plot:", a.plot)


if __name__ == "__main__":
    main()
