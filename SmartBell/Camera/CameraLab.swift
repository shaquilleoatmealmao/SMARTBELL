//
//  CameraLab.swift
//  SmartBell — Camera
//
//  View model for the Camera tab (CameraView). AppModel calls process() for every
//  camera frame while the tab is visible. Two jobs:
//    1. Camera-only rep counting for the selected exercise (AngleRepCounter).
//    2. Accuracy check: pairs the camera's forearm angle with SmartBell's β frame by
//       frame and accumulates mean / RMS / max difference; can save the pairs as CSV.
//

import Foundation

/// State behind the Camera tab: live joint angles, camera rep counting, and a side-by-side
/// comparison of the camera's forearm angle with the SmartBell's (to measure sensor accuracy).
@MainActor
final class CameraLab: ObservableObject {
    /// One matched measurement: time (s from first pair), sensor β and camera angle (deg).
    struct Pair { var t: Double; var sensor: Double; var camera: Double }

    // Changing the exercise builds a fresh counter with that exercise's camera config
    // (nil if the exercise has no camera support).
    @Published var exercise: Exercise = ExerciseLibrary.exercise("bicep-curl")! {
        didSet { counter = exercise.camera.map { AngleRepCounter(config: $0) } }
    }
    @Published private(set) var counter: AngleRepCounter? = nil
    @Published private(set) var lastRep: CameraRep? = nil
    @Published private(set) var trackedAngle: Double? = nil
    @Published private(set) var forearmAngle: Double? = nil
    @Published private(set) var elbowAngle: Double? = nil
    @Published private(set) var sensorAngle: Double? = nil

    // comparison
    @Published private(set) var series: [Pair] = []          // last ~8 s for the chart
    @Published private(set) var isMeasuring = false
    @Published private(set) var stats = Stats()
    /// True while the Camera tab is on screen (so it doesn't count or speak during a workout).
    var isActive = false
    private var log: [Pair] = []     // every pair since startMeasuring(), saved by stopMeasuring()
    private var t0: Double?          // time of the first pair (chart x-axis origin)

    /// Running statistics of (sensor − camera), so no history is needed to compute them.
    struct Stats {
        var n = 0
        var sum = 0.0, sumSq = 0.0, maxAbs = 0.0
        var mean: Double { n > 0 ? sum / Double(n) : 0 }
        var rmse: Double { n > 0 ? (sumSq / Double(n)).squareRoot() : 0 }
    }

    init() { counter = exercise.camera.map { AngleRepCounter(config: $0) } }

    func resetCount() {
        counter?.reset()
        lastRep = nil
    }

    /// Called for every camera frame. `sensor` is the SmartBell forearm angle if it's streaming.
    func process(_ frame: PoseFrame?, sensor: Double?, coach: Coach) {
        forearmAngle = frame?.angle(.forearmFromVertical)
        elbowAngle = frame?.angle(.elbowFlexion)
        sensorAngle = sensor
        if let cfg = exercise.camera {
            trackedAngle = frame?.angle(cfg.metric)
            if let f = frame, counter != nil {
                switch counter!.push(angle: trackedAngle, time: f.time) {
                case .counted(let n, let rep)?:
                    lastRep = rep
                    coach.repCounted(n)
                case .partial(let rep)?:
                    lastRep = rep
                case nil:
                    break
                }
            }
        }

        // Comparison needs both a sensor angle and a visible forearm in this frame.
        guard let f = frame, let s = sensor, let c = forearmAngle else { return }
        if t0 == nil { t0 = f.time }
        let p = Pair(t: f.time - (t0 ?? f.time), sensor: s, camera: c)
        series.append(p)
        if let first = series.first, p.t - first.t > 8 { series.removeFirst(min(series.count, 10)) }
        if isMeasuring {
            log.append(p)
            let d = s - c
            stats.n += 1
            stats.sum += d
            stats.sumSq += d * d
            stats.maxAbs = max(stats.maxAbs, abs(d))
        }
    }

    func startMeasuring() {
        log.removeAll()
        stats = Stats()
        isMeasuring = true
    }

    /// Stops and writes the comparison to Recordings as CSV. Returns the file URL.
    func stopMeasuring() -> URL? {
        isMeasuring = false
        guard !log.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = Recorder.folder.appendingPathComponent("compare-\(f.string(from: Date())).csv")
        var text = "# SmartBell vs camera forearm angle (deg). n=\(stats.n) mean diff=\(String(format: "%.2f", stats.mean)) rmse=\(String(format: "%.2f", stats.rmse))\n"
        text += "t_s,sensor_deg,camera_deg\n"
        text += log.map { String(format: "%.3f,%.2f,%.2f", $0.t, $0.sensor, $0.camera) }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
