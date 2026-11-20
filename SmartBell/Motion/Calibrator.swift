import Foundation

/// Two-step calibration, ~15 s:
///   1. Arm hanging straight down, still, for 2 s  -> forearm axis, gyro bias, accel scale
///   2. Three slow, full curls                      -> elbow hinge axis, your range, your rep shape
/// Nothing about the mounting is hard-coded, so it works whichever way the box is strapped on.
struct Calibrator {
    static let hangSeconds = 2.0
    static let curlsNeeded = 3

    let params: MotionParams
    private var hangAccel: [Vec3] = []
    private var hangGyro: [Vec3] = []
    private var hangTime = 0.0
    private(set) var curlSamples: [SensorSample] = []
    private(set) var probe: MotionEngine? = nil
    private(set) var probeReps = 0

    init(params: MotionParams = MotionParams()) { self.params = params }

    /// Returns progress 0...1. Restarts if the arm moves.
    mutating func pushHang(_ s: SensorSample) -> Double {
        let n = hangAccel.count
        let recent = hangAccel.suffix(50)
        let meanNorm = n > 0 ? recent.reduce(0) { $0 + $1.norm } / Double(recent.count) : 0
        if s.gyro.norm > 15.0 || (n >= 10 && abs(s.accel.norm - meanNorm) > 1.2) {
            hangAccel.removeAll(); hangGyro.removeAll(); hangTime = 0
            return 0
        }
        hangAccel.append(s.accel)
        hangGyro.append(s.gyro)
        hangTime += min(s.dt, 0.05)
        return min(hangTime / Calibrator.hangSeconds, 1)
    }

    /// Call when pushHang reached 1. Returns the partial calibration and arms step 2.
    mutating func finishHang() -> Calibration {
        let n = Double(max(hangAccel.count, 1))
        let meanA = hangAccel.reduce(Vec3.zero, +) * (1 / n)
        let meanG = hangGyro.reduce(Vec3.zero, +) * (1 / n)
        var cal = Calibration()
        cal.forearm = -meanA.normalized
        cal.gyroBias = meanG
        cal.gravity = hangAccel.reduce(0) { $0 + $1.norm } / n
        cal.hinge = Vec3(1, 0, 0).removingComponent(along: cal.forearm).normalized
        if cal.forearm.cross(Vec3(1, 0, 0)).norm < 0.3 {
            cal.hinge = Vec3(0, 1, 0).removingComponent(along: cal.forearm).normalized
        }
        var probeCal = cal
        probeCal.bottomDeg = 8; probeCal.topDeg = 120; probeCal.template = []
        probe = MotionEngine(calibration: probeCal, params: params)
        curlSamples.removeAll()
        probeReps = 0
        return cal
    }

    /// Step 2 sample. Returns the live forearm angle for display.
    mutating func pushCurl(_ s: SensorSample) -> Double {
        curlSamples.append(s)
        let events = probe?.push(s) ?? []  // mutate in place (avoids copying the frame buffer)
        for e in events {
            if case .result(let r) = e, r.counted { probeReps += 1 }
        }
        return probe?.beta ?? 0
    }

    /// Learns the hinge axis (PCA of the gyro), your range and your rep template.
    /// Returns nil if fewer than 2 clear curls were seen.
    func finishCurls(_ base: Calibration) -> Calibration? {
        var cal = base
        let rows = curlSamples

        // Hinge axis = dominant rotation axis (power iteration on the gyro covariance).
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in rows {
            let w = r.gyro - cal.gyroBias
            let a = [w.x, w.y, w.z]
            for i in 0..<3 { for j in 0..<3 { c[i][j] += a[i] * a[j] } }
        }
        var v = Vec3(0.577, 0.577, 0.577)
        for _ in 0..<50 {
            v = Vec3(c[0][0] * v.x + c[0][1] * v.y + c[0][2] * v.z,
                     c[1][0] * v.x + c[1][1] * v.y + c[1][2] * v.z,
                     c[2][0] * v.x + c[2][1] * v.y + c[2][2] * v.z).normalized
        }
        let h = v.removingComponent(along: cal.forearm).normalized

        // Sign: a positive hinge rate must mean the angle is increasing.
        var tr = GravityTracker(params: params, calibration: cal)
        var prevBeta: Double? = nil
        var s = 0.0
        for r in rows {
            tr.update(accel: r.accel, gyroDps: r.gyro, dt: r.dt)
            guard let u = tr.up else { continue }
            let beta = forearmAngleDegrees(up: u, forearm: cal.forearm)
            if let pb = prevBeta { s += (beta - pb) * (tr.rate * degPerRad).dot(h) }
            prevBeta = beta
        }
        cal.hinge = s >= 0 ? h : -h

        // Replay with default thresholds to find the reps.
        var probeCal = cal
        probeCal.bottomDeg = 8; probeCal.topDeg = 120; probeCal.template = []
        var eng = MotionEngine(calibration: probeCal, params: params)
        var results: [RepResult] = []
        for r in rows {
            for e in eng.push(r) { if case .result(let res) = e, res.counted { results.append(res) } }
        }
        guard results.count >= 2 else { return nil }
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        cal.bottomDeg = median(results.map(\.bottomDeg))
        cal.topDeg = median(results.map(\.topDeg))
        cal.twistRef = median(results.map(\.twistRange))
        cal.swayRef = median(results.map(\.swayRange))
        cal.template = (0..<40).map { i in results.reduce(0) { $0 + $1.curve[i] } / Double(results.count) }
        cal.date = Date()
        return cal
    }
}
