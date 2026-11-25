//
//  WorkoutController.swift
//  SmartBell — Fitness
//
//  State machine for one workout in progress (created by AppModel.startWorkout,
//  displayed by WorkoutPlayerView). Receives reps from three inputs:
//    sensorCounted()/sensorResult()  ← AppModel's MotionEngine (SmartBell)
//    cameraFrame()                   ← PoseCamera, counted here with AngleRepCounter
//    adjustReps()/startSet()         ← buttons (manual)
//  and builds the WorkoutSession that is saved when the workout finishes.
//

import Foundation

/// Runs a guided workout, hands-free:
///
///   ready ──first rep detected (or Start)──▶ active ──Done──▶ resting
///     ▲                                                          │
///     └────────── rest timer ends (or Skip) ◀────────────────────┘
///   after the last set of the last exercise ──▶ finished
///
/// With the SmartBell or the camera the first rep starts the set. A set only ends when you tap
/// Done, however long you take between reps. The rest timer then runs and speaks, and the next
/// set starts when you do.
/// Rest is measured from the end of one set to the first rep of the next.
@MainActor
final class WorkoutController: ObservableObject {
    enum Phase: Equatable { case ready, active, resting, finished }

    @Published private(set) var session: WorkoutSession      // everything logged so far
    @Published private(set) var phase = Phase.ready
    @Published private(set) var exerciseIndex = 0             // which item of the template we're on
    @Published private(set) var source: TrackingMode = .manual  // how the current set is counted
    @Published private(set) var reps = 0                      // reps in the current set
    @Published private(set) var partials = 0
    @Published private(set) var lastSensorRep: RepResult? = nil
    @Published private(set) var lastCameraRep: CameraRep? = nil
    @Published private(set) var cameraProgress = 0.0          // 0...1, for the camera progress bar
    @Published private(set) var restRemaining: TimeInterval = 0
    @Published private(set) var restTotal: TimeInterval = 0
    @Published private(set) var lastFinished: (exercise: Int, index: Int)? = nil  // set just completed (editable on the rest screen)
    @Published var weight: Double = 0                         // user can edit before/while lifting
    @Published var targetReps: Int = 10

    let unit: WeightUnit
    let previous: [String: [SetLog]]       // exerciseId -> sets from the most recent session
    private let coach: Coach
    private let sensorStatus: @MainActor (Exercise) -> SensorStatus
    /// Called once when the workout finishes normally (not on cancel).
    var onFinished: (@MainActor () -> Void)?
    private let suggestedWeights: [String: Double]   // exerciseId -> Progression's suggestion
    private var setStart: Date?                      // nil when no set is active
    private var lastSetEnd: Date?                    // for rest timing
    private var sensorReps: [RepResult] = []         // per-rep detail for the current set
    private var cameraReps: [CameraRep] = []
    private var cameraCounter: AngleRepCounter?
    private var timer: Timer?                        // 4 Hz tick for the rest countdown
    private var restWarned = false                   // "10 seconds" already spoken
    private var restAnnounced = false                // rest-over already handled

    init(template: WorkoutTemplate, unit: WeightUnit, isDemo: Bool, coach: Coach, store: WorkoutStore,
         sensorStatus: @escaping @MainActor (Exercise) -> SensorStatus) {
        self.unit = unit
        self.coach = coach
        self.sensorStatus = sensorStatus
        // For each exercise: last session's sets (shown as "last time") and a suggested weight.
        var prev: [String: [SetLog]] = [:]
        var sugg: [String: Double] = [:]
        for item in template.items where prev[item.exerciseId] == nil {
            if let last = store.history(of: item.exerciseId).last { prev[item.exerciseId] = last.sets }
            if let w = store.suggestedWeight(item.exerciseId, unit: unit) { sugg[item.exerciseId] = w }
        }
        previous = prev
        suggestedWeights = sugg
        session = WorkoutSession(name: template.name, templateId: template.id, start: Date(), end: nil,
                                 exercises: template.items.map { ExerciseLog(exerciseId: $0.exerciseId, plan: $0) },
                                 isDemo: isDemo)
        prepareExercise()
    }

    // MARK: - current position

    // Index is clamped so these stay valid after the last exercise finishes.
    var currentLog: ExerciseLog { session.exercises[min(exerciseIndex, session.exercises.count - 1)] }
    var exercise: Exercise? { currentLog.exercise }
    var plan: PlannedExercise { currentLog.plan }
    var setNumber: Int { currentLog.sets.count + 1 }
    var totalSets: Int { max(plan.sets, currentLog.sets.count) }
    var isDone: Bool { phase == .finished }

