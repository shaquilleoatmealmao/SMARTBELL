//
//  ExerciseProfile.swift
//  SmartBell — Motion
//
//  Lets SmartBell count exercises other than curls. Contents:
//    • MotionProfile    – what was learned about one taught exercise (saved per exercise)
//    • VerticalMotion   – drift-limited height estimate for up/down exercises
//    • ProfileSignal    – converts live tracker state to "progress %" for RepDetector
//    • ExerciseTeacher  – records a teaching session (TeachView) and picks the best profile
//

import Foundation

// Teaching SmartBell a new exercise. Mirrors the "taught exercises" part of
// tools/smartbell_motion.py; test changes there first with tools/simulate_exercises.py.
//
// Two ways a forearm sensor can see a rep:
//   orientation  the forearm tilts relative to gravity (raises, push-ups, triceps, ...).
//                Measured exactly like the curl angle, so it can't drift. Preferred.
//   vertical     the forearm mostly moves up and down without tilting (squat, press, row).
//                Measured from vertical acceleration, re-anchored at the start of every rep.
//                Counts reps well; range checks are approximate.
// Teaching = hold the start position for 1.5 s, then do 3 reps. Both channels are tried by
// replaying the recording through the real engine, and the one that finds the clearest reps wins.

/// Which signal a taught exercise is measured with (see the comment above).
enum ProfileChannel: String, Codable {
    case orientation, vertical
}

/// Everything learned when teaching one exercise. Stored by WorkoutStore, keyed by exerciseId.
struct MotionProfile: Codable, Equatable {
    var exerciseId: String        // matches an Exercise.id in ExerciseLibrary
    var channel: ProfileChannel
    var uStart = Vec3(0, 0, 1)    // gravity direction (sensor frame) in the start position
    var axis = Vec3(1, 0, 0)      // rotation axis from start to end position
    var romDeg = 0.0              // orientation: start -> end angle
    var amplitude = 0.0           // vertical: signed height change of a rep, m (+ = up first)
    var vPeak = 0.0               // vertical: typical outward speed, m/s
    var template: [Double] = []   // 40-point average progress curve of the taught reps
    var twistRef = 8.0            // user's normal wrist twist (deg) during this exercise
    var repsLearned = 0           // how many clean reps were found while teaching
    var date = Date()

    /// One-line description for the UI.
    var summary: String {
        switch channel {
        case .orientation: "Arm angle, \(Int(romDeg.rounded()))° range"
        case .vertical: "Up-down movement, \(Int((abs(amplitude) * 100).rounded())) cm"
        }
    }

    var reliabilityNote: String {
        switch channel {
        case .orientation: "Reliable: measured against gravity, so it can't drift."
        case .vertical: "Counts reps well; range and depth checks are approximate."
        }
    }

    /// A Calibration for RepDetector in "progress %" units: range is 0–100 % so the usual
    /// 30 % / 70 % / 22 % thresholds apply, and `generic` switches to the generic form checks.
    func detectorCalibration(base: Calibration) -> Calibration {
        var c = base
        c.bottomDeg = 0
        c.topDeg = 100
        c.template = template
        c.twistRef = twistRef
        c.generic = true
        return c
    }
}

/// Signed angle (deg) of u around `axis`, measured from `start`.
func arcAngleDegrees(_ u: Vec3, start: Vec3, axis: Vec3) -> Double {
    // Project u onto the plane perpendicular to the axis, then measure the signed angle
    // from `start` within that plane (atan2 of sin and cos parts).
    let p = u.removingComponent(along: axis)
    guard p.norm > 1e-6 else { return 0 }
    let up = p.normalized
    return atan2(axis.dot(start.cross(up)), start.dot(up)) * degPerRad
}

