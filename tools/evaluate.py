"""
Runs the reference engine on simulated sessions and reports rep-count accuracy,
angle error vs ground truth, and form-cue hits.  Optional: --plot out.png

Usage:  python3 tools/evaluate.py [--seeds 20] [--plot angle.png]
"""
from __future__ import annotations

import argparse
import math

import numpy as np

import simulate as sim
from smartbell_motion import Calibrator, MotionEngine, Params

CAL_HANG_ROWS = (30, 280)


def run(seed, plot=None, verbose=False):
    cal_segs = sim.calibration_segments()
    rows, true_beta, truth, _ = sim.simulate(cal_segs + sim.workout_segments(), seed=seed)

    c = Calibrator()
    k = CAL_HANG_ROWS[0]
    while c.push_hang(rows[k][0:3], rows[k][3:6], rows[k][6]) < 1.0:
        k += 1
    cal = c.finish_hang()
    t_cal = (3.0 + 3 * (1.6 + 0.4 + 2.2 + 1.0) + 0.9)
    cal_len, acc = 0, 0.0
    while acc < t_cal:
        acc += rows[cal_len][6]; cal_len += 1
    for r in rows[k:cal_len]:
        c.push_curl(r)
    cal, found = c.finish_curls(cal)

    eng = MotionEngine(cal, Params())
    est, results, naive = [], [], []
    naive_angle = 0.0
    for r in rows[cal_len:]:
        for ev in eng.push(*r):
            if ev[0] == "result":
                results.append(ev[1])
        est.append(eng.beta)
        # naive: integrate the hinge-axis gyro without any correction (what drifts)
        naive_angle += np.dot(np.array(r[3:6]), np.array(cal.hinge)) * r[6]
        naive.append(naive_angle)
    tb = np.array(true_beta[cal_len:])
    est = np.array(est)
    err = est - tb
    skip = 50
    rmse = float(np.sqrt(np.mean(err[skip:] ** 2)))
    maxe = float(np.max(np.abs(err[skip:])))
    late = float(np.mean(np.abs(err[-300:])))
    naive = np.array(naive) + tb[0]

    expected_workout = [t for t in truth[3:]]
    want = sum(1 for _, _, counts in expected_workout if counts)
    got = eng.detector.count

    if verbose:
        print(f"seed {seed}: calibration reps={found} bottom={cal.bottom_deg:.1f} top={cal.top_deg:.1f} "
              f"twist_ref={cal.twist_ref:.1f} sway_ref={cal.sway_ref:.1f} g={cal.gravity:.2f}")
        print(f"  angle RMSE {rmse:.2f} deg, max {maxe:.2f}, mean |err| last 3 s {late:.2f}; "
              f"naive gyro drift at end {naive[-1]-tb[-1]:+.1f} deg")
        print(f"  reps counted {got} / expected {want}")
        labels = [lab for _, lab, _ in expected_workout]
        for res, lab in zip(results, labels):
            iss = ", ".join(k for k, _ in res.issues) or "-"
            print(f"   #{res.index:2d} {lab:14s} counted={str(res.counted):5s} top={res.top_deg:5.1f} "
                  f"bot={res.bottom_deg:5.1f} con={res.concentric_s:.2f} ecc={res.eccentric_s:.2f} "
                  f"tw={res.twist_range:4.1f} sw={res.sway_range:4.1f} swing={res.swing:.1f} "
                  f"path={res.path_rms_deg:4.1f} score={res.score:3d}  [{iss}]")
        if len(results) != len(labels):
            print(f"  !! {len(results)} analysed reps vs {len(labels)} performed")

    if plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        t = np.cumsum([r[6] for r in rows[cal_len:]])
        fig, ax = plt.subplots(2, 1, figsize=(12, 6), sharex=True)
        ax[0].plot(t, tb, label="true forearm angle", lw=2, color="#999")
        ax[0].plot(t, est, label="SmartBell estimate", lw=1, color="#1565c0")
        ax[0].plot(t, naive, label="raw gyro integration (old approach)", lw=1, color="#c62828", alpha=.7)
        for res in results:
            ax[0].axvspan(res.start_t - eng.t + t[-1], res.end_t - eng.t + t[-1],
                          color="#2e7d32" if res.counted else "#f9a825", alpha=.12)
        ax[0].set_ylabel("deg"); ax[0].legend(loc="upper right", fontsize=8)
        ax[0].set_title("Forearm angle: fused estimate vs truth (green = counted rep, yellow = partial)")
        ax[1].plot(t, err, color="#1565c0", lw=1)
        ax[1].set_ylabel("estimate error, deg"); ax[1].set_xlabel("s")
        ax[1].axhline(0, color="#999", lw=.5)
        fig.tight_layout(); fig.savefig(plot, dpi=110)
    return got, want, rmse, maxe, results, expected_workout


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--plot")
    a = ap.parse_args()
    ok = 0
    rm = []
    cue_hits = {}
    for s in range(1, a.seeds + 1):
        got, want, rmse, maxe, results, exp = run(s, plot=a.plot if s == 1 else None, verbose=(a.seeds == 1))
        ok += got == want
        rm.append(rmse)
        for res, (_, lab, _) in zip(results, exp):
            keys = [k for k, _ in res.issues]
            hit = (lab in ("good", "slow") and not keys) or (lab == "partial" and "partial" in keys) or \
                  (lab == "very_fast" and ("fast_down" in keys or "fast_up" in keys)) or \
                  (lab == "elbow_forward" and "elbow" in keys) or (lab in keys)
            d = cue_hits.setdefault(lab, [0, 0]); d[0] += hit; d[1] += 1
    if a.seeds > 1:
        print(f"{ok}/{a.seeds} sessions with exact rep count; angle RMSE mean {np.mean(rm):.2f} deg (worst {max(rm):.2f})")
        for lab, (h, n) in cue_hits.items():
            print(f"  {lab:14s} expected cue/no-cue {h}/{n}")