    /// SmartBell readiness for the current exercise.
    var sensorState: SensorStatus { exercise.map { sensorStatus($0) } ?? .noData }

    var availableSources: [TrackingMode] {
        guard let ex = exercise else { return [.manual] }
        // SmartBell is offered whenever it's streaming; if this exercise still needs
        // calibrating or teaching, the workout screen offers to do that.
        return ex.tracking.filter { $0 != .sensor || sensorStatus(ex) != .noData }
    }

    // MARK: - lifecycle

    /// Start the workout: prepare audio/haptics, start the tick timer, announce the first set.
    func begin() {
        coach.beginSet()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        enterReady(announce: true)
    }

    /// Switch counting method (not allowed mid-set).
    func setSource(_ s: TrackingMode) {
        guard phase != .active else { return }
        source = s
        cameraCounter = exercise?.camera.map { AngleRepCounter(config: $0) }
    }

    /// Manual start (for manual tracking, or if you want to start the clock yourself).
    func startSet() {
        guard phase == .ready || phase == .resting else { return }
        phase = .active
        setStart = Date()
        reps = 0
        partials = 0
        sensorReps = []
        cameraReps = []
        lastSensorRep = nil
        lastCameraRep = nil
        if source == .manual { reps = targetReps }  // pre-fill; adjust with − / +
    }

    /// Manual end (Done button).
    func finishSet() {
        guard phase == .active, let start = setStart else { return }
        let now = Date()
        let rest = lastSetEnd.map { start.timeIntervalSince($0) }
        let log = SetLog(reps: reps, partials: partials, weight: weight, unit: unit, rpe: nil, start: start,
                         duration: now.timeIntervalSince(start), restBefore: rest, source: source,
                         sensorReps: sensorReps, cameraReps: cameraReps)
        session.exercises[exerciseIndex].sets.append(log)
        lastFinished = (exerciseIndex, session.exercises[exerciseIndex].sets.count - 1)
        lastSetEnd = now
        setStart = nil

        // Spoken summary; warn about fatigue if rep speed dropped 30%+ during the set.
        var line = "\(reps) reps."
        if let vl = log.velocityLoss, vl >= 0.3 {
            line += " Speed dropped \(Int(vl * 100)) percent, you're close to failure."
        }
        coach.guide(line)

        if currentLog.sets.count >= plan.sets {
            // exercise done
            if exerciseIndex + 1 < session.exercises.count {
                // Move to the next exercise, resting for the finished exercise's rest time.
                exerciseIndex += 1
                prepareExercise()
                enterRest(seconds: Double(session.exercises[exerciseIndex - 1].plan.restSeconds))
            } else {
                finish()
            }
        } else {
            enterRest(seconds: Double(plan.restSeconds))
        }
    }

    // MARK: - buttons on the workout screen

    /// − / + buttons during a set.
    func adjustReps(_ delta: Int) {
        guard phase == .active else { return }
        reps = max(0, reps + delta)
    }

    func skipRest() {
        guard phase == .resting else { return }
        enterReady(announce: true)
    }

    func extendRest(_ seconds: Double) {
        guard phase == .resting else { return }
        restTotal += seconds
        restWarned = false
    }

    func addSet() {
        session.exercises[exerciseIndex].plan.sets += 1
    }

    /// Move on; a set in progress is kept if it has any reps.
    func skipExercise() {
        if phase == .active { finishSetQuietly() }
        if exerciseIndex + 1 < session.exercises.count {
            exerciseIndex += 1
            prepareExercise()
            enterReady(announce: true)
        } else {
            finish()
        }
    }

    /// Edit the set that just finished (shown on the rest screen).
    func setRPE(_ rpe: Double?) {
        guard let lf = lastFinished else { return }
        session.exercises[lf.exercise].sets[lf.index].rpe = rpe
    }

    func correctLastSet(reps newReps: Int) {
        guard let lf = lastFinished else { return }
        session.exercises[lf.exercise].sets[lf.index].reps = max(0, newReps)
    }

    var lastFinishedSet: SetLog? {
        guard let lf = lastFinished, lf.exercise < session.exercises.count,
              lf.index < session.exercises[lf.exercise].sets.count else { return nil }
        return session.exercises[lf.exercise].sets[lf.index]
    }

    /// End normally: close any open set, stamp the end time and let AppModel save the session.
    func finish() {
        if phase == .active { finishSetQuietly() }
        guard phase != .finished else { return }
        phase = .finished
        session.end = Date()
        timer?.invalidate()
        timer = nil
        coach.guide("Workout complete. \(session.totalReps) reps in total.")
        coach.endSet()
        onFinished?()
    }

