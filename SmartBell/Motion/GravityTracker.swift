//
//  GravityTracker.swift
//  SmartBell — Motion
//
//  Core sensor-fusion filter. Each sample it updates `up` (gravity direction in the
//  sensor's own frame) using a complementary filter: gyro to predict, accelerometer to
//  correct. Also detects stillness and re-learns gyro bias / accelerometer scale whenever
//  the arm is still. Everything downstream (forearm angle β, rep detection, form checks)
//  is computed from `up`, so this is the file that keeps the app drift-free.
//
//  Pipeline per sample:  remove lever-arm accel → 8 Hz low-pass → stillness check
//                        → gyro predict → accel correct (weighted by trust)
//

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

    /// Feed one raw sensor sample. `a` in m/s², `gyroDps` in deg/s, `rawDt` in seconds
    /// since the previous sample (from the firmware's dt_s field).
    mutating func update(accel a: Vec3, gyroDps: Vec3, dt rawDt: Double) {
        // A long gap (dropped BLE packets) means our state is stale: start over.
        if rawDt > params.gapResetSeconds { reset() }
        // Clamp dt so a single bad timestamp can't make one step huge or zero.
        let dt = min(max(rawDt, 0.001), 0.05)

        // Bias-corrected angular rate, converted to rad/s.
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

        // First sample after (re)start: initialise every filter state from this
        // reading and assume the accelerometer is pointing along gravity.
        guard var u = up, var lpf = accelLPF, var slow = accelSlow else {
            accelLPF = aIn
            accelSlow = aIn
            accelFiltered = aIn
            up = aIn.normalized
            rate = w
            return
        }

        // First-order (RC) low-pass at accelLowPassHz: y += (x − y)·dt/(RC + dt).
        let rc = 1.0 / (2.0 * Double.pi * params.accelLowPassHz)
        let k = dt / (rc + dt)
        lpf = lpf + (aIn - lpf) * k
        // How far the raw reading sits from its low-pass: high-frequency shaking.
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
        // Must be quiet for stillSamples in a row (0.25 s): one calm instant mid-rep isn't enough.
        stillCount = moving ? 0 : stillCount + 1
        isStill = stillCount >= params.stillSamples
        if isStill {
            // At rest the true rotation rate is zero, so whatever the gyro reads is bias.
            // Nudge the bias estimate toward it, and let g follow this accelerometer's scale.
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

        // Save state for the next sample and publish outputs.
        up = u
        accelLPF = lpf
        accelSlow = slow
        accelFiltered = lpf
        rate = w
        linearAcceleration = (lpf - u * gravity).norm
    }
}

/// 0 = forearm hanging straight down, 90 = horizontal, ~140 = top of a curl.
/// β = angle between the forearm (elbow → hand) and straight down (−up).
/// `forearm` comes from calibration; `up` from GravityTracker. Both are sensor-frame unit vectors.
func forearmAngleDegrees(up: Vec3, forearm: Vec3) -> Double {
    // cos β = forearm · (−up); clamp before acos so rounding can't produce NaN.
    let c = -forearm.dot(up)
    return acos(max(-1.0, min(1.0, c))) * degPerRad
}
