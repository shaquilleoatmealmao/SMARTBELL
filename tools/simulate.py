"""
Physics-based simulator for a forearm-mounted IMU doing dumbbell curls.

Produces the same CSV rows the ESP32 sends (ax,ay,az,gx,gy,gz,dt_s) including
the things that broke the old app: gyro bias + bias random walk, sensor noise,
accelerometer scale error, timing jitter, dropped BLE samples, an arbitrary
mounting rotation, body swing, wrist twist and sideways wobble.

Usage:  python3 tools/simulate.py out.csv   (writes CSV + prints ground truth)
"""
from __future__ import annotations

import math
import sys
from dataclasses import dataclass

import numpy as np
from scipy.spatial.transform import Rotation as R

# Swift counterpart: SmartBell/Sensor/DemoSensor.swift uses the same model.
G = 9.80665


@dataclass
class Rep:
    con: float = 1.2       # seconds up
    hold: float = 0.3      # at the top
    ecc: float = 2.0       # seconds down
    rest: float = 0.6      # at the bottom
    top: float = 140.0     # deg
    bottom: float = 6.0    # deg
    swing: float = 0.0     # m, elbow pushed forward by a body swing during the lift
    twist: float = 0.0     # deg, wrist rotation amplitude
    sway: float = 0.0      # deg, sideways wobble amplitude
    label: str = "good"
    counts: bool = True


def smooth(x):  # minimum-jerk 0..1
    x = min(max(x, 0.0), 1.0)
    return x * x * x * (10 - 15 * x + 6 * x * x)


# Turns a list of hold / rep segments into per-sample ground truth (forearm angle, twist,
# sway, elbow swing) at fs Hz.
def build_timeline(segments, fs=100.0):
    """segments: list of ('hold', seconds, beta) or ('rep', Rep). Returns arrays."""
    t, beta, twist, sway, elbow = [], [], [], [], []
    truth = []
    clock = 0.0
    cur = 6.0
    for seg in segments:
        if seg[0] == "hold":
            n = int(seg[1] * fs)
            for _ in range(n):
                t.append(clock); beta.append(seg[2]); twist.append(0); sway.append(0); elbow.append(0)
                clock += 1 / fs
            cur = seg[2]
            continue
        rep: Rep = seg[1]
        total = rep.con + rep.hold + rep.ecc + rep.rest
        n = int(total * fs)
        start = clock
        for i in range(n):
            s = i / fs
            if s < rep.con:
                b = cur + (rep.top - cur) * smooth(s / rep.con)
                ph = s / rep.con
            elif s < rep.con + rep.hold:
                b = rep.top; ph = 1.0
            elif s < rep.con + rep.hold + rep.ecc:
                b = rep.top + (rep.bottom - rep.top) * smooth((s - rep.con - rep.hold) / rep.ecc)
                ph = 1.0 - (s - rep.con - rep.hold) / rep.ecc
            else:
                b = rep.bottom; ph = 0.0
            active = s < rep.con + rep.hold + rep.ecc
            env = math.sin(math.pi * min(s / (rep.con + rep.hold + rep.ecc), 1.0)) if active else 0.0
            t.append(clock); beta.append(b)
            twist.append(rep.twist * env * math.sin(2 * math.pi * 1.5 * s))
            sway.append(rep.sway * env * math.sin(2 * math.pi * 1.0 * s))
            # body swing: elbow pushed forward then back during the concentric phase
            elbow.append(rep.swing * (0.5 - 0.5 * math.cos(2 * math.pi * s / rep.con)) if s < rep.con else 0.0)
            clock += 1 / fs
        cur = rep.bottom
        truth.append((start, rep.label, rep.counts))
    return np.array(t), np.array(beta), np.array(twist), np.array(sway), np.array(elbow), truth


