//
//  MotionEngine.swift
//  SmartBell — Motion
//
//  The top of the motion pipeline. The rest of the app hands every SensorSample to
//  MotionEngine.push(), and gets back RepEvents. Internally:
//
//    SensorSample → GravityTracker (up vector, stillness, bias)
//                 → β: forearm angle (curls) or ProfileSignal progress % (taught exercises)
//                 → heading-anchored hand direction (for drawing the rep path)
//                 → MotionFrame → RepDetector → RepEvent (.counted / .result)
//
//  Also defines SensorSample, the parsed form of one CSV line from the ESP32.
//

import Foundation

/// One raw row from the ESP32: `ax,ay,az,gx,gy,gz,dt_s`.
struct SensorSample: Equatable {
    var accel: Vec3      // m/s^2
    var gyro: Vec3       // deg/s
    var dt: Double       // seconds since the previous sensor read

    /// Same format the firmware sends; used when saving recordings to CSV.
    var csvLine: String {
        String(format: "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.6f",
               accel.x, accel.y, accel.z, gyro.x, gyro.y, gyro.z, dt)
    }

    /// Parses one firmware line. Returns nil for malformed or physically impossible rows.
    static func parse(_ line: Substring) -> SensorSample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 7 else { return nil }
        var v: [Double] = []
        v.reserveCapacity(7)
        for f in fields {
            guard let d = Double(f.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            v.append(d)
        }
        let a = Vec3(v[0], v[1], v[2]), g = Vec3(v[3], v[4], v[5])
        // Sanity limits: past the BMX160's ±16 g / ±2000 °/s, or a non-positive / >1 s
        // interval, the row is corrupt (e.g. a BLE packet split mid-line).
        guard a.norm < 16 * standardGravity, g.norm < 2500, v[6] > 0, v[6] <= 1 else { return nil }
        return SensorSample(accel: a, gyro: g, dt: v[6])
    }
}

/// Sensor samples in, forearm angle + reps + form out.
///
/// The forearm angle comes from `GravityTracker` and never drifts. For the 3D path of a rep
/// we also need a heading, which gravity can't provide. The engine carries a horizontal
/// reference direction that only the gyro turns (it may slowly wander in heading over
/// minutes, which doesn't matter) and **re-anchors at the start of every rep**: whatever
/// direction the hand is moving becomes "forward" for that rep. A rep lasts 2-3 s, so the
/// heading error inside a rep stays well under a degree, and nothing carries over between reps.
struct MotionEngine {
    let params: MotionParams
    let calibration: Calibration
    /// Set for a taught exercise: `beta` is then "% of the learned range" instead of the forearm angle.
    let profile: MotionProfile?
    private var signal: ProfileSignal?            // converts tracker state → progress % (taught exercises only)
    private(set) var tracker: GravityTracker
    private(set) var detector: RepDetector
    private(set) var t = 0.0                      // seconds since the engine started (sum of sample dt)
    private(set) var beta = 0.0                   // latest forearm angle (deg) or progress (%)
    private(set) var twistDeg = 0.0               // wrist rotation about the forearm since the rep began
    /// Unit forearm vector in the current rep's frame: x forward, y sideways, z up.
    private(set) var hand = Vec3(0, 0, -1)
    private var reference: Vec3? = nil            // horizontal "forward" reference in the sensor frame, turned by the gyro
    private var heading = 0.0                     // rad; offset that makes the current rep's direction "forward"

    init(calibration: Calibration, params: MotionParams = MotionParams(), profile: MotionProfile? = nil) {
        self.params = params
        self.calibration = calibration
        self.profile = profile
        signal = profile.map { ProfileSignal(profile: $0) }
        tracker = GravityTracker(params: params, calibration: calibration)
        // Taught exercises give the detector thresholds in % of range instead of degrees.
        detector = RepDetector(calibration: profile?.detectorCalibration(base: calibration) ?? calibration)
    }

    // Read-only views of internal state for the UI.
    var isInRep: Bool { detector.state != .idle }
    var linearAcceleration: Double { tracker.linearAcceleration }
    var isStill: Bool { tracker.isStill }
    var gyroBias: Vec3 { tracker.bias }