/// Height change of the sensor during a rep, without long-term drift.
///
/// a_v = |a| - g_ref is the vertical acceleration: |g + a_lin| = g + (vertical part of a_lin) to
/// first order whatever way the sensor is tilted, so no orientation estimate is needed and gyro
/// drift can't leak in. Integrating twice gives height. To stop it drifting:
///  - velocity is zeroed whenever the arm is still (zero-velocity update), g_ref is re-learned
///    then, and velocity bleeds slowly toward zero otherwise;
///  - height is re-anchored to zero at the start of every rep: the moment the velocity clearly
///    heads outward again (past 25% of the learned peak speed) you have just left the start
///    position. "Reset the position after each rep", so errors only live for one rep.
struct VerticalMotion {
    static let tauV = 15.0      // s: time constant of the velocity bleed toward zero
    var outSign: Double = 0     // +1 rep moves up first (press, row), -1 down first (squat)
    var vPeak: Double = 0       // learned outward speed; 0 = no re-anchoring (first pass)
    private(set) var v = 0.0    // vertical velocity, m/s
    private(set) var z = 0.0    // height since the start of the current rep, m
    private var mean: Double?   // g_ref: |a| at rest, re-learned whenever still
    private var outward = false // true while moving away from the start position

    init(outSign: Double = 0, vPeak: Double = 0) { self.outSign = outSign; self.vPeak = vPeak }

    mutating func update(accel: Vec3, dt rawDt: Double, still: Bool) -> Double {
        let dt = min(max(rawDt, 0.001), 0.05)
        let av = accel.norm
        if mean == nil { mean = av }
        if still {
            // Zero-velocity update: at rest v must be 0. Re-learn g_ref, and ease
            // the height back toward 0 over ~1 s.
            mean! += (av - mean!) * 0.05
            v = 0
            z -= z * min(dt / 1.0, 1.0)
            outward = false
            return z
        }
        // (no "zero acceleration means stopped" shortcut: mid-rep, at constant speed,
        // the acceleration is also zero)
        // Integrate vertical acceleration to velocity, with a slow bleed so a small
        // g_ref error can't make velocity grow forever.
        v += (av - mean!) * dt
        v -= v * dt / VerticalMotion.tauV
        // Re-anchoring (only once vPeak is learned): detect "just left the start" from
        // the velocity heading outward past 25% of the typical peak speed.
        if vPeak > 0 {
            let sv = outSign * v
            if !outward && sv > 0.25 * vPeak {
                outward = true
                z = 0          // leaving the start position: re-anchor
            } else if outward && sv < -0.25 * vPeak {
                outward = false
            }
        }
        z += v * dt   // integrate velocity to height
        return z
    }
}

/// Turns the tracker state into "% of the learned range" for a taught exercise.
struct ProfileSignal {
    let profile: MotionProfile
    private var vm: VerticalMotion

    init(profile: MotionProfile) {
        self.profile = profile
        vm = VerticalMotion(outSign: profile.amplitude > 0 ? 1 : -1, vPeak: profile.vPeak)
    }

    /// Call after `tr.update(...)` each sample. 0 % = start position, 100 % = end of a typical rep.
    mutating func update(_ tr: GravityTracker, dt: Double) -> Double {
        // Always run the vertical integrator so its state stays warm, even for orientation profiles.
        let z = vm.update(accel: tr.accelFiltered, dt: dt, still: tr.isStill)
        switch profile.channel {
        case .orientation:
            guard let u = tr.up else { return 0 }
            return 100 * arcAngleDegrees(u, start: profile.uStart, axis: profile.axis) / max(profile.romDeg, 1e-6)
        case .vertical:
            return 100 * z / (abs(profile.amplitude) > 1e-6 ? profile.amplitude : 1)
        }
    }
}

/// Records a teaching session and turns it into a MotionProfile.
struct ExerciseTeacher {
    static let holdSeconds = 1.5
    static let minMoveSeconds = 4.0     // need at least this much movement for 3 reps
    static let endStillSeconds = 2.5    // stop automatically after this long still
    static let maxSamples = 100 * 45    // 45 s cap

    enum Phase { case hold, reps }   // hold = waiting for 1.5 s still; reps = recording the 3 reps

