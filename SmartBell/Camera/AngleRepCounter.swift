import Foundation

/// Rep counter for any joint angle from the camera. Same idea as the SmartBell RepDetector:
/// hysteresis on how far the angle has travelled from the rest position toward the work position.
///
///   progress p = (angle - rest) / (work - rest)     0 = rest position, 1 = full rep
///   rep starts when p > 0.35, is a full rep if the peak passed 0.8, and ends when p < 0.25
///
/// Works for movements in either direction (a curl increases the angle, a press decreases it).
struct AngleRepCounter {
    enum Event { case counted(Int, CameraRep), partial(CameraRep) }

    let config: CameraRepConfig
    private(set) var count = 0
    private(set) var smoothed: Double?
    private(set) var inRep = false
    private var lastTime: TimeInterval?
    private var startT = 0.0
    private var peakP = 0.0
    private var peakT = 0.0

    init(config: CameraRepConfig) { self.config = config }

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
        if t - startT > 15 { inRep = false; return nil }
        guard p < 0.25 else { return nil }

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
