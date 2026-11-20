"""
Reference implementation of the SmartBell motion engine.

This file mirrors SmartBell/Motion/*.swift line for line so the algorithm can be
tested and tuned on a laptop (simulated data or CSV recordings from the ESP32).
If you change a constant or a rule here, change it in the Swift files too.

Input: one row per sample, exactly what the firmware sends:
    ax, ay, az   specific force, m/s^2   (reads about +9.81 "up" when still)
    gx, gy, gz   angular rate, deg/s
    dt_s         seconds since the previous sensor read

Core idea (why this does not drift):
    The old app double-integrated acceleration to get position. Any tiny bias
    grows with t^2, so after a few seconds the position is garbage. This engine
    never integrates acceleration. It tracks one thing: the direction of gravity
    in the sensor frame ("up" vector u). The gyro moves u between samples; the
    accelerometer pulls u back toward the true gravity direction whenever the
    measured acceleration looks like gravity. Tilt relative to gravity is fully
    observable, so its error stays bounded forever instead of growing.

    With the sensor strapped to the forearm, the curl is captured by one number:
    the forearm angle from straight-down, beta = angle(forearm axis, down).
    0 deg = arm hanging, ~140 deg = top of a curl. Because it is an angle to
    gravity, it is the same every rep and cannot drift.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

G0 = 9.80665
DEG = math.pi / 180.0


# ----------------------------------------------------------------------------- vector helpers
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def mul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def norm(a): return math.sqrt(dot(a, a))


def normalized(a):
    n = norm(a)
    return a if n < 1e-12 else mul(a, 1.0 / n)


def rotate(v, rv):
    """Rotate vector v by rotation vector rv (axis * angle, radians). Rodrigues."""
    ang = norm(rv)
    if ang < 1e-12:
        return v
    k = mul(rv, 1.0 / ang)
    c, s = math.cos(ang), math.sin(ang)
    return add(add(mul(v, c), mul(cross(k, v), s)), mul(k, dot(k, v) * (1.0 - c)))


def lpf_alpha(cutoff_hz, dt):
    rc = 1.0 / (2.0 * math.pi * cutoff_hz)
    return dt / (rc + dt)


# ----------------------------------------------------------------------------- parameters
@dataclass
class Params:
    accel_lpf_hz: float = 8.0          # low-pass on accel before it is used as a gravity reference
    gain_motion: float = 1.5           # 1/s, how fast accel corrects u while moving (tau ~0.7 s)
    gain_still: float = 10.0           # 1/s, when still: snap to accel quickly
    trust_sigma: float = 1.0           # m/s^2, accel trusted only when |a| is within ~sigma of g
    still_gyro_dps: float = 6.0        # still if bias-corrected |gyro| below this...
    still_accel_dev: float = 0.35      # ...and accel is not shaking (m/s^2 from its low-pass)
    still_samples: int = 25            # ...for this many consecutive samples (0.25 s)
    bias_alpha: float = 0.02           # per still sample, gyro-bias learning rate
    bias_max_dps: float = 10.0         # never learn a bias bigger than this
    lever_m: float = 0.06              # sensor distance from elbow along forearm (m)
    gap_reset_s: float = 0.15          # a gap this long (BLE drop) re-initialises the filter
    wobble_decay_s: float = 0.5        # between reps the per-rep path integrators decay to 0


# ----------------------------------------------------------------------------- calibration
@dataclass
class Calibration:
    forearm: tuple = (0.0, 0.0, -1.0)  # unit vector, sensor frame, elbow -> hand
    hinge: tuple = (1.0, 0.0, 0.0)     # unit vector, sensor frame, elbow axis (+ = curling up)
    gyro_bias: tuple = (0.0, 0.0, 0.0) # deg/s
    gravity: float = G0                # what this accelerometer reads at rest
    bottom_deg: float = 8.0            # forearm angle at the bottom of a calibration rep
    top_deg: float = 140.0             # forearm angle at the top of a calibration rep
    twist_ref: float = 8.0             # typical wrist rotation (deg) in calibration reps
    sway_ref: float = 4.0              # typical sideways wobble (deg) in calibration reps
    template: list = field(default_factory=list)  # 40-pt time-normalised beta curve

    @property
    def side(self):
        return normalized(cross(self.forearm, self.hinge))

    # thresholds for the rep detector
    @property
    def rom(self): return max(self.top_deg - self.bottom_deg, 40.0)
    @property
    def start_deg(self): return self.bottom_deg + 0.30 * self.rom
    @property
    def top_thresh_deg(self): return self.bottom_deg + 0.70 * self.rom
    @property
    def return_deg(self): return self.bottom_deg + 0.22 * self.rom


# ----------------------------------------------------------------------------- orientation
class GravityTracker:
    """Tracks u = 'up' direction in the sensor frame + gyro bias. Drift-free in tilt."""

    def __init__(self, p: Params, cal: Calibration | None = None):
        self.p = p
        self.u = None
        self.bias = cal.gyro_bias if cal else (0.0, 0.0, 0.0)
        self.g = cal.gravity if cal else G0
        self.lever = mul(cal.forearm, p.lever_m) if cal else None
        self.a_lpf = None
        self.prev_w = None
        self.still_count = 0
        self.is_still = False
        self.w = (0.0, 0.0, 0.0)       # bias-corrected angular rate, rad/s
        self.a_corr = (0.0, 0.0, 0.0)  # filtered accel minus rotation effects
        self.lin_acc = 0.0             # |a_corr - g*u|, m/s^2 (body/elbow acceleration)

    def reset(self):
        self.u = None
        self.a_lpf = None
        self.prev_w = None
        self.still_count = 0

    def update(self, a, gyro_dps, dt):
        p = self.p
        if dt > p.gap_reset_s:
            self.reset()
        dt = min(max(dt, 0.001), 0.05)

        w_raw = mul(gyro_dps, DEG)
        w = sub(w_raw, mul(self.bias, DEG))

        # rotation effects at the sensor (it sits lever_m from the elbow, which is the pivot)
        if self.lever is not None and self.prev_w is not None:
            alpha = mul(sub(w, self.prev_w), 1.0 / dt)
            a_rot = add(cross(w, cross(w, self.lever)), cross(alpha, self.lever))
        else:
            a_rot = (0.0, 0.0, 0.0)
        self.prev_w = w
        a_in = sub(a, a_rot)

        if self.u is None or self.a_lpf is None:
            self.a_lpf = a_in
            self.u = normalized(a_in)
            self.w = w
            self.a_corr = a_in
            return

        k = lpf_alpha(p.accel_lpf_hz, dt)
        self.a_lpf = add(self.a_lpf, mul(sub(a_in, self.a_lpf), k))
        shake = norm(sub(a_in, self.a_lpf))

        # stillness -> learn gyro bias and accelerometer scale
        moving = norm(w) * 180.0 / math.pi > p.still_gyro_dps or shake > p.still_accel_dev \
            or abs(norm(self.a_lpf) - self.g) > 1.5
        self.still_count = 0 if moving else self.still_count + 1
        self.is_still = self.still_count >= p.still_samples
        if self.is_still:
            nb = add(self.bias, mul(sub(gyro_dps, self.bias), p.bias_alpha))
            if norm(nb) < p.bias_max_dps:
                self.bias = nb
            self.g += 0.01 * (norm(self.a_lpf) - self.g)

        # 1) predict: a world-fixed vector seen from a rotating body turns by -w*dt
        self.u = normalized(rotate(self.u, mul(w, -dt)))

        # 2) correct toward measured gravity, weighted by how much it looks like gravity
        mag = norm(self.a_lpf)
        if mag > 1e-6:
            dev = (mag - self.g) / p.trust_sigma
            trust = math.exp(-dev * dev)
            gain = (p.gain_still if self.is_still else p.gain_motion) * trust * dt
            gain = min(max(gain, 0.0), 1.0)
            self.u = normalized(add(self.u, mul(sub(mul(self.a_lpf, 1.0 / mag), self.u), gain)))

        self.w = w
        self.a_corr = self.a_lpf
        self.lin_acc = norm(sub(self.a_lpf, mul(self.u, self.g)))


def forearm_angle_deg(u, forearm):
    """0 = forearm hanging straight down, 90 = horizontal, ~140 = top of curl."""
    c = -dot(forearm, u)
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


# ----------------------------------------------------------------------------- rep detection
@dataclass
class Frame:
    t: float
    beta: float       # forearm angle from straight down, deg (gravity referenced, no drift)
    w_curl: float     # deg/s about the elbow hinge
    twist_deg: float  # wrist rotation since this rep started (short-window gyro integral)
    hand: tuple       # unit forearm vector in the heading-reference frame (fwd, side, up)
    lin_acc: float    # m/s^2, elbow/body acceleration (swinging)


@dataclass
class RepResult:
    index: int
    counted: bool
    start_t: float
    peak_t: float
    end_t: float
    bottom_deg: float
    top_deg: float
    concentric_s: float
    eccentric_s: float
    peak_speed_dps: float
    twist_range: float
    sway_range: float
    swing: float
    path_rms_deg: float
    score: int
    issues: list
    curve: list  # 40-point normalised beta curve


BAND = 5.0  # deg; a phase starts/ends when the angle is within this of its extreme


class RepDetector:
    """Hysteresis state machine on the forearm angle.

    IDLE   -> UP      angle rises past start_deg (30% of calibrated range)
    UP     -> SETTLE  angle falls back below return_deg (22%)  -> rep ends at the bottom
    UP     -> UP      angle fell >= 45% of range then rose 12 deg  -> rep ended at a high
                      bottom (user didn't lower all the way); next rep starts there
    SETTLE -> IDLE    bottom found (angle stops falling)        -> rep analysed
    A rep counts if its peak passed top_thresh_deg (70% of calibrated range).
    """
    IDLE, UP, SETTLE = 0, 1, 2

    def __init__(self, cal: Calibration):
        self.cal = cal
        self.state = self.IDLE
        self.buf: list[Frame] = []
        self.count = 0
        self.attempts = 0
        self.run_min = 1e9
        self.near_min_t = 0.0
        self.start_t = 0.0
        self.peak = -1e9
        self.peak_t = 0.0
        self.valley = 1e9
        self.valley_t = 0.0
        self.counted = False
        self.just_started = False

    def push(self, f: Frame):
        """Returns events: ('counted', n) as soon as a rep is counted, ('result', RepResult) once analysed."""
        cal = self.cal
        self.buf.append(f)
        if len(self.buf) > 2000:  # 20 s at 100 Hz
            del self.buf[:500]
        events = []
        self.just_started = False

        if self.state == self.IDLE:
            if f.beta < self.run_min:
                self.run_min = f.beta
            if f.beta <= self.run_min + 3.0:
                self.near_min_t = f.t
            self.run_min += 0.02  # let the bottom reference float up if the arm is held higher
            if f.beta > cal.start_deg:
                self._begin(self.near_min_t, f)
        elif self.state == self.UP:
            if f.beta > self.peak:
                self.peak, self.peak_t = f.beta, f.t
                self.valley = 1e9
            if self.peak - f.beta > 0.45 * cal.rom and f.beta < self.valley:
                self.valley, self.valley_t = f.beta, f.t
            if f.beta < cal.return_deg:
                self.counted = self.peak >= cal.top_thresh_deg
                self.attempts += 1
                if self.counted:
                    self.count += 1
                    events.append(("counted", self.count))
                self.state = self.SETTLE
                self.valley, self.valley_t = f.beta, f.t
            elif self.valley < 1e8 and f.beta > self.valley + 12.0:
                # turned around before reaching the bottom: close this rep at the valley
                self.counted = self.peak >= cal.top_thresh_deg
                self.attempts += 1
                if self.counted:
                    self.count += 1
                    events.append(("counted", self.count))
                if self.counted:
                    events.append(("result", self._analyse()))
                self._begin(self.valley_t, f)
            elif f.t - self.start_t > 12.0:
                self._to_idle(f)
        elif self.state == self.SETTLE:
            if f.beta < self.valley:
                self.valley, self.valley_t = f.beta, f.t
            if f.beta > self.valley + 4.0 or f.t - self.valley_t > 0.35:
                if self.counted or self.peak >= cal.start_deg + 8.0:
                    events.append(("result", self._analyse()))
                self._to_idle(f)
                self.run_min = self.valley
                self.near_min_t = self.valley_t
        return events

    def _begin(self, start_t, f):
        self.state = self.UP
        self.start_t = start_t
        self.peak, self.peak_t = f.beta, f.t
        self.valley = 1e9
        self.counted = False
        self.just_started = True

    def _to_idle(self, f):
        self.state = self.IDLE
        self.run_min = f.beta
        self.near_min_t = f.t

    def _analyse(self) -> RepResult:
        cal = self.cal
        seg = [fr for fr in self.buf if self.start_t <= fr.t <= self.valley_t]
        if len(seg) < 3:
            seg = self.buf[-3:]
        peak = self.peak
        b0, b1 = seg[0].beta, seg[-1].beta
        ipk = max(range(len(seg)), key=lambda i: seg[i].beta)
        # phase timing between "within BAND of the bottom" and "within BAND of the top"
        t_up0 = next((seg[i].t for i in range(ipk, -1, -1) if seg[i].beta <= b0 + BAND), seg[0].t)
        t_up1 = next((fr.t for fr in seg if fr.beta >= peak - BAND), seg[ipk].t)
        t_dn0 = next((seg[i].t for i in range(len(seg) - 1, -1, -1) if seg[i].beta >= peak - BAND), seg[ipk].t)
        t_dn1 = next((seg[i].t for i in range(ipk, len(seg)) if seg[i].beta <= b1 + BAND), seg[-1].t)
        concentric = max(t_up1 - t_up0, 0.0)
        eccentric = max(t_dn1 - t_dn0, 0.0)
        bottom = b1

        def rms(xs):
            return math.sqrt(sum(x * x for x in xs) / max(len(xs), 1))
        # form metrics only over the moving part (bottom band -> bottom band)
        act = [fr for fr in seg if t_up0 <= fr.t <= t_dn1] or seg
        twist = max(fr.twist_deg for fr in act) - min(fr.twist_deg for fr in act)
        sway = plane_deviation_deg([fr.hand for fr in act])
        swing = max(fr.lin_acc for fr in act)
        peak_speed = max(abs(fr.w_curl) for fr in act)
        curve = resample([fr.t for fr in seg], [fr.beta for fr in seg], 40)
        path_rms = rms([a - b for a, b in zip(curve, cal.template)]) if cal.template else 0.0

        issues = []  # (priority, key, message, penalty)
        if swing > 4.0:
            issues.append((1, "swing", "Don't swing - keep your body still", 30))
        if peak > cal.top_deg + 18.0:
            issues.append((2, "elbow", "Keep your elbow pinned to your side", 20))
        if not self.counted:
            issues.append((3, "partial", "Curl all the way up", 35))
        elif peak < cal.top_deg - 20.0:
            issues.append((3, "short_top", "Curl a little higher", 20))
        if bottom > cal.bottom_deg + 20.0:
            issues.append((4, "short_bottom", "Lower all the way down", 15))
        if eccentric < 0.7:
            issues.append((5, "fast_down", "Lower slower - about 2 seconds", 15))
        if concentric < 0.35:
            issues.append((6, "fast_up", "Lift with control, not momentum", 10))
        if twist > max(30.0, 2.0 * cal.twist_ref + 10.0):
            issues.append((7, "twist", "Keep your wrist from twisting", 10))
        if sway > max(15.0, 2.0 * cal.sway_ref + 8.0):
            issues.append((8, "sway", "Keep the dumbbell in a straight path", 15))
        issues.sort()
        score = max(0, 100 - sum(i[3] for i in issues))
        return RepResult(self.attempts, self.counted, seg[0].t, self.peak_t, seg[-1].t,
                         bottom, peak, concentric, eccentric, peak_speed, twist, sway, swing,
                         path_rms, score, [(i[1], i[2]) for i in issues], curve)


def plane_deviation_deg(hands):
    """A curl moves the hand in a vertical plane. Fit that plane (main horizontal
    direction of the hand path) and return how far, peak to peak, the forearm
    left it, in degrees."""
    sxx = sum(h[0] * h[0] for h in hands)
    syy = sum(h[1] * h[1] for h in hands)
    sxy = sum(h[0] * h[1] for h in hands)
    ang = 0.5 * math.atan2(2.0 * sxy, sxx - syy)
    nx, ny = -math.sin(ang), math.cos(ang)  # normal of the fitted plane
    off = [math.degrees(math.asin(max(-1.0, min(1.0, h[0] * nx + h[1] * ny)))) for h in hands]
    return max(off) - min(off) if off else 0.0


def resample(ts, ys, n):
    if len(ts) < 2:
        return [ys[0] if ys else 0.0] * n
    t0, t1 = ts[0], ts[-1]
    out, j = [], 0
    for i in range(n):
        t = t0 + (t1 - t0) * i / (n - 1)
        while j < len(ts) - 2 and ts[j + 1] < t:
            j += 1
        span = ts[j + 1] - ts[j]
        f = 0.0 if span <= 0 else min(max((t - ts[j]) / span, 0.0), 1.0)
        out.append(ys[j] + (ys[j + 1] - ys[j]) * f)
    return out


# ----------------------------------------------------------------------------- engine
class MotionEngine:
    """Feeds samples through GravityTracker -> forearm angle -> RepDetector.

    The forearm angle (beta) is referenced to gravity, so it never drifts.
    For the 3D path of each rep we also need a heading, which gravity can't give.
    The engine carries a horizontal reference direction that the gyro turns
    (it may slowly wander in heading over minutes; that doesn't matter), and at
    the start of every rep it re-anchors: whatever direction the hand is moving
    becomes "forward" for that rep. Over the ~2-3 s of a rep the heading moves
    well under 1 deg, so the per-rep path is honest, and nothing accumulates
    from rep to rep. ("Reset the position after each rep.")

    Exposes per sample:
      hand        unit forearm vector (forward, side, up) in the current rep's frame
      twist_deg   wrist rotation about the forearm since the rep started
    """

    def __init__(self, cal: Calibration, p: Params | None = None):
        self.p = p or Params()
        self.cal = cal
        self.tracker = GravityTracker(self.p, cal)
        self.detector = RepDetector(cal)
        self.t = 0.0
        self.beta = 0.0
        self.ref = None          # horizontal world reference, sensor frame
        self.heading = 0.0       # rad, rep-frame forward relative to ref
        self.twist_deg = 0.0
        self.hand = (0.0, 0.0, -1.0)
        self.raw_hand = (0.0, 0.0, -1.0)

    def push(self, ax, ay, az, gx, gy, gz, dt):
        self.t += dt
        tr = self.tracker
        tr.update((ax, ay, az), (gx, gy, gz), dt)
        cal = self.cal
        u = tr.u
        self.beta = forearm_angle_deg(u, cal.forearm)
        w = mul(tr.w, 180.0 / math.pi)
        d = min(max(dt, 0.001), 0.05)

        # heading reference: turned by the gyro, kept horizontal
        if self.ref is None:
            r0 = cross(cal.hinge, cal.forearm)
            if norm(sub(r0, mul(u, dot(r0, u)))) < 0.2:
                r0 = cal.hinge
            self.ref = r0
        else:
            self.ref = rotate(self.ref, mul(tr.w, -d))
        self.ref = normalized(sub(self.ref, mul(u, dot(self.ref, u))))
        lat = cross(u, self.ref)
        f = cal.forearm
        rx, ry, rz = dot(f, self.ref), dot(f, lat), dot(f, u)
        self.raw_hand = (rx, ry, rz)
        ch, sh = math.cos(self.heading), math.sin(self.heading)
        self.hand = (rx * ch + ry * sh, -rx * sh + ry * ch, rz)

        if self.detector.state == RepDetector.IDLE:
            self.twist_deg *= math.exp(-d / self.p.wobble_decay_s)
        self.twist_deg += dot(w, cal.forearm) * d

        fr = Frame(self.t, self.beta, dot(w, cal.hinge), self.twist_deg, self.raw_hand, tr.lin_acc)
        events = self.detector.push(fr)
        if self.detector.just_started:
            # re-anchor: the direction the hand is moving now is "forward" for this rep
            self.heading = math.atan2(ry, rx)
            self.twist_deg = 0.0
        return events


# ----------------------------------------------------------------------------- calibration builder
HANG_SECONDS = 2.0


class Calibrator:
    """Step 1: hang arm still 2 s. Step 2: three slow, full curls."""

    def __init__(self, p: Params | None = None):
        self.p = p or Params()
        self.hang_a, self.hang_g = [], []
        self.curl_rows = []
        self.hang_time = 0.0

    def push_hang(self, a, g, dt):
        """Returns progress 0..1 (needs HANG_SECONDS of stillness). Restarts if the arm moves."""
        n = len(self.hang_a)
        mean_norm = sum(norm(x) for x in self.hang_a[-50:]) / min(n, 50) if n else 0.0
        if norm(g) > 15.0 or (n >= 10 and abs(norm(a) - mean_norm) > 1.2):
            self.hang_a, self.hang_g, self.hang_time = [], [], 0.0
            return 0.0
        self.hang_a.append(a)
        self.hang_g.append(g)
        self.hang_time += min(dt, 0.05)
        return min(self.hang_time / HANG_SECONDS, 1.0)

    def finish_hang(self) -> Calibration:
        n = len(self.hang_a)
        mean_a = mul(tuple(map(sum, zip(*self.hang_a))), 1.0 / n)
        mean_g = mul(tuple(map(sum, zip(*self.hang_g))), 1.0 / n)
        cal = Calibration()
        cal.forearm = mul(normalized(mean_a), -1.0)
        cal.gyro_bias = mean_g
        cal.gravity = sum(norm(a) for a in self.hang_a) / n
        cal.hinge = normalized(sub((1.0, 0.0, 0.0), mul(cal.forearm, cal.forearm[0])))
        if norm(cross(cal.forearm, (1.0, 0.0, 0.0))) < 0.3:
            cal.hinge = normalized(sub((0.0, 1.0, 0.0), mul(cal.forearm, cal.forearm[1])))
        return cal

    def push_curl(self, row):
        self.curl_rows.append(row)

    def finish_curls(self, cal: Calibration):
        """Learns hinge axis (PCA of gyro), rep range and template. Returns (cal, reps_found)."""
        p = self.p
        rows = self.curl_rows
        # hinge axis = dominant rotation axis (power iteration on gyro covariance)
        c = [[0.0] * 3 for _ in range(3)]
        for r in rows:
            w = sub(r[3:6], cal.gyro_bias)
            for i in range(3):
                for j in range(3):
                    c[i][j] += w[i] * w[j]
        v = (0.577, 0.577, 0.577)
        for _ in range(50):
            v = normalized((dot(c[0], v), dot(c[1], v), dot(c[2], v)))
        h = normalized(sub(v, mul(cal.forearm, dot(v, cal.forearm))))
        # sign: + hinge rate must mean the angle is increasing
        tr = GravityTracker(p, cal)
        prev_beta, s = None, 0.0
        for r in rows:
            tr.update(r[0:3], r[3:6], r[6])
            beta = forearm_angle_deg(tr.u, cal.forearm)
            if prev_beta is not None:
                s += (beta - prev_beta) * dot(mul(tr.w, 180 / math.pi), h)
            prev_beta = beta
        cal.hinge = h if s >= 0 else mul(h, -1.0)

        # replay with default thresholds to find the reps
        probe = Calibration(**{**cal.__dict__})
        probe.bottom_deg, probe.top_deg, probe.template = 8.0, 120.0, []
        eng = MotionEngine(probe, p)
        results = []
        for r in rows:
            for ev in eng.push(*r):
                if ev[0] == "result" and ev[1].counted:
                    results.append(ev[1])
        if len(results) < 2:
            return cal, len(results)
        med = lambda xs: sorted(xs)[len(xs) // 2]
        cal.bottom_deg = med([r.bottom_deg for r in results])
        cal.top_deg = med([r.top_deg for r in results])
        cal.twist_ref = med([r.twist_range for r in results])
        cal.sway_ref = med([r.sway_range for r in results])
        cal.template = [sum(r.curve[i] for r in results) / len(results) for i in range(40)]
        return cal, len(results)
