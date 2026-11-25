//
//  MotionModels.swift
//  SmartBell — Motion
//
//  Shared data types and tuning constants for the motion pipeline:
//    • MotionParams  – every filter/stillness threshold in one place
//    • Calibration   – what the 15 s calibration learns about the strap mounting
//    • MotionFrame   – one processed sample (forearm angle, rates, hand direction)
//    • FormIssue     – the form problems we can detect, with cue text and score penalty
//    • RepResult     – everything measured about one finished rep
//

import Foundation

// Mirrors tools/smartbell_motion.py. If you change a constant here, change it there too,
// then re-run `python3 tools/evaluate.py --seeds 20` to check nothing regressed.

let standardGravity = 9.80665  // m/s², used until calibration measures this sensor's own g

/// Tuning knobs for GravityTracker / MotionEngine. Defaults were chosen against
/// the simulator (tools/evaluate.py), not yet against labeled real recordings.
struct MotionParams {
    var accelLowPassHz = 8.0      // low-pass on accel before it is used as a gravity reference
    var gainMotion = 1.5          // 1/s: how fast accel corrects the up-vector while moving
    var gainStill = 10.0          // 1/s: when still, snap to accel quickly
    var trustSigma = 1.0          // m/s^2: accel trusted only when |a| is near g
    var stillGyroDps = 6.0        // still if bias-corrected |gyro| below this...
    var stillAccelDev = 0.35      // ...and accel isn't shaking (m/s^2 from its low-pass)
    var stillAccelDrift = 0.15    // ...and isn't slowly changing (8 Hz vs 1 Hz filtered, m/s^2)
    var stillSamples = 25         // ...for this many consecutive samples (0.25 s)
    var biasAlpha = 0.02          // per still sample, gyro-bias learning rate
    var biasMaxDps = 10.0         // never learn a bias bigger than this
    var leverMeters = 0.06        // sensor distance from the elbow along the forearm
    var gapResetSeconds = 0.15    // a gap this long (BLE drop) re-initialises the filter
    var wobbleDecaySeconds = 0.5  // between reps the twist integrator decays to 0
}

/// Everything learned in the 15-second calibration. Mount-specific: redo it if the strap moves.
struct Calibration: Codable, Equatable {
    var forearm = Vec3(0, 0, -1)    // unit vector in sensor frame, elbow -> hand
    var hinge = Vec3(1, 0, 0)       // unit vector in sensor frame, elbow axis (+ = curling up)
    var gyroBias = Vec3.zero        // deg/s
    var gravity = standardGravity   // what this accelerometer reads at rest
    var bottomDeg = 8.0             // forearm angle at the bottom of a calibration rep
    var topDeg = 140.0              // forearm angle at the top of a calibration rep
    var twistRef = 8.0              // typical wrist rotation (deg) in calibration reps
    var swayRef = 4.0               // typical sideways wobble (deg) in calibration reps
    var template: [Double] = []     // 40-point time-normalised forearm-angle curve
    var date = Date()
    /// true for taught exercises: units are % of the learned range and form rules are generic.
    /// Optional so calibrations saved by older versions still decode.
    var generic: Bool? = nil
    var isGeneric: Bool { generic == true }

    // Rep-detector thresholds, all expressed as fractions of the user's own range of
    // motion (ROM) so they work for any arm length, mounting or flexibility.
    // ROM is floored at 40° so a sloppy calibration can't make thresholds collapse together.
    var rom: Double { max(topDeg - bottomDeg, 40.0) }
    // startDeg: crossing upward = a rep has begun. topThresholdDeg: the peak must pass this
    // for the rep to count. returnDeg: crossing downward = the rep is over (counted here).
    // returnDeg < startDeg gives hysteresis, so noise near one threshold can't double-count.
    var startDeg: Double { bottomDeg + 0.30 * rom }
    var topThresholdDeg: Double { bottomDeg + 0.70 * rom }
    var returnDeg: Double { bottomDeg + 0.22 * rom }
}

/// One processed sample, as stored by the rep detector.
struct MotionFrame {
    var t: Double
    var beta: Double        // forearm angle from straight down, deg (gravity referenced, no drift)
    var wCurl: Double       // deg/s about the elbow hinge
    var twistDeg: Double    // wrist rotation since this rep started (short-window gyro integral)
    var hand: Vec3          // unit forearm vector in the heading-reference frame (fwd, side, up)
    var linAcc: Double      // m/s^2, elbow/body acceleration (swinging)
}

