import Foundation
import Combine
import UIKit

/// Snapshot of the motion state for the UI, refreshed ~30 times a second
/// (the sensor itself runs at 100 Hz; SwiftUI doesn't need every sample).
struct LiveState {
    var beta = 0.0                 // forearm angle, deg
    var hand = Vec3(0, 0, -1)      // forearm direction in the rep frame
    var twistDeg = 0.0
    var isInRep = false
    var currentPath: [Vec3] = []   // hand path of the rep in progress
    var linearAcceleration = 0.0
    var isStill = false
    var angleHistory: [Double] = []  // last ~6 s, for the chart
    var sampleRate = 0.0
    var secondsSinceSample = Double.infinity
    var gyroBias = Vec3.zero
}

enum CalibrationStep: Equatable {
    case hang(progress: Double)
    case curls(count: Int, angle: Double)
    case done
    case failed(String)
}

struct ActiveSet {
    var exercise: Exercise
    var weight: Double
    var unit: WeightUnit
    var targetReps: Int
    var start = Date()
    var reps: [RepResult] = []
    var count = 0
    var isDemo: Bool
}

struct ReplayReport: Identifiable {
    let id = UUID()
    var fileName: String
    var duration: Double
    var samples: Int
    var usedRecordedCalibration: Bool
    var reps: [RepResult]
    var angles: [Double]            // decimated forearm angle, 20 Hz
}

@MainActor
final class AppModel: ObservableObject {
    enum Source { case none, sensor, demo }

    let ble = BLEManager()
    let demo = DemoSensor()
    let recorder = Recorder()
    let store = WorkoutStore()
    let coach = Coach()

    @Published private(set) var source = Source.none
    @Published private(set) var calibration: Calibration?
    @Published private(set) var live = LiveState()
    @Published private(set) var calibrationStep: CalibrationStep?
    @Published private(set) var activeSet: ActiveSet?
    @Published private(set) var lastRep: RepResult?
    @Published private(set) var lastFinishedSet: WorkoutSet?