    let exerciseId: String
    let base: Calibration            // the curl calibration (forearm axis, bias, g)
    let params: MotionParams
    private(set) var phase = Phase.hold
    private(set) var samples: [SensorSample] = []   // the recording: clean hold + reps
    private(set) var holdProgress = 0.0             // 0...1, for the UI
    private(set) var moveSeconds = 0.0              // total time spent moving during the reps phase
    private(set) var stillSeconds = 0.0             // current run of stillness (resets on movement)
    private(set) var motionLevel = 0.0   // 0...1 for the on-screen meter
    private var tracker: GravityTracker
    private var holdTime = 0.0
    private var holdMagSum = 0.0

    init(exerciseId: String, base: Calibration, params: MotionParams = MotionParams()) {
        self.exerciseId = exerciseId
        self.base = base
        self.params = params
        tracker = GravityTracker(params: params, calibration: base)
    }

    /// True once there's enough movement followed by a pause: time to analyse.
    var readyToFinish: Bool {
        phase == .reps && ((moveSeconds >= ExerciseTeacher.minMoveSeconds && stillSeconds >= ExerciseTeacher.endStillSeconds)
                           || samples.count >= ExerciseTeacher.maxSamples)
    }
    /// Enough movement to let the user press "Done" manually.
    var canFinish: Bool { phase == .reps && moveSeconds >= 3 }

    /// Feed one live sample during teaching.
    mutating func push(_ s: SensorSample) {
        tracker.update(accel: s.accel, gyroDps: s.gyro, dt: s.dt)
        let d = min(s.dt, 0.05)
        let rot = (s.gyro - tracker.bias).norm
        let mag = s.accel.norm
        // Smoothed 0...1 "how much are you moving" value (rotation + |a| deviation) for the meter.
        motionLevel = motionLevel * 0.9 + min(1, rot / 120 + abs(mag - tracker.gravity) / 3) * 0.1
        switch phase {
        case .hold:
            // still = barely rotating and |a| steady (compared with the hold so far)
            let n = Double(samples.count)
            let meanMag = n > 0 ? holdMagSum / n : mag
            if rot > 15 || (n >= 10 && abs(mag - meanMag) > 0.5) {
                samples.removeAll()   // the recording starts at the beginning of a clean hold
                holdTime = 0
                holdMagSum = 0
            } else {
                samples.append(s)
                holdMagSum += mag
                holdTime += d
            }
            holdProgress = min(holdTime / ExerciseTeacher.holdSeconds, 1)
            if holdTime >= ExerciseTeacher.holdSeconds { phase = .reps }
        case .reps:
            if samples.count < ExerciseTeacher.maxSamples { samples.append(s) }
            if tracker.isStill { stillSeconds += d } else { moveSeconds += d; stillSeconds = 0 }
        }
    }

