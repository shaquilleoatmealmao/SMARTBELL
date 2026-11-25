//
//  AngleRepCounter.swift
//  SmartBell — Camera
//
//  Counts reps from a single camera-measured joint angle (from PoseFrame.angle).
//  Used by WorkoutController when an exercise is set to camera counting, and by
//  CameraLab on the Camera tab. Rest/work angles per exercise come from
//  CameraRepConfig in ExerciseLibrary.
//

import Foundation

/// Rep counter for any joint angle from the camera. Same idea as the SmartBell RepDetector:
/// hysteresis on how far the angle has travelled from the rest position toward the work position.
///
///   progress p = (angle - rest) / (work - rest)     0 = rest position, 1 = full rep
///   rep starts when p > 0.35, is a full rep if the peak passed 0.8, and ends when p < 0.25
///
/// Works for movements in either direction (a curl increases the angle, a press decreases it).
struct AngleRepCounter {
    /// counted(total, rep) for a full rep; partial(rep) when the peak stayed below 0.8.
    enum Event { case counted(Int, CameraRep), partial(CameraRep) }

    let config: CameraRepConfig
    private(set) var count = 0
    private(set) var smoothed: Double?       // filtered angle, deg (nil = no tracking)
    private(set) var inRep = false
    private var lastTime: TimeInterval?      // time of the last valid measurement
    private var startT = 0.0                 // when p crossed 0.35
    private var peakP = 0.0                  // highest progress in this rep
    private var peakT = 0.0

    init(config: CameraRepConfig) { self.config = config }

    /// 0 at the rest angle, 1 at the work angle (can go outside 0...1).
    var progress: Double {
        guard let a = smoothed else { return 0 }
        return (a - config.restDeg) / (config.workDeg - config.restDeg)
    }

    mutating func reset() { self = AngleRepCounter(config: config) }

    /// Feed one measurement (nil = joints not visible). Returns an event when a rep finishes.
    mutating func push(angle: Double?, time t: TimeInterval) -> Event? {
        guard let a = angle else {
            if let last = lastTime, t - last > 1.0 { inRep = false; smoothed = nil } // lost tracking
            return nil
        }
        // light smoothing: Vision joints jitter by a few degrees frame to frame
        if let s = smoothed, let last = lastTime, t - last < 0.5 { smoothed = s + 0.45 * (a - s) } else { smoothed = a }
        lastTime = t
        let p = progress

        if !inRep {
            if p > 0.35 {
                inRep = true
                startT = t
                peakP = p; peakT = t
            }
            return nil
        }
        if p > peakP { peakP = p; peakT = t }
        if t - startT > 15 { inRep = false; return nil }  // held too long: not a rep
        guard p < 0.25 else { return nil }                 // still in the rep
        // Back below 0.25: the rep is over.

        inRep = false
        // The thresholds cut off the slow ends of the movement; for a smooth rep the 35%->peak and
        // peak->25% stretches are each about 60% of the full lift / lower time.
        let rep = CameraRep(upSeconds: max(peakT - startT, 0.05) / 0.6,
                            downSeconds: max(t - peakT, 0.05) / 0.6,
                            romDeg: abs(config.workDeg - config.restDeg) * min(peakP, 1.2),
                            counted: peakP >= 0.8)
        if rep.counted {
            count += 1
            return .counted(count, rep)
        }
        return .partial(rep)
    }
}