    /// Discard: stop everything without calling onFinished (nothing is saved).
    func cancel() {
        timer?.invalidate()
        timer = nil
        phase = .finished
        coach.endSet()
    }

    // MARK: - inputs

    /// SmartBell counted a rep.
    func sensorCounted() {
        guard source == .sensor else { return }
        repDetected()
    }

    /// SmartBell finished analysing a rep (arrives ~0.3 s after it was counted).
    func sensorResult(_ r: RepResult) {
        guard source == .sensor, phase == .active else { return }
        sensorReps.append(r)
        if !r.counted { partials += 1 }
        lastSensorRep = r
        coach.repAnalysed(r)
    }

    /// Every camera frame. Counting runs even while ready/resting so the first rep can
    /// start the set hands-free; partials only count during an active set.
    func cameraFrame(_ f: PoseFrame?) {
        guard source == .camera, phase != .finished, cameraCounter != nil, let cfg = exercise?.camera else { return }
        let angle = f?.angle(cfg.metric)
        let event = cameraCounter!.push(angle: angle, time: f?.time ?? ProcessInfo.processInfo.systemUptime)
        cameraProgress = max(0, min(1, cameraCounter!.progress))
        switch event {
        case .counted(_, let rep)?:
            repDetected()
            cameraReps.append(rep)
            lastCameraRep = rep
            if rep.downSeconds < 0.7 { coach.guide("Slower on the way back.") }
        case .partial(let rep)?:
            if phase == .active {
                partials += 1
                cameraReps.append(rep)
                lastCameraRep = rep
                coach.guide("Full range.")
            }
        case nil:
            break
        }
    }

    // MARK: - internals

    /// A full rep from the sensor or camera.
    private func repDetected() {
        if phase == .ready || phase == .resting {
            startSet()   // hands-free start
        }
        guard phase == .active else { return }
        reps += 1
        coach.repCounted(reps)
        if reps == targetReps { coach.guide("Target reached.") }
    }

    /// Set up for the current exercise: weight (suggestion beats plan), target reps,
    /// and the best available counting method (SmartBell if ready, else camera, else manual).
    private func prepareExercise() {
        let ex = exercise
        let p = plan
        weight = suggestedWeights[p.exerciseId] ?? p.weight
        targetReps = p.reps
        if let ex, ex.supportsSensor, sensorStatus(ex) == .ready { source = .sensor }
        else if let ex, ex.supportsCamera { source = .camera }
        else { source = .manual }
        cameraCounter = ex?.camera.map { AngleRepCounter(config: $0) }
    }

    /// Waiting for the next set; optionally speak what it is.
    private func enterReady(announce: Bool) {
        phase = .ready
        reps = 0
        partials = 0
        restAnnounced = false
        guard announce, let ex = exercise else { return }
        var line = "\(ex.name). Set \(setNumber) of \(totalSets). \(targetReps) reps"
        if ex.usesWeight && weight > 0 { line += " at \(formatWeight(weight)) \(unit == .lb ? "pounds" : "kilos")" }
        line += source == .manual ? ". Tap start when you begin." : ". Start when you're ready."
        coach.guide(line)
    }

    private func enterRest(seconds: Double) {
        phase = .resting
        restTotal = seconds
        restRemaining = seconds
        restWarned = false
        coach.guide("Rest \(Int(seconds)) seconds.")
    }

    /// Like finishSet() but without announcements or rest; used when skipping/finishing
    /// mid-set. A set with 0 reps is dropped.
    private func finishSetQuietly() {
        guard phase == .active, let start = setStart, reps > 0 else { phase = .ready; return }
        let now = Date()
        let log = SetLog(reps: reps, partials: partials, weight: weight, unit: unit, rpe: nil, start: start,
                         duration: now.timeIntervalSince(start), restBefore: lastSetEnd.map { start.timeIntervalSince($0) },
                         source: source, sensorReps: sensorReps, cameraReps: cameraReps)
        session.exercises[exerciseIndex].sets.append(log)
        lastSetEnd = now
        phase = .ready
    }

    /// 4 Hz: update the rest countdown, warn at 10 s (only for rests over 15 s), and
    /// move to `ready` when rest is over.
    private func tick() {
        let now = Date()
        switch phase {
        case .resting:
            guard let end = lastSetEnd else { return }
            restRemaining = restTotal - now.timeIntervalSince(end)
            if restRemaining <= 10 && !restWarned && restTotal > 15 {
                restWarned = true
                coach.guide("10 seconds.")
            }
            if restRemaining <= 0 && !restAnnounced {
                restAnnounced = true
                coach.restOver()
                enterReady(announce: true)
            }
        case .ready, .active, .finished:
            break
        }
    }
}
