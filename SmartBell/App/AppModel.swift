//
//  AppModel.swift
//  SmartBell — App
//
//  The app's central controller (one instance, owned by SmartBellApp). It:
//    • owns the data sources (BLEManager, DemoSensor, PoseCamera) and services
//      (Recorder, WorkoutStore, Coach, CameraLab)
//    • routes every sensor sample to whichever mode is active:
//        calibrating → Calibrator,  teaching → ExerciseTeacher,
//        otherwise   → MotionEngine (curls) and/or a profile engine (taught exercise)
//    • forwards rep events to the active WorkoutController
//    • publishes a 30 Hz LiveState snapshot for the UI
//    • saves the calibration and taught profiles in UserDefaults
//    • replays recorded CSVs through a fresh engine
//

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
    var profileProgress: Double? = nil   // taught exercise in use: % of the learned range
}

/// SmartBell readiness for one exercise.
enum SensorStatus: Equatable { case ready, needsCalibration, needsTeaching, noData }

/// Progress of "Teach SmartBell", shown by TeachView. nil in AppModel = not teaching.
enum TeachStep: Equatable {
    case hold(progress: Double)
    case reps(seconds: Double, level: Double, canFinish: Bool)
    case done(MotionProfile)
    case failed(String)
}

/// Progress of the 15 s calibration, shown by CalibrationView. nil = not calibrating.
enum CalibrationStep: Equatable {
    case hang(progress: Double)
    case curls(count: Int, angle: Double)
    case done
    case failed(String)
}