/// A form problem detected on one rep (see RepDetector.analyse for the thresholds).
enum FormIssue: String, Codable, CaseIterable, Identifiable {
    case swing, elbow, partial, shortTop, shortBottom, fastDown, fastUp, twist, sway
    var id: String { rawValue }

    /// Lower number = more important. Only the highest-priority issue is spoken after a rep.
    var priority: Int {
        switch self {
        case .swing: 1
        case .elbow: 2
        case .partial, .shortTop: 3
        case .shortBottom: 4
        case .fastDown: 5
        case .fastUp: 6
        case .twist: 7
        case .sway: 8
        }
    }

    /// Points subtracted from the rep's 100-point form score.
    var penalty: Int {
        switch self {
        case .swing: 30
        case .elbow: 20
        case .partial: 35
        case .shortTop: 20
        case .shortBottom: 15
        case .fastDown: 15
        case .fastUp: 10
        case .twist: 10
        case .sway: 15
        }
    }

    /// Short spoken/printed cue.
    var cue: String {
        switch self {
        case .swing: "Don't swing. Keep your body still."
        case .elbow: "Keep your elbow pinned to your side."
        case .partial: "Curl all the way up."
        case .shortTop: "Curl a little higher."
        case .shortBottom: "Lower all the way down."
        case .fastDown: "Lower slower, about two seconds."
        case .fastUp: "Lift with control, not momentum."
        case .twist: "Keep your wrist from twisting."
        case .sway: "Keep the dumbbell in a straight path."
        }
    }

    /// Cue for taught (non-curl) exercises, where only range, tempo and twist are judged.
    var genericCue: String {
        switch self {
        case .partial: "Go through the full range."
        case .shortTop: "Go a little further."
        case .shortBottom: "Return fully to the start."
        case .fastDown: "Slower on the way back."
        case .fastUp: "Control the movement, no bouncing."
        case .twist: "Keep your wrist steady."
        default: cue
        }
    }

    func cueText(generic: Bool) -> String { generic ? genericCue : cue }

    /// Name of the issue, shown in history and session summaries.
    var label: String {
        switch self {
        case .swing: "Swinging"
        case .elbow: "Elbow drifting forward"
        case .partial: "Partial rep"
        case .shortTop: "Not curling high enough"
        case .shortBottom: "Not lowering fully"
        case .fastDown: "Lowering too fast"
        case .fastUp: "Lifting too fast"
        case .twist: "Wrist twisting"
        case .sway: "Path drifting sideways"
        }
    }
}

/// Measurements and form verdict for one rep (counted or partial). Saved with the workout.
/// For curls, angles are degrees of forearm angle; for taught exercises they are % of range.
struct RepResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var index: Int                  // 1-based position in the set
    var counted: Bool               // false = partial rep (peak never reached the count threshold)
    var startT: Double              // seconds (sensor clock) when the rep began
    var peakT: Double               // ...when it reached its highest point
    var endT: Double                // ...when it finished
    var bottomDeg: Double           // lowest angle at the start of the rep
    var topDeg: Double              // highest angle reached
    var concentricSeconds: Double   // lift time (bottom band -> top band)
    var eccentricSeconds: Double    // lower time (top band -> bottom band)
    var peakSpeedDps: Double
    var twistRange: Double          // deg
    var swayRange: Double           // deg out of the curl plane, peak to peak
    var swing: Double               // m/s^2 peak elbow/body acceleration
    var pathRmsDeg: Double          // difference from the calibration rep shape
    var score: Int
    var issues: [FormIssue]
    var curve: [Double]             // 40-point forearm angle curve
    var path: [Vec3] = []           // hand path in the rep's own frame (fwd, side, up), for drawing
    var generic: Bool? = nil        // true for taught exercises (values in % of learned range)
    var isGeneric: Bool { generic == true }

    /// 0...100, how close the rep's shape was to the calibration reps.
    var consistency: Int { max(0, min(100, Int((100 - pathRmsDeg * 2.5).rounded()))) }
}