def simulate(segments, seed=1, mount=None, lever=0.06, bias_dps=(2.5, -1.8, 1.2),
             gyro_noise=0.6, acc_noise=0.10, acc_scale=1.03, drop_rate=0.004, fs=100.0):
    rng = np.random.default_rng(seed)
    t, beta, twist, sway, elbow, truth = build_timeline(segments, fs)
    n = len(t)
    # forearm frame F: x = hinge (lateral), z = toward hand. At beta=0 the forearm points down.
    # world: X lateral, Y forward, Z up. Curl rotates forearm about +X so the hand comes forward/up.
    base = R.from_matrix(np.array([[1, 0, 0], [0, -1, 0], [0, 0, -1]]).T)  # F->world at rest: z_F -> -Z
    rots = []
    for i in range(n):
        r = R.from_rotvec([0, sway[i] * math.pi / 180, 0]) * R.from_rotvec([-beta[i] * math.pi / 180, 0, 0]) \
            * base * R.from_rotvec([0, 0, twist[i] * math.pi / 180])
        rots.append(r)
    if mount is None:
        mount = R.from_rotvec(rng.normal(size=3) * 1.2)
    rws = [r * mount for r in rots]  # sensor -> world

    # sensor position in world: elbow (moves with swing) + lever along forearm
    pos = np.zeros((n, 3))
    for i in range(n):
        pos[i] = np.array([0, elbow[i], 0]) + rots[i].apply([0, 0, lever])
    dt = 1 / fs
    vel = np.gradient(pos, dt, axis=0)
    acc = np.gradient(vel, dt, axis=0)

    rows = []
    bias = np.array(bias_dps, dtype=float)
    true_beta = []
    for i in range(n - 1):
        rel = rws[i].inv() * rws[i + 1]
        w_body = rel.as_rotvec() / dt * 180 / math.pi
        f_world = acc[i] + np.array([0, 0, G])
        a_body = rws[i].inv().apply(f_world) * acc_scale
        bias += rng.normal(scale=0.02, size=3)  # slow bias random walk
        g = w_body + bias + rng.normal(scale=gyro_noise, size=3)
        a = a_body + rng.normal(scale=acc_noise, size=3)
        jitter = dt + rng.normal(scale=0.0006)
        rows.append([*a, *g, jitter])
        fw = rots[i].apply([0, 0, 1])
        true_beta.append(math.degrees(math.acos(np.clip(-fw[2], -1, 1))))
    # dropped BLE packets: merge dt into the next row
    out, tb = [], []
    carry = 0.0
    for r, b in zip(rows, true_beta):
        if rng.random() < drop_rate:
            carry += r[6]
            continue
        r = list(r); r[6] += carry; carry = 0.0
        out.append(r); tb.append(b)
    return out, tb, truth, mount


# The calibration script: still hang, then 3 slow full curls.
def calibration_segments():
    return [("hold", 3.0, 0.0)] + [("rep", Rep(con=1.6, hold=0.4, ecc=2.2, rest=1.0, top=138))] * 3 + [("hold", 1.0, 6.0)]


# A scripted set with good reps and one example of each form fault.
def workout_segments():
    reps = [
        Rep(),
        Rep(con=1.0, ecc=2.2, top=142),
        Rep(con=0.9, ecc=0.5, label="fast_down"),
        Rep(top=90, label="partial", counts=False),
        Rep(con=0.6, ecc=2.0, swing=0.12, top=150, label="swing"),
        Rep(twist=35, label="twist"),
        Rep(sway=14, label="sway"),
        Rep(con=0.5, hold=0.0, ecc=0.6, rest=0.1, label="very_fast"),
        Rep(con=0.5, hold=0.0, ecc=0.6, rest=0.1, label="very_fast"),
        Rep(con=2.5, hold=1.0, ecc=3.5, rest=1.5, label="slow"),
        Rep(top=165, label="elbow_forward"),
        Rep(bottom=40, label="short_bottom"),
        Rep(),
    ]
    return [("hold", 2.0, 6.0)] + [("rep", r) for r in reps] + [("hold", 20.0, 6.0)] + \
        [("rep", Rep()) for _ in range(5)] + [("hold", 2.0, 6.0)]


if __name__ == "__main__":
    rows, _, truth, _ = simulate(calibration_segments() + workout_segments())
    path = sys.argv[1] if len(sys.argv) > 1 else "simulated.csv"
    with open(path, "w") as fh:
        fh.write("ax,ay,az,gx,gy,gz,dt_s\n")
        for r in rows:
            fh.write(",".join(f"{v:.3f}" for v in r[:6]) + f",{r[6]:.6f}\n")
    print(f"wrote {len(rows)} rows to {path}")
    for start, label, counts in truth:
        print(f"{start:7.2f}s  {label:14s} {'counts' if counts else 'no count'}")