    private var engine: MotionEngine?
    private var calibrator: Calibrator?
    private var partialCalibration: Calibration?
    private var calibrationStart = Date()
    private var snapshotTimer: Timer?
    private var samplesSinceSnapshot = 0
    private var lastSnapshot = Date()
    private var lastSampleDate: Date?
    private var history: [Double] = []
    private var cancellables: Set<AnyCancellable> = []
    private static let calibrationKey = "calibration.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let cal = try? JSONDecoder().decode(Calibration.self, from: data) {
            calibration = cal
            engine = MotionEngine(calibration: cal)
        }
        ble.onSample = { [weak self] s in self?.handle(s, from: .sensor) }
        demo.onSample = { [weak self] s in self?.handle(s, from: .demo) }
        // Re-publish child objects so views observing AppModel update.
        ble.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot() }
        }
    }

    var isDemo: Bool { demo.isRunning }
    var hasData: Bool { live.secondsSinceSample < 1.0 }

    // MARK: - sources

    func startDemo() {
        ble.disconnect()
        demo.start(script: calibrationStep != nil ? .calibration : .workout)
        source = .demo
    }

    func stopDemo() {
        demo.stop()
        if source == .demo { source = .none }
    }

    // MARK: - sample pipeline

    private func handle(_ s: SensorSample, from origin: Source) {
        if origin == .sensor && demo.isRunning { return } // demo has priority while it's on
        if source != origin { source = origin }
        lastSampleDate = Date()
        samplesSinceSnapshot += 1
        recorder.append(s)

        if calibrator != nil {
            handleCalibration(s)
            return
        }
        guard engine != nil else { return }
        let events = engine!.push(s)  // mutate in place
        guard activeSet != nil else {
            for e in events { if case .result(let r) = e { lastRep = r } }
            return
        }
        for e in events {
            switch e {
            case .counted:
                activeSet!.count += 1
                coach.repCounted(activeSet!.count)
            case .result(let r):
                activeSet!.reps.append(r)
                lastRep = r
                coach.repAnalysed(r)
            }
        }
    }

    private func snapshot() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSnapshot)
        var l = live
        if elapsed > 0 {
            let rate = Double(samplesSinceSnapshot) / elapsed
            l.sampleRate = l.sampleRate * 0.8 + rate * 0.2
        }
        samplesSinceSnapshot = 0
        lastSnapshot = now
        l.secondsSinceSample = lastSampleDate.map { now.timeIntervalSince($0) } ?? .infinity

        if let e = engine, calibrator == nil {
            l.beta = e.beta
            l.hand = e.hand
            l.twistDeg = e.twistDeg
            l.isInRep = e.isInRep
            l.currentPath = e.currentRepPath()
            l.linearAcceleration = e.linearAcceleration
            l.isStill = e.isStill
            l.gyroBias = e.gyroBias
        } else if case .curls(_, let angle)? = calibrationStep {
            l.beta = angle
        }
        if l.secondsSinceSample < 1 {
            history.append(l.beta)
            if history.count > 180 { history.removeFirst(history.count - 180) }
        }
        l.angleHistory = history
        // Nothing streaming: publish once so the UI shows "no data", then stay quiet.
        if l.secondsSinceSample > 1.5 && live.secondsSinceSample > 1.5 { return }
        live = l
    }

    // MARK: - calibration

    func startCalibration() {
        calibrator = Calibrator()
        partialCalibration = nil
        calibrationStart = Date()
        calibrationStep = .hang(progress: 0)
        if demo.isRunning { demo.restart(script: .calibration) }
    }

    func cancelCalibration() {
        calibrator = nil
        calibrationStep = nil
        if demo.isRunning { demo.restart(script: .workout) }
    }

    /// Finish step 2 early (allowed once 2 curls were seen).
    func finishCalibrationNow() {
        guard let c = calibrator, let base = partialCalibration else { return }
        completeCalibration(c, base)
    }

    private func handleCalibration(_ s: SensorSample) {
        guard calibrator != nil else { return }
        switch calibrationStep {
        case .hang?:
            let p = calibrator!.pushHang(s)
            if p >= 1 {
                partialCalibration = calibrator!.finishHang()
                calibrationStep = .curls(count: 0, angle: 0)
                calibrationStart = Date()
            } else if case .hang(let old)? = calibrationStep, abs(old - p) > 0.02 || (p == 0 && old != 0) {
                calibrationStep = .hang(progress: p)
            }
        case .curls?:
            let angle = calibrator!.pushCurl(s)
            let n = calibrator!.probeReps
            if case .curls(let oldN, let oldAngle)? = calibrationStep, oldN == n, abs(oldAngle - angle) < 1 {
                // unchanged enough; don't re-render 100x a second
            } else {
                calibrationStep = .curls(count: n, angle: angle)
            }
            let idle = calibrator!.probe.map { !$0.isInRep } ?? true
            if n >= Calibrator.curlsNeeded && idle, let base = partialCalibration {
                completeCalibration(calibrator!, base)
            } else if Date().timeIntervalSince(calibrationStart) > 90 {
                calibrator = nil
                calibrationStep = .failed("Didn't see three full curls. Make sure the strap is snug and curl all the way up and down.")
            }
        default:
            break
        }
    }

    private func completeCalibration(_ c: Calibrator, _ base: Calibration) {
        calibrator = nil
        guard let cal = c.finishCurls(base) else {
            calibrationStep = .failed("Couldn't find at least two clear curls. Try again with slow, full curls.")
            return
        }
        calibration = cal
        engine = MotionEngine(calibration: cal)
        if let data = try? JSONEncoder().encode(cal) { UserDefaults.standard.set(data, forKey: Self.calibrationKey) }
        calibrationStep = .done
        if demo.isRunning { demo.restart(script: .workout) }
    }

    func dismissCalibration() {
        if calibrator != nil { cancelCalibration() }
        calibrationStep = nil
    }

    // MARK: - sets

    func startSet(exercise: Exercise, weight: Double, unit: WeightUnit, targetReps: Int) {
        guard let cal = calibration else { return }
        engine = MotionEngine(calibration: cal) // fresh detector, nothing carried over
        activeSet = ActiveSet(exercise: exercise, weight: weight, unit: unit, targetReps: targetReps, isDemo: isDemo)
        lastRep = nil
        coach.beginSet()
        UIApplication.shared.isIdleTimerDisabled = true // keep running with the phone in a pocket
    }

    func endSet() {
        guard let s = activeSet else { return }
        activeSet = nil
        coach.endSet()
        UIApplication.shared.isIdleTimerDisabled = false
        let set = WorkoutSet(date: s.start, exercise: s.exercise, weight: s.weight, unit: s.unit,
                             targetReps: s.targetReps, reps: s.reps,
                             duration: Date().timeIntervalSince(s.start), isDemo: s.isDemo)
        if !set.reps.isEmpty { store.add(set) }
        lastFinishedSet = set
    }

    func discardSet() {
        activeSet = nil
        coach.endSet()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clearFinishedSet() { lastFinishedSet = nil }

    // MARK: - recording / replay

    func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else { recorder.start(calibration: calibration) }
    }

    /// Runs a recorded CSV through a fresh engine, exactly as if it were live.
    func replay(_ url: URL) -> ReplayReport? {
        guard let loaded = Recorder.load(url), !loaded.samples.isEmpty else { return nil }
        let recordedCal = loaded.calibration, samples = loaded.samples
        guard let cal = recordedCal ?? calibration else { return nil }
        var e = MotionEngine(calibration: cal)
        var reps: [RepResult] = []
        var angles: [Double] = []
        var t = 0.0, nextAngle = 0.0
        for s in samples {
            for ev in e.push(s) { if case .result(let r) = ev { reps.append(r) } }
            t += s.dt
            if t >= nextAngle { angles.append(e.beta); nextAngle += 0.05 }
        }
        return ReplayReport(fileName: url.lastPathComponent, duration: t, samples: samples.count,
                            usedRecordedCalibration: recordedCal != nil, reps: reps, angles: angles)
    }
}