/// What replay(_:) found in a recorded CSV (shown on the Device tab).
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
    /// Where samples are currently coming from.
    enum Source { case none, sensor, demo }

    let ble = BLEManager()
    let demo = DemoSensor()
    let recorder = Recorder()
    let store = WorkoutStore()
    let coach = Coach()
    let camera = PoseCamera()
    let lab = CameraLab()

    @Published private(set) var source = Source.none
    @Published private(set) var calibration: Calibration?          // nil until the user calibrates
    @Published private(set) var live = LiveState()
    @Published private(set) var calibrationStep: CalibrationStep?
    @Published private(set) var lastRep: RepResult?                // most recent analysed curl
    @Published private(set) var workout: WorkoutController?        // non-nil while a workout is open
    @Published private(set) var profiles: [String: MotionProfile] = [:]  // taught exercises, by exercise id
    @Published private(set) var teachStep: TeachStep?
    @Published private(set) var teachingExercise: Exercise?

    private var engine: MotionEngine?            // curl engine; always running once calibrated
    private var profileEngine: MotionEngine?     // runs the taught exercise in the current workout
    private var teacher: ExerciseTeacher?
    private static let profilesKey = "exerciseProfiles.v1"
    private var calibrator: Calibrator?          // non-nil while calibrating
    private var partialCalibration: Calibration? // result of calibration step 1 (hang)
    private var calibrationStart = Date()        // for the 90 s timeout in step 2
    private var snapshotTimer: Timer?            // fires snapshot() at 30 Hz
    private var samplesSinceSnapshot = 0         // for the measured sample rate
    private var lastSnapshot = Date()
    private var lastSampleDate: Date?            // to detect "no data"
    private var history: [Double] = []           // recent β values for the live chart (180 = 6 s at 30 Hz)
    private var cancellables: Set<AnyCancellable> = []
    private static let calibrationKey = "calibration.v2"

    init() {
        // Restore the saved calibration and taught profiles from the last launch.
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let cal = try? JSONDecoder().decode(Calibration.self, from: data) {
            calibration = cal
            engine = MotionEngine(calibration: cal)
        }
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let p = try? JSONDecoder().decode([String: MotionProfile].self, from: data) {
            profiles = p
        }
        // Wire every data source into the pipeline.
        ble.onSample = { [weak self] s in self?.handle(s, from: .sensor) }
        demo.onSample = { [weak self] s in self?.handle(s, from: .demo) }
        camera.onFrame = { [weak self] f in MainActor.assumeIsolated { self?.handlePose(f) } }
        // Re-publish child objects so views observing AppModel update.
        ble.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot() }
        }
    }

    var isDemo: Bool { demo.isRunning }
    /// True if a sample arrived in the last second (from either source).
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

    /// Every sample (100 Hz) from the ESP32 or the demo comes through here.
    /// Calibration and teaching each take the stream exclusively; otherwise the curl
    /// engine always runs and the profile engine runs when a taught exercise is active.
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
        if teacher != nil {
            handleTeaching(s)
            return
        }
        // Only report curl reps to the workout if the current exercise is a curl
        // (the curl engine keeps running for the live display either way).
        let current = workout?.exercise
        let curlInUse = current?.sensorBuiltIn ?? false
        if engine != nil {
            let events = engine!.push(s)  // mutate in place
            for e in events {
                switch e {
                case .counted:
                    if curlInUse { workout?.sensorCounted() }
                case .result(let r):
                    lastRep = r
                    if curlInUse { workout?.sensorResult(r) }
                }
            }
        }
        // taught exercise: its own engine with the learned profile
        if let ex = current, !ex.sensorBuiltIn, let profile = profiles[ex.id] {
            // (Re)create the engine when the exercise changes or its profile is re-taught.
            if profileEngine?.profile != profile {
                profileEngine = MotionEngine(calibration: calibration ?? Calibration(), profile: profile)
            }
            let events = profileEngine!.push(s)
            for e in events {
                switch e {
                case .counted: workout?.sensorCounted()
                case .result(let r): workout?.sensorResult(r)
                }
            }
        } else if profileEngine != nil {
            profileEngine = nil
        }
    }

    /// SmartBell readiness for an exercise right now.
    func sensorStatus(for ex: Exercise) -> SensorStatus {
        guard hasData else { return .noData }
        if ex.sensorBuiltIn { return calibration != nil ? .ready : .needsCalibration }
        return profiles[ex.id] != nil ? .ready : .needsTeaching
    }

    /// Every camera frame (main thread).
    private func handlePose(_ f: PoseFrame?) {
        if lab.isActive {
            let sensorAngle: Double? = (calibration != nil && hasData && calibrator == nil) ? engine?.beta : nil
            lab.process(f, sensor: sensorAngle, coach: coach)
        }
        workout?.cameraFrame(f)
    }

    /// 30 Hz: copy engine state into `live` for SwiftUI. Publishing at 100 Hz would
    /// re-render the views far more often than the screen can show.
    private func snapshot() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSnapshot)
        var l = live
        if elapsed > 0 {
            let rate = Double(samplesSinceSnapshot) / elapsed
            l.sampleRate = l.sampleRate * 0.8 + rate * 0.2   // smoothed samples/s (should read ~100)
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
        l.profileProgress = profileEngine?.beta
        l.angleHistory = history
        // Nothing streaming: publish once so the UI shows "no data", then stay quiet.
        if l.secondsSinceSample > 1.5 && live.secondsSinceSample > 1.5 { return }
        live = l
    }

    // MARK: - calibration

    /// Begin the two-step calibration. While `calibrator` is set, handle() sends every
    /// sample to handleCalibration() instead of the engines.
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

    /// Drive the Calibrator and update `calibrationStep` for the UI. Steps:
    /// hang (until 2 s still) → curls (until 3 curls and arm back down, or 90 s timeout) → done/failed.
    /// The step is only re-published when it changes visibly, to avoid 100 Hz re-renders.
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

    /// Learn hinge/range from the recorded curls, then save the calibration and
    /// rebuild the curl engine with it.
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

    // MARK: - workouts


    /// Open a workout. `sensorStatus` is passed as a closure so the controller can ask
    /// "is SmartBell ready for this exercise?" at each exercise change. The session is
    /// saved to the store when the workout finishes (if any set was logged).
    func startWorkout(_ template: WorkoutTemplate, unit: WeightUnit) {
        guard !template.items.isEmpty else { return }
        let w = WorkoutController(template: template, unit: unit, isDemo: isDemo, coach: coach, store: store,
                                  sensorStatus: { [weak self] ex in self?.sensorStatus(for: ex) ?? .noData })
        w.onFinished = { [weak self, weak w] in
            guard let self, let w else { return }
            if !w.session.allSets.isEmpty { self.store.add(w.session) }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        workout = w
        lastRep = nil
        w.begin()
        UIApplication.shared.isIdleTimerDisabled = true // keep running with the phone in a pocket
    }

    /// Quick start: one exercise, three sets.
    func quickStart(_ exercise: Exercise, unit: WeightUnit) {
        // Weight: the store's progression suggestion, else a light default (15 lb / 7 kg).
        let w = store.suggestedWeight(exercise.id, unit: unit) ?? (exercise.usesWeight ? (unit == .lb ? 15 : 7) : 0)
        let t = WorkoutTemplate(name: exercise.name, items: [
            PlannedExercise(exerciseId: exercise.id, sets: 3, reps: 10, weight: w, restSeconds: 90)])
        startWorkout(t, unit: unit)
    }

    /// Discard without saving.
    func cancelWorkout() {
        workout?.cancel()
        workout = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Close the summary after a finished workout.
    func closeWorkout() { workout = nil }

    // MARK: - teaching SmartBell an exercise

    /// Begin teaching `ex`. Uses the curl calibration (forearm axis, bias, g) as the base;
    /// while `teacher` is set, handle() routes samples to handleTeaching().
    func startTeaching(_ ex: Exercise) {
        teacher = ExerciseTeacher(exerciseId: ex.id, base: calibration ?? Calibration())
        teachingExercise = ex
        teachStep = .hold(progress: 0)
        if demo.isRunning { demo.restart(script: .calibration) } // demo: still, then 3 slow reps
    }

    /// Finish now (allowed after a few seconds of movement) instead of waiting for the pause.
    func finishTeachingNow() { finishTeaching() }

    func cancelTeaching() {
        teacher = nil
        teachStep = nil
        teachingExercise = nil
        if demo.isRunning { demo.restart(script: .workout) }
    }

    /// Close the teaching sheet after success or failure.
    func dismissTeaching() {
        if teacher != nil { cancelTeaching() }
        teachStep = nil
        teachingExercise = nil
    }

    func forgetProfile(_ exerciseId: String) {
        profiles[exerciseId] = nil
        saveProfiles()
    }

    private func handleTeaching(_ s: SensorSample) {
        guard teacher != nil else { return }
        teacher!.push(s)
        let t = teacher!
        // Round the displayed values so teachStep only changes (and the UI only redraws)
        // a few times per second.
        let step: TeachStep
        switch t.phase {
        case .hold: step = .hold(progress: (t.holdProgress * 20).rounded() / 20)
        case .reps: step = .reps(seconds: (t.moveSeconds * 2).rounded() / 2, level: (t.motionLevel * 10).rounded() / 10,
                                 canFinish: t.canFinish)
        }
        if step != teachStep { teachStep = step }
        if t.readyToFinish { finishTeaching() }
    }

    private func finishTeaching() {
        guard let t = teacher else { return }
        teacher = nil
        if demo.isRunning { demo.restart(script: .workout) }
        guard let p = t.finish() else {
            teachStep = .failed("Couldn't find a clear repeating movement. Make sure the strap is snug, start from a still position, and do 3 full reps at a steady pace.")
            return
        }
        profiles[p.exerciseId] = p
        saveProfiles()
        teachStep = .done(p)
        // Taught mid-workout for the current exercise: switch that exercise to sensor counting.
        if let w = workout, w.exercise?.id == p.exerciseId { w.setSource(.sensor) }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.profilesKey) }
    }

    // MARK: - recording / replay

    func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else { recorder.start(calibration: calibration) }
    }

    /// Runs a recorded CSV through a fresh engine, exactly as if it were live.
    func replay(_ url: URL) -> ReplayReport? {
        guard let loaded = Recorder.load(url), !loaded.samples.isEmpty else { return nil }
        let recordedCal = loaded.calibration, samples = loaded.samples
        // Prefer the calibration saved inside the recording so the replay matches what the app saw.
        guard let cal = recordedCal ?? calibration else { return nil }
        var e = MotionEngine(calibration: cal)
        var reps: [RepResult] = []
        var angles: [Double] = []
        var t = 0.0, nextAngle = 0.0
        for s in samples {
            for ev in e.push(s) { if case .result(let r) = ev { reps.append(r) } }
            t += s.dt
            if t >= nextAngle { angles.append(e.beta); nextAngle += 0.05 }  // keep 20 Hz for the plot
        }
        return ReplayReport(fileName: url.lastPathComponent, duration: t, samples: samples.count,
                            usedRecordedCalibration: recordedCal != nil, reps: reps, angles: angles)
    }
}