    /// Learn the profile. Returns nil if no clear repeating movement was found.
    func finish() -> MotionProfile? {
        guard samples.count > 50 else { return nil }
        // Pass 1: replay the recording once, keeping the time, up-vector, height and
        // vertical velocity at every sample.
        var tr = GravityTracker(params: params, calibration: base)
        var vm = VerticalMotion()
        var ts: [Double] = [], us: [Vec3] = [], zs: [Double] = [], vs: [Double] = []
        var t = 0.0
        for s in samples {
            t += s.dt
            tr.update(accel: s.accel, gyroDps: s.gyro, dt: s.dt)
            zs.append(vm.update(accel: tr.accelFiltered, dt: s.dt, still: tr.isStill))
            vs.append(vm.v)
            ts.append(t)
            us.append(tr.up ?? Vec3(0, 0, 1))
        }
        // Start-position gravity direction = average `up` over the hold (skipping the first
        // 0.3 s while the filter settles). `after` = sample indices once the reps begin.
        let hold = zip(ts, us).filter { $0.0 >= 0.3 && $0.0 <= ExerciseTeacher.holdSeconds }.map { $0.1 }
        guard !hold.isEmpty else { return nil }
        let s0 = hold.reduce(Vec3.zero, +).normalized
        let after = ts.indices.filter { ts[$0] > ExerciseTeacher.holdSeconds }
        guard !after.isEmpty else { return nil }

        // Pass 2: build up to two candidate profiles (one per channel).
        var candidates: [MotionProfile] = []
        // orientation: direction farthest from the start, averaged over the rep peaks.
        // Needs at least 20° of tilt, and a well-defined rotation axis (|s0 × e| > 0.2).
        let ang = after.map { acos(max(-1, min(1, us[$0].dot(s0)))) * degPerRad }
        if let maxAng = ang.max(), maxAng >= 20 {
            let pk = peaks(after.map { ts[$0] }, ang, minHeight: 0.6 * maxAng)
            if !pk.isEmpty {
                let e = pk.map { us[after[$0]] }.reduce(Vec3.zero, +).normalized
                let axis = s0.cross(e)
                if axis.norm > 0.2 {
                    let rom = acos(max(-1, min(1, s0.dot(e)))) * degPerRad
                    candidates.append(MotionProfile(exerciseId: exerciseId, channel: .orientation, uStart: s0,
                                                    axis: axis.normalized, romDeg: rom))
                }
            }
        }
        // vertical: the first movement after the hold sets the direction (up for a press, down for
        // a squat); its extreme, before it heads back, is a first guess of the amplitude
        // (needs at least 6 cm of travel and 0.05 m/s of outward speed)
        let zz = after.map { zs[$0] }
        if let first = zz.firstIndex(where: { abs($0) > 0.06 }) {
            let sign: Double = zz[first] > 0 ? 1 : -1
            var k = first, ext = 0.0
            while k < zz.count && sign * zz[k] > 0.3 * ext {
                ext = max(ext, sign * zz[k])
                k += 1
            }
            if ext >= 0.06 && k > first {
                let vpk = (first..<k).map { sign * vs[after[$0]] }.max() ?? 0
                if vpk > 0.05 {
                    candidates.append(MotionProfile(exerciseId: exerciseId, channel: .vertical, uStart: s0,
                                                    amplitude: sign * ext, vPeak: vpk))
                }
            }
        }

        // pad with a moment of the last reading so a rep that just ended gets analysed
        var padded = samples
        if let last = samples.last {
            padded += Array(repeating: SensorSample(accel: last.accel, gyro: last.gyro, dt: 0.01), count: 60)
        }
        // Run the full engine over the recording with a candidate profile; return the counted reps.
        func replay(_ c: MotionProfile) -> [RepResult] {
            var eng = MotionEngine(calibration: base, params: params, profile: c)
            var out: [RepResult] = []
            for s in padded {
                for e in eng.push(s) { if case .result(let r) = e, r.counted { out.append(r) } }
            }
            return out
        }

        // Pass 3: score each candidate. More reps found = better; inconsistent peak heights
        // = worse; orientation gets +15 because it can't drift. Keep the best one.
        var best: (score: Double, profile: MotionProfile)?
        for var c in candidates {
            var res = replay(c)
            if c.channel == .vertical && !res.isEmpty {
                // refine: scale so the median taught rep peaks at 100%
                c.amplitude *= res.map(\.topDeg).sorted()[res.count / 2] / 100
                res = replay(c)
            }
            guard res.count >= 2 else { continue }
            let tops = res.map(\.topDeg)
            let spread = (tops.max() ?? 0) - (tops.min() ?? 0)
            let score = Double(res.count) * 10 - spread / 10 + (c.channel == .orientation ? 15 : 0) // prefer drift-free
            if best == nil || score > best!.score {
                c.template = (0..<40).map { i in res.reduce(0) { $0 + $1.curve[i] } / Double(res.count) }
                c.twistRef = res.map(\.twistRange).sorted()[res.count / 2]
                c.repsLearned = res.count
                c.date = Date()
                best = (score, c)
            }
        }
        return best?.profile
    }

    /// Local maxima above minHeight, at least minGap s apart (keeps the higher one).
    private func peaks(_ ts: [Double], _ ys: [Double], minHeight: Double, minGap: Double = 0.6) -> [Int] {
        var out: [Int] = []
        guard ys.count >= 3 else { return out }
        for i in 1..<(ys.count - 1) where ys[i] >= minHeight && ys[i] >= ys[i - 1] && ys[i] > ys[i + 1] {
            if let last = out.last, ts[i] - ts[last] < minGap {
                if ys[i] > ys[last] { out[out.count - 1] = i }
            } else {
                out.append(i)
            }
        }
        return out
    }
}
