//
//  DemoSensor.swift
//  SmartBell — Sensor
//
//  A fake ESP32 for the simulator / demos. Produces the same SensorSample stream as
//  BLEManager (100 Hz, via `onSample`) from a scripted arm motion, so every screen can
//  be exercised without hardware. Mirrors tools/simulate.py.
//
//  How a sample is made: pose(at:) gives the arm's angles at time t → build the
//  sensor's rotation and position in the world → gyro = rotation change between
//  samples, accel = second difference of position + gravity → add bias, noise, scale error.
//

import Foundation

/// Simulated forearm-mounted IMU so the app can be used without the ESP32.
///
/// It is a small physics model, not canned numbers: an arm curls through a scripted
/// set of reps, and the sensor readings are computed from that motion with an arbitrary
/// mounting rotation, gyro bias, noise and a lever arm, i.e. the same problems the real
/// sensor has. Some reps deliberately have bad form so the coaching can be seen.
/// Everything it produces is labelled "Demo" in the UI.
@MainActor
final class DemoSensor {
    /// calibration = 3 clean slow curls (for the calibration screen); workout = a looping
    /// set that includes deliberately bad reps.
    enum Script { case calibration, workout }

    /// One scripted rep. Times in seconds: con = lift, hold = pause at top, ecc = lower,
    /// rest = pause at bottom. Angles in degrees of forearm angle β.
    struct DemoRep {
        var con = 1.2, hold = 0.3, ecc = 2.0, rest = 0.8
        var top = 140.0, bottom = 6.0
        var swing = 0.0      // m the elbow is heaved forward during the lift
        var twist = 0.0      // deg wrist rotation amplitude
        var sway = 0.0       // deg sideways wobble amplitude
        var duration: Double { con + hold + ecc + rest }
    }

    var onSample: ((SensorSample) -> Void)?

    private var timer: Timer?
    private var wallStart = Date()                 // real time the stream started
    private var simTime = 0.0                      // simulated time of the last sample produced
    private let dt = 0.01                          // 100 Hz, like the firmware
    private var script = Script.workout
    private var lastRotation: Mat3?                // previous sensor→world rotation (for the gyro)
    private var lastPositions: [Vec3] = []         // last 3 positions (for the accel second difference)
    private var bias = Vec3(2.2, -1.6, 1.1)        // deg/s, deliberately not zero
    private let mount = Mat3(axis: Vec3(0.3, 0.8, -0.5), angle: 1.9)  // arbitrary box-on-strap rotation
    private let base = Mat3(r0: Vec3(1, 0, 0), r1: Vec3(0, -1, 0), r2: Vec3(0, 0, -1))  // forearm z points down when β = 0
    private let lever = 0.06                       // m from elbow to sensor
    private var rng = SystemRandomNumberGenerator()

    private let calibrationReps = [DemoRep(con: 1.6, hold: 0.4, ecc: 2.2, rest: 1.0, top: 138),
                                   DemoRep(con: 1.6, hold: 0.4, ecc: 2.2, rest: 1.0, top: 139),
                                   DemoRep(con: 1.6, hold: 0.4, ecc: 2.2, rest: 1.0, top: 137)]
    private let workoutReps = [DemoRep(), DemoRep(con: 1.0, ecc: 2.2, top: 142),
                               DemoRep(con: 0.9, ecc: 0.5),              // drops the weight
                               DemoRep(),
                               DemoRep(con: 0.6, top: 150, swing: 0.12),  // swings
                               DemoRep(top: 90),                          // partial
                               DemoRep(),
                               DemoRep(twist: 35),                        // twists wrist
                               DemoRep(con: 1.1, ecc: 2.1),
                               DemoRep(bottom: 40),                       // doesn't lower fully
                               DemoRep(top: 138),
                               DemoRep(top: 165),                         // elbow forward
                               DemoRep(sway: 14)]                         // wobbles sideways

