"""
Tests "teach SmartBell an exercise" on simulated non-curl exercises.

Each exercise is a forearm orientation + sensor position over time (sensor strapped on the
forearm near the elbow). The script simulates: hold the start position 1.5 s, 3 teaching reps,
then a set with one partial rep and one fast rep, with gyro bias, noise, accel scale error and
dropped packets. It learns a profile from the teaching part and counts the set.

    python3 tools/simulate_exercises.py [--seeds 10]
"""
from __future__ import annotations

import argparse
import math

import numpy as np
from scipy.spatial.transform import Rotation as R

from smartbell_motion import Calibration, MotionEngine, Params, teach

G = 9.80665
FS = 100.0


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * x * (10 - 15 * x + 6 * x * x)


def rep_progress(reps, hold=1.5, rest_between=0.8):
    """Per-sample progress 0..1 (and labels). reps: list of (out_s, hold_s, back_s, depth)."""
    prog, t = [], 0.0
    prog += [0.0] * int(hold * FS)
    for out_s, top_s, back_s, depth in reps:
        for i in range(int(out_s * FS)):
            prog.append(depth * smooth(i / (out_s * FS)))
        prog += [depth] * int(top_s * FS)
        for i in range(int(back_s * FS)):
            prog.append(depth * (1 - smooth(i / (back_s * FS))))
        prog += [0.0] * int(rest_between * FS)
    return np.array(prog)


# exercise kinematics: progress p -> (rotation forearm->world, sensor position)
# forearm frame: z = elbow->hand. world: X lateral, Y forward, Z up.
DOWN = R.from_matrix(np.array([[1, 0, 0], [0, -1, 0], [0, 0, -1]]).T)   # forearm hanging
UP = R.from_rotvec([math.pi, 0, 0]) * DOWN                               # forearm pointing up


def kin_squat(p):       # dumbbells at sides, body goes down 35 cm, forearm hangs (slight swing)
    return R.from_rotvec([-0.08 * p, 0, 0]) * DOWN, np.array([0, 0.03 * p, -0.35 * p])


def kin_press(p):       # forearm vertical up, pressed 40 cm overhead, slight tilt
    return R.from_rotvec([0.12 * (1 - p), 0, 0]) * UP, np.array([0, 0, 0.40 * p])


def kin_lateral(p):     # straight arm raised sideways to 85 deg about the forward axis
    rot = R.from_rotvec([0, -math.radians(85) * p, 0]) * DOWN
    return rot, rot.apply([0, 0, 0.30]) - DOWN.apply([0, 0, 0.30])


def kin_row(p):         # bent-over row: forearm hangs, elbow pulled up 25 cm
    return R.from_rotvec([0.10 * p, 0, 0]) * DOWN, np.array([0, -0.05 * p, 0.25 * p])


def kin_pushup(p):      # forearm from wrist up, body lowers 25 cm, forearm tilts 25 deg
    return R.from_rotvec([math.radians(25) * p, 0, 0]) * UP, np.array([0, 0.05 * p, -0.25 * p])


EXERCISES = {"squat": kin_squat, "press": kin_press, "lateral raise": kin_lateral,
             "row": kin_row, "push-up": kin_pushup}


def sensor_rows(prog, kin, seed, bias=(2.0, -1.5, 1.0), drop=0.01):
    rng = np.random.default_rng(seed)
    mount = R.from_rotvec(rng.normal(size=3) * 1.2)
    rots, pos = [], []
    for p in prog:
        r, x = kin(p)
        rots.append(r * mount)
        pos.append(x)
    pos = np.array(pos)
    dt = 1 / FS
    acc = np.gradient(np.gradient(pos, dt, axis=0), dt, axis=0)
    b = np.array(bias, float)
    rows, carry = [], 0.0
    for i in range(len(prog) - 1):
        w = (rots[i].inv() * rots[i + 1]).as_rotvec() / dt * 180 / math.pi
        f = rots[i].inv().apply(acc[i] + [0, 0, G]) * 1.03
        b += rng.normal(scale=0.02, size=3)
        row = [*(f + rng.normal(scale=0.1, size=3)), *(w + b + rng.normal(scale=0.6, size=3)),
               dt + rng.normal(scale=0.0006)]
        if rng.random() < drop:
            carry += row[6]
            continue
        row[6] += carry
        carry = 0.0
        rows.append(row)
    return rows


def run(name, seed, verbose=False):
    kin = EXERCISES[name]
    teach_reps = [(1.2, 0.3, 1.4, 1.0)] * 3
    set_reps = [(1.0, 0.2, 1.5, 1.0), (1.1, 0.2, 1.6, 1.0), (0.9, 0.1, 1.2, 0.5),   # 3rd: partial
                (1.0, 0.2, 1.5, 1.0), (0.7, 0.0, 0.6, 1.0), (1.2, 0.3, 1.8, 1.0),   # 5th: fast
                (1.0, 0.2, 1.5, 0.95), (1.0, 0.2, 1.5, 1.0)]
    teach_prog = rep_progress(teach_reps)
    set_prog = rep_progress(set_reps, hold=8.0)  # 8 s rest before the set
    rows = sensor_rows(np.concatenate([teach_prog, set_prog]), kin, seed)
    n_teach = len(teach_prog) - 5

    base = Calibration()
    profile, info = teach(rows[:n_teach], base, exercise=name)
    if profile is None:
        if verbose:
            print(f"{name:14s} seed {seed}: TEACH FAILED {info}")
        return False, info
    eng = MotionEngine(base, Params(), profile)
    results = []
    rows = rows + [list(rows[-1][:6]) + [0.01]] * 100
    for r in rows:   # run the whole stream so the filter is warm, count only the set
        for ev in eng.push(*r):
            if ev[0] == "result":
                results.append(ev[1])
    teach_t = sum(r[6] for r in rows[:n_teach])
    set_res = [r for r in results if r.peak_t > teach_t]
    counted = sum(r.counted for r in set_res)
    partials = [r for r in set_res if not r.counted]
    fast_flag = any(k in ("fast_down", "fast_up") for k, _ in set_res[4].issues) if len(set_res) > 4 else False
    ok = counted == 7
    if verbose:
        print(f"{name:14s} seed {seed}: channel={profile.channel:11s} "
              f"{'rom=%.0f deg' % profile.rom_deg if profile.channel == 'orientation' else 'amp=%.2f m' % profile.amplitude:12s} "
              f"counted {counted}/7, partials {len(partials)}/1, fast cue {fast_flag}  tried={info['tried']}")
    return ok, info


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=1)
    a = ap.parse_args()
    for name in EXERCISES:
        oks = [run(name, s, verbose=(a.seeds == 1))[0] for s in range(1, a.seeds + 1)]
        if a.seeds > 1:
            print(f"{name:14s} {sum(oks)}/{len(oks)} sets with all 7 full reps counted exactly")
