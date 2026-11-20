import Foundation

enum RepEvent {
    case counted(Int)        // fired the moment a rep is counted (on the way down)
    case result(RepResult)   // fired ~0.3 s later once the bottom is found and the rep is analysed
}

/// Hysteresis state machine on the forearm angle.
///
///   idle   -> up      angle rises past startDeg (30% of calibrated range)
///   up     -> settle  angle falls back below returnDeg (22%)        -> rep ends at the bottom
///   up     -> up      angle fell >= 45% of range then rose 12 deg   -> rep ended at a high bottom
///                     (didn't lower all the way); the next rep starts there
///   settle -> idle    bottom found (angle stops falling)             -> rep analysed
/// A rep counts if its peak passed topThresholdDeg (70% of calibrated range).
/// Because the angle is gravity-referenced, the same thresholds work at any speed.
struct RepDetector {
    enum State { case idle, up, settle }

    static let band = 5.0  // deg: a phase starts/ends when the angle is within this of its extreme

    let calibration: Calibration
    private(set) var state = State.idle
    private(set) var frames: [MotionFrame] = []
    private(set) var count = 0
    private(set) var attempts = 0
    private(set) var startT = 0.0
    private(set) var peak = -1e9
    private(set) var justStarted = false
    private var runMin = 1e9
    private var nearMinT = 0.0
    private var peakT = 0.0
    private var valley = 1e9
    private var valleyT = 0.0
    private var counted = false

    init(calibration: Calibration) { self.calibration = calibration }

    mutating func push(_ f: MotionFrame) -> [RepEvent] {
        let cal = calibration
        frames.append(f)
        if frames.count > 2000 { frames.removeFirst(500) }  // keep ~15-20 s
        var events: [RepEvent] = []
        justStarted = false

        switch state {
        case .idle:
            if f.beta < runMin { runMin = f.beta }
            if f.beta <= runMin + 3.0 { nearMinT = f.t }
            runMin += 0.02  // let the bottom reference float up if the arm is held higher
            if f.beta > cal.startDeg { begin(startT: nearMinT, f) }

        case .up:
            if f.beta > peak {
                peak = f.beta; peakT = f.t
                valley = 1e9
            }
            if peak - f.beta > 0.45 * cal.rom && f.beta < valley {
                valley = f.beta; valleyT = f.t
            }
            if f.beta < cal.returnDeg {
                counted = peak >= cal.topThresholdDeg
                attempts += 1
                if counted { count += 1; events.append(.counted(count)) }
                state = .settle
                valley = f.beta; valleyT = f.t
            } else if valley < 1e8 && f.beta > valley + 12.0 {
                // Turned around before reaching the bottom: close this rep at the valley.
                counted = peak >= cal.topThresholdDeg
                attempts += 1
                if counted {
                    count += 1
                    events.append(.counted(count))
                    events.append(.result(analyse()))
                }
                begin(startT: valleyT, f)
            } else if f.t - startT > 12.0 {
                toIdle(f)
            }

        case .settle:
            if f.beta < valley { valley = f.beta; valleyT = f.t }
            if f.beta > valley + 4.0 || f.t - valleyT > 0.35 {
                if counted || peak >= cal.startDeg + 8.0 { events.append(.result(analyse())) }
                toIdle(f)
                runMin = valley
                nearMinT = valleyT
            }
        }
        return events
    }

    private mutating func begin(startT: Double, _ f: MotionFrame) {
        state = .up
        self.startT = startT
        peak = f.beta; peakT = f.t
        valley = 1e9
        counted = false
        justStarted = true
    }

    private mutating func toIdle(_ f: MotionFrame) {
        state = .idle
        runMin = f.beta
        nearMinT = f.t
    }