    /// Start (or restart) streaming the given script from t = 0.
    func start(script: Script) {
        stop()
        self.script = script
        wallStart = Date()
        simTime = 0
        lastRotation = nil
        lastPositions = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func restart(script: Script) { start(script: script) }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    private func tick() {
        // Catch up to wall-clock time so the stream stays at 100 Hz even if a timer fires late.
        let target = Date().timeIntervalSince(wallStart)
        var produced = 0
        while simTime + dt <= target && produced < 20 {
            simTime += dt
            produced += 1
            if let s = sample(at: simTime) { onSample?(s) }
        }
        if target - simTime > 0.5 { simTime = target } // fell far behind (app was paused)
    }

    // MARK: - motion script

    private struct Pose { var beta: Double; var twist: Double; var sway: Double; var elbow: Double }

    /// Arm pose at time t: a still lead-in, then the script's reps in order
    /// (the workout script loops with a 4 s break between passes).
    private func pose(at t: Double) -> Pose {
        let lead: Double
        let reps: [DemoRep]
        let loop: Bool
        switch script {
        case .calibration: lead = 4.0; reps = calibrationReps; loop = false
        case .workout: lead = 2.0; reps = workoutReps; loop = true
        }
        if t < lead { return Pose(beta: 3, twist: 0, sway: 0, elbow: 0) }
        var s = t - lead
        let cycle = reps.reduce(0) { $0 + $1.duration } + (loop ? 4.0 : 0)
        if loop { s = s.truncatingRemainder(dividingBy: cycle) }
        var current = 3.0
        for rep in reps {
            if s < rep.duration { return pose(rep, at: s, from: current) }
            s -= rep.duration
            current = rep.bottom
        }
        return Pose(beta: current, twist: 0, sway: 0, elbow: 0)
    }

    /// Pose `s` seconds into one rep. `smooth` is a quintic ease-in/out (zero velocity and
    /// acceleration at both ends), so the simulated arm starts and stops like a real one.
    /// `env` is a half-sine envelope that fades twist/sway/tremor in and out over the rep.
    private func pose(_ rep: DemoRep, at s: Double, from start: Double) -> Pose {
        func smooth(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * x * (10 - 15 * x + 6 * x * x) }
        let active = rep.con + rep.hold + rep.ecc
        var beta: Double
        if s < rep.con { beta = start + (rep.top - start) * smooth(s / rep.con) }
        else if s < rep.con + rep.hold { beta = rep.top }
        else if s < active { beta = rep.top + (rep.bottom - rep.top) * smooth((s - rep.con - rep.hold) / rep.ecc) }
        else { beta = rep.bottom }
        let env = s < active ? sin(Double.pi * s / active) : 0
        let elbow = s < rep.con ? rep.swing * (0.5 - 0.5 * cos(2 * Double.pi * s / rep.con)) : 0
        // a little natural tremor so it doesn't look robotic
        beta += 0.4 * sin(2 * Double.pi * 7.3 * s) * env
        return Pose(beta: beta, twist: rep.twist * env * sin(2 * Double.pi * 1.5 * s),
                    sway: rep.sway * env * sin(2 * Double.pi * 1.0 * s), elbow: elbow)
    }

    // MARK: - sensor model

    /// Standard normal random number (Box–Muller transform).
    private func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
    }

    private func sample(at t: Double) -> SensorSample? {
        let p = pose(at: t)
        // forearm frame -> world (X lateral, Y forward, Z up); same convention as tools/simulate.py
        let forearmToWorld = Mat3(axis: Vec3(0, 1, 0), angle: p.sway * radPerDeg)
            * Mat3(axis: Vec3(1, 0, 0), angle: -p.beta * radPerDeg)
            * base
            * Mat3(axis: Vec3(0, 0, 1), angle: p.twist * radPerDeg)
        let sensorToWorld = forearmToWorld * mount
        // Sensor position = elbow (moved forward by `swing`) + lever arm along the forearm.
        let position = Vec3(0, p.elbow, 0) + forearmToWorld * Vec3(0, 0, lever)

        lastPositions.append(position)
        if lastPositions.count > 3 { lastPositions.removeFirst() }
        defer { lastRotation = sensorToWorld }
        guard let prev = lastRotation, lastPositions.count == 3 else { return nil }

        // Ideal gyro: rotation from the previous sample to this one, in the sensor frame, per second.
        let rel = prev.transposed * sensorToWorld
        let gyro = rel.rotationVector * (degPerRad / dt)
        // Ideal accelerometer: linear acceleration (finite difference) plus +g, rotated into
        // the sensor frame. An accelerometer measures "specific force", so at rest it reads +g up.
        let acc = (lastPositions[2] - lastPositions[1] * 2 + lastPositions[0]) * (1 / (dt * dt))
        let specificForce = sensorToWorld.transposed * (acc + Vec3(0, 0, standardGravity))

        // Real-sensor imperfections: bias random walk, gyro noise (0.5 °/s),
        // 2% accelerometer scale error and accel noise (0.08 m/s²).
        bias = bias + Vec3(gaussian(), gaussian(), gaussian()) * 0.01
        let g = gyro + bias + Vec3(gaussian(), gaussian(), gaussian()) * 0.5
        let a = specificForce * 1.02 + Vec3(gaussian(), gaussian(), gaussian()) * 0.08
        return SensorSample(accel: a, gyro: g, dt: dt)
    }
}