    /// Process one sensor sample. Returns rep events (empty for most samples).
    @discardableResult
    mutating func push(_ s: SensorSample) -> [RepEvent] {
        t += s.dt
        // 1) Sensor fusion: update the gravity direction.
        tracker.update(accel: s.accel, gyroDps: s.gyro, dt: s.dt)
        guard let u = tracker.up else { return [] }
        // 2) The one number the rep detector watches.
        let cal = calibration
        if signal != nil {
            beta = signal!.update(tracker, dt: s.dt)   // % of the learned range
        } else {
            beta = forearmAngleDegrees(up: u, forearm: cal.forearm)
        }
        let w = tracker.rate * degPerRad             // bias-corrected rate, deg/s
        let d = min(max(s.dt, 0.001), 0.05)          // clamped dt, as in GravityTracker

        // 3) Heading reference: turned by the gyro, kept horizontal.
        //    First sample: start with the direction perpendicular to hinge and forearm
        //    (roughly "forward" for a curl), or the hinge itself if that is near-vertical.
        if var r = reference {
            r = r.rotated(by: tracker.rate * (-d))
            reference = r.removingComponent(along: u).normalized
        } else {
            var r0 = cal.hinge.cross(cal.forearm)
            if r0.removingComponent(along: u).norm < 0.2 { r0 = cal.hinge }
            reference = r0.removingComponent(along: u).normalized
        }
        // Build a world-like frame (forward = ref, side = up × ref, up = u) and express the
        // forearm in it. `raw` is before the per-rep heading offset; `hand` is after.
        let ref = reference ?? Vec3(1, 0, 0)
        let lat = u.cross(ref)
        let f = cal.forearm
        let raw = Vec3(f.dot(ref), f.dot(lat), f.dot(u))
        // Rotate about vertical by −heading so this rep's direction lies along +x.
        let ch = cos(heading), sh = sin(heading)
        hand = Vec3(raw.x * ch + raw.y * sh, -raw.x * sh + raw.y * ch, raw.z)

        // 4) Wrist twist = integral of rotation about the forearm axis. It is only needed
        //    within one rep, so between reps it decays to 0 (gyro drift can't build up).
        if detector.state == .idle {
            twistDeg *= exp(-d / params.wobbleDecaySeconds)
        }
        twistDeg += w.dot(cal.forearm) * d

        // 5) Hand everything to the rep detector.
        let frame = MotionFrame(t: t, beta: beta, wCurl: w.dot(cal.hinge), twistDeg: twistDeg,
                                hand: raw, linAcc: tracker.linearAcceleration)
        var events = detector.push(frame)

        // Attach the drawn hand path (in that rep's own frame) before re-anchoring.
        for i in events.indices {
            if case .result(var r) = events[i] {
                r.path = handPath(from: r.startT, to: r.endT, heading: heading)
                events[i] = .result(r)
            }
        }
        if detector.justStarted {
            heading = atan2(raw.y, raw.x)  // re-anchor: current hand direction is "forward"
            twistDeg = 0
        }
        return events
    }

    /// Hand path of the rep in progress (or empty when idle), in the rep's own frame.
    func currentRepPath(maxPoints: Int = 120) -> [Vec3] {
        guard detector.state != .idle else { return [] }
        return handPath(from: detector.startT, to: t, heading: heading, maxPoints: maxPoints)
    }

    /// Hand directions between t0 and t1, rotated into the frame given by `heading`
    /// and thinned to about `maxPoints` points for drawing.
    private func handPath(from t0: Double, to t1: Double, heading: Double, maxPoints: Int = 60) -> [Vec3] {
        let pts = detector.frames.filter { $0.t >= t0 && $0.t <= t1 }
        guard !pts.isEmpty else { return [] }
        let step = max(1, pts.count / maxPoints)  // keep every Nth frame
        let ch = cos(heading), sh = sin(heading)
        var out: [Vec3] = []
        var i = 0
        while i < pts.count {
            let h = pts[i].hand
            out.append(Vec3(h.x * ch + h.y * sh, -h.x * sh + h.y * ch, h.z))
            i += step
        }
        return out
    }
}