    private func analyse() -> RepResult {
        let cal = calibration
        var seg = frames.filter { $0.t >= startT && $0.t <= valleyT }
        if seg.count < 3 { seg = Array(frames.suffix(3)) }
        let band = RepDetector.band
        let b0 = seg[0].beta, b1 = seg[seg.count - 1].beta
        var ipk = 0
        for i in seg.indices where seg[i].beta > seg[ipk].beta { ipk = i }

        // Phase timing between "within band of the bottom" and "within band of the top".
        var tUp0 = seg[0].t
        for i in stride(from: ipk, through: 0, by: -1) where seg[i].beta <= b0 + band { tUp0 = seg[i].t; break }
        var tUp1 = seg[ipk].t
        for fr in seg where fr.beta >= peak - band { tUp1 = fr.t; break }
        var tDn0 = seg[ipk].t
        for i in stride(from: seg.count - 1, through: 0, by: -1) where seg[i].beta >= peak - band { tDn0 = seg[i].t; break }
        var tDn1 = seg[seg.count - 1].t
        for i in ipk..<seg.count where seg[i].beta <= b1 + band { tDn1 = seg[i].t; break }
        let concentric = max(tUp1 - tUp0, 0)
        let eccentric = max(tDn1 - tDn0, 0)
        let bottom = b1

        // Form metrics only over the moving part (bottom band -> bottom band).
        var act = seg.filter { $0.t >= tUp0 && $0.t <= tDn1 }
        if act.isEmpty { act = seg }
        let twists = act.map(\.twistDeg)
        let twist = (twists.max() ?? 0) - (twists.min() ?? 0)
        let sway = planeDeviationDegrees(act.map(\.hand))
        let swing = act.map(\.linAcc).max() ?? 0
        let peakSpeed = act.map { abs($0.wCurl) }.max() ?? 0
        let curve = resample(ts: seg.map(\.t), ys: seg.map(\.beta), n: 40)
        var pathRms = 0.0
        if cal.template.count == curve.count {
            pathRms = rms(zip(curve, cal.template).map { $0 - $1 })
        }

        var issues: [FormIssue] = []
        if swing > 4.0 { issues.append(.swing) }
        if peak > cal.topDeg + 18.0 { issues.append(.elbow) }
        if !counted { issues.append(.partial) } else if peak < cal.topDeg - 20.0 { issues.append(.shortTop) }
        if bottom > cal.bottomDeg + 20.0 { issues.append(.shortBottom) }
        if eccentric < 0.7 { issues.append(.fastDown) }
        if concentric < 0.35 { issues.append(.fastUp) }
        if twist > max(30.0, 2.0 * cal.twistRef + 10.0) { issues.append(.twist) }
        if sway > max(15.0, 2.0 * cal.swayRef + 8.0) { issues.append(.sway) }
        issues.sort { $0.priority < $1.priority }
        let score = max(0, 100 - issues.reduce(0) { $0 + $1.penalty })

        return RepResult(index: attempts, counted: counted, startT: seg[0].t, peakT: peakT,
                         endT: seg[seg.count - 1].t, bottomDeg: bottom, topDeg: peak,
                         concentricSeconds: concentric, eccentricSeconds: eccentric,
                         peakSpeedDps: peakSpeed, twistRange: twist, swayRange: sway, swing: swing,
                         pathRmsDeg: pathRms, score: score, issues: issues, curve: curve)
    }
}

/// A curl moves the hand in a vertical plane. Fit that plane (main horizontal direction
/// of the hand path) and return how far, peak to peak, the forearm left it, in degrees.
func planeDeviationDegrees(_ hands: [Vec3]) -> Double {
    guard !hands.isEmpty else { return 0 }
    var sxx = 0.0, syy = 0.0, sxy = 0.0
    for h in hands { sxx += h.x * h.x; syy += h.y * h.y; sxy += h.x * h.y }
    let ang = 0.5 * atan2(2.0 * sxy, sxx - syy)
    let nx = -sin(ang), ny = cos(ang)
    let off = hands.map { asin(max(-1.0, min(1.0, $0.x * nx + $0.y * ny))) * degPerRad }
    return (off.max() ?? 0) - (off.min() ?? 0)
}

func rms(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    return sqrt(xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count))
}

func resample(ts: [Double], ys: [Double], n: Int) -> [Double] {
    guard ts.count >= 2 else { return Array(repeating: ys.first ?? 0, count: n) }
    let t0 = ts[0], t1 = ts[ts.count - 1]
    var out: [Double] = []
    out.reserveCapacity(n)
    var j = 0
    for i in 0..<n {
        let t = t0 + (t1 - t0) * Double(i) / Double(n - 1)
        while j < ts.count - 2 && ts[j + 1] < t { j += 1 }
        let span = ts[j + 1] - ts[j]
        let f = span <= 0 ? 0.0 : min(max((t - ts[j]) / span, 0.0), 1.0)
        out.append(ys[j] + (ys[j + 1] - ys[j]) * f)
    }
    return out
}
