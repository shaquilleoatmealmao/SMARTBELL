import Foundation

/// Tracks `up`, the direction of gravity in the sensor frame, plus the gyro bias.
///
/// Why this doesn't drift: tilt relative to gravity is observable. The gyro moves `up`
/// between samples (smooth, but drifts), and the accelerometer pulls it back toward the
/// measured gravity direction whenever the measured acceleration looks like gravity
/// (|a| close to g). The error therefore stays bounded instead of growing with time.
/// Acceleration is never integrated.
struct GravityTracker {
    let params: MotionParams
    private(set) var up: Vec3? = nil
    private(set) var bias: Vec3            // deg/s
    private(set) var gravity: Double
    private let lever: Vec3?
    private var accelLPF: Vec3? = nil
    private var accelSlow: Vec3? = nil
    /// Low-passed acceleration with rotation effects removed (m/s^2).
    private(set) var accelFiltered = Vec3.zero
    private var previousRate: Vec3? = nil
    private var stillCount = 0
    private(set) var isStill = false
    private(set) var rate = Vec3.zero      // bias-corrected angular rate, rad/s
    private(set) var linearAcceleration = 0.0 // |a - g*up| after removing rotation effects, m/s^2

    init(params: MotionParams, calibration: Calibration?) {
        self.params = params
        bias = calibration?.gyroBias ?? .zero
        gravity = calibration?.gravity ?? standardGravity
        lever = calibration.map { $0.forearm * params.leverMeters }
    }

    mutating func reset() {
        up = nil
        accelLPF = nil
        accelSlow = nil
        previousRate = nil
        stillCount = 0
    }

    mutating func update(accel a: Vec3, gyroDps: Vec3, dt rawDt: Double) {
        if rawDt > params.gapResetSeconds { reset() }
        let dt = min(max(rawDt, 0.001), 0.05)

        let w = (gyroDps - bias) * radPerDeg

        // The sensor sits `lever` from the elbow (the pivot), so it also feels
        // centripetal and tangential acceleration. Remove them.
        var aRot = Vec3.zero
        if let lever, let previousRate {
            let alpha = (w - previousRate) * (1.0 / dt)
            aRot = w.cross(w.cross(lever)) + alpha.cross(lever)
        }
        previousRate = w
        let aIn = a - aRot

        guard var u = up, var lpf = accelLPF, var slow = accelSlow else {
            accelLPF = aIn
            accelSlow = aIn
            accelFiltered = aIn
            up = aIn.normalized
            rate = w
            return
        }

        let rc = 1.0 / (2.0 * Double.pi * params.accelLowPassHz)
        let k = dt / (rc + dt)
        lpf = lpf + (aIn - lpf) * k
        let shake = (aIn - lpf).norm
        // Slow (1 Hz) copy: smooth translation without rotation (squat, press) shows up as a
        // difference between the 8 Hz and 1 Hz filtered acceleration.
        let rcSlow = 1.0 / (2.0 * Double.pi * 1.0)
        slow = slow + (aIn - slow) * (dt / (rcSlow + dt))
        let drift = (lpf - slow).norm

        // Stillness: learn gyro bias and accelerometer scale.
        let moving = w.norm * degPerRad > params.stillGyroDps
            || shake > params.stillAccelDev
            || drift > params.stillAccelDrift
            || abs(lpf.norm - gravity) > 1.5
        stillCount = moving ? 0 : stillCount + 1
        isStill = stillCount >= params.stillSamples
        if isStill {
            let nb = bias + (gyroDps - bias) * params.biasAlpha
            if nb.norm < params.biasMaxDps { bias = nb }
            gravity += 0.01 * (lpf.norm - gravity)
        }

        // 1) Predict: a world-fixed vector seen from a rotating body turns by -w*dt.
        u = u.rotated(by: w * (-dt)).normalized

        // 2) Correct toward measured gravity, weighted by how much it looks like gravity.
        let mag = lpf.norm
        if mag > 1e-6 {
            let dev = (mag - gravity) / params.trustSigma
            let trust = exp(-dev * dev)
            var gain = (isStill ? params.gainStill : params.gainMotion) * trust * dt
            gain = min(max(gain, 0.0), 1.0)
            u = (u + (lpf * (1.0 / mag) - u) * gain).normalized
        }

        up = u
        accelLPF = lpf
        accelSlow = slow
        accelFiltered = lpf
        rate = w
        linearAcceleration = (lpf - u * gravity).norm
    }
}

/// 0 = forearm hanging straight down, 90 = horizontal, ~140 = top of a curl.
func forearmAngleDegrees(up: Vec3, forearm: Vec3) -> Double {
    let c = -forearm.dot(up)
    return acos(max(-1.0, min(1.0, c))) * degPerRad
}
