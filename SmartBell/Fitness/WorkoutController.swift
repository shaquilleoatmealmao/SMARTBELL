import Foundation

/// Runs a guided workout, hands-free:
///
///   ready ──first rep detected (or Start)──▶ active ──no rep for a few s (or Done)──▶ resting
///     ▲                                                                                  │
///     └────────── rest timer ends (or Skip) ◀────────────────────────────────────────────┘
///   after the last set of the last exercise ──▶ finished
///
/// With the SmartBell or the camera you never need to touch the phone: the first rep starts the
/// set, a pause ends it, the rest timer runs and speaks, and the next set starts when you do.
/// Rest is measured from the end of one set to the first rep of the next.
@MainActor
final class WorkoutController: ObservableObject {
    enum Phase: Equatable { case ready, active, resting, finished }

    @Published private(set) var session: WorkoutSession
    @Published private(set) var phase = Phase.ready
    @Published private(set) var exerciseIndex = 0
    @Published private(set) var source: TrackingMode = .manual
    @Published private(set) var reps = 0
    @Published private(set) var partials = 0
    @Published private(set) var lastSensorRep: RepResult? = nil
    @Published private(set) var lastCameraRep: CameraRep? = nil
    @Published private(set) var cameraProgress = 0.0
    @Published private(set) var restRemaining: TimeInterval = 0
    @Published private(set) var restTotal: TimeInterval = 0
    @Published private(set) var lastFinished: (exercise: Int, index: Int)? = nil
    @Published var weight: Double = 0
    @Published var targetReps: Int = 10

    let unit: WeightUnit
    let previous: [String: [SetLog]]       // exerciseId -> sets from the most recent session
    private let coach: Coach
    private let sensorStatus: @MainActor (Exercise) -> SensorStatus
    /// Called once when the workout finishes normally (not on cancel).
    var onFinished: (@MainActor () -> Void)?
    private let suggestedWeights: [String: Double]
    private var setStart: Date?
    private var lastSetEnd: Date?
    private var lastActivity = Date()      // last counted rep, partial, or rep in progress
    private var autoEnded: AutoEnded?
    /// True for ~20 s after a set ended on its own: lifting again continues that set.
    @Published private(set) var canResume = false

    /// What's needed to undo an automatic set end.
    private struct AutoEnded {
        var exerciseIndex: Int
        var log: SetLog
        var targetReps: Int
        var previousSetEnd: Date?
        var previousLastFinished: (exercise: Int, index: Int)?
        var endedAt: Date
    }

    nonisolated static let autoFinishKey = "autoFinishSets"
    private var autoFinishEnabled: Bool { UserDefaults.standard.object(forKey: Self.autoFinishKey) as? Bool ?? true }
    nonisolated static let resumeWindow: TimeInterval = 20
    private var sensorReps: [RepResult] = []
    private var cameraReps: [CameraRep] = []
    private var cameraCounter: AngleRepCounter?
    private var timer: Timer?
    private var restWarned = false
    private var restAnnounced = false

    init(template: WorkoutTemplate, unit: WeightUnit, isDemo: Bool, coach: Coach, store: WorkoutStore,
         sensorStatus: @escaping @MainActor (Exercise) -> SensorStatus) {
        self.unit = unit
        self.coach = coach
        self.sensorStatus = sensorStatus
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

    func begin() {
        coach.beginSet()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        enterReady(announce: true)
    }

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
        lastActivity = Date()
        clearResume()
        reps = 0
        partials = 0
        sensorReps = []
        cameraReps = []
        lastSensorRep = nil
        lastCameraRep = nil
        if source == .manual { reps = targetReps }  // pre-fill; adjust with − / +
    }

    /// Manual end (Done button).
    func finishSet() { finishSet(auto: false) }

    /// `auto`: ended by a pause. Then lifting again within 20 s continues the same set.
    private func finishSet(auto: Bool) {
        guard phase == .active, let start = setStart else { return }
        let now = Date()
        let rest = lastSetEnd.map { start.timeIntervalSince($0) }
        let log = SetLog(reps: reps, partials: partials, weight: weight, unit: unit, rpe: nil, start: start,
                         duration: now.timeIntervalSince(start), restBefore: rest, source: source,
                         sensorReps: sensorReps, cameraReps: cameraReps)
        autoEnded = auto ? AutoEnded(exerciseIndex: exerciseIndex, log: log, targetReps: targetReps,
                                     previousSetEnd: lastSetEnd, previousLastFinished: lastFinished, endedAt: now) : nil
        canResume = auto
        session.exercises[exerciseIndex].sets.append(log)
        lastFinished = (exerciseIndex, session.exercises[exerciseIndex].sets.count - 1)
        lastSetEnd = now
        setStart = nil

        var line = "\(reps) reps."
        if let vl = log.velocityLoss, vl >= 0.3 {
            line += " Speed dropped \(Int(vl * 100)) percent, you're close to failure."
        }
        coach.guide(line)

        if currentLog.sets.count >= plan.sets {
            // exercise done
            if exerciseIndex + 1 < session.exercises.count {
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

    func adjustReps(_ delta: Int) {
        guard phase == .active else { return }
        reps = max(0, reps + delta)
    }

    func skipRest() {
        guard phase == .resting else { return }
        clearResume()
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

    func skipExercise() {
        clearResume()
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
        lastActivity = Date()
        sensorReps.append(r)
        if !r.counted { partials += 1 }
        lastSensorRep = r
        coach.repAnalysed(r)
    }

    func cameraFrame(_ f: PoseFrame?) {
        guard source == .camera, phase != .finished, cameraCounter != nil, let cfg = exercise?.camera else { return }
        let angle = f?.angle(cfg.metric)
        let event = cameraCounter!.push(angle: angle, time: f?.time ?? ProcessInfo.processInfo.systemUptime)
        cameraProgress = max(0, min(1, cameraCounter!.progress))
        if cameraCounter!.inRep { noteMovement() }
        switch event {
        case .counted(_, let rep)?:
            repDetected()
            cameraReps.append(rep)
            lastCameraRep = rep
            if rep.downSeconds < 0.7 { coach.guide("Slower on the way back.") }
        case .partial(let rep)?:
            if phase == .active {
                lastActivity = Date()
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

    /// A rep is in progress (SmartBell or camera sees you mid-movement): don't end the set.
    func noteMovement() {
        if phase == .active { lastActivity = Date() }
    }

    /// Continue the set that just ended on its own, as if it never stopped.
    func resumeSet() {
        guard let a = autoEnded, phase == .resting || phase == .ready else { return }
        clearResume()
        if let i = session.exercises[a.exerciseIndex].sets.lastIndex(where: { $0.id == a.log.id }) {
            session.exercises[a.exerciseIndex].sets.remove(at: i)
        }
        if exerciseIndex != a.exerciseIndex {
            exerciseIndex = a.exerciseIndex
            prepareExercise()
        }
        weight = a.log.weight
        targetReps = a.targetReps
        source = a.log.source
        reps = a.log.reps
        partials = a.log.partials
        sensorReps = a.log.sensorReps
        cameraReps = a.log.cameraReps
        setStart = a.log.start
        lastSetEnd = a.previousSetEnd
        lastFinished = a.previousLastFinished
        phase = .active
        lastActivity = Date()
        coach.guide("Continuing the set.")
    }

    private func clearResume() {
        autoEnded = nil
        canResume = false
    }

    private func repDetected() {
        if phase == .ready || phase == .resting {
            // Lifting again right after a set ended on its own: it wasn't over, continue it.
            if let a = autoEnded, Date().timeIntervalSince(a.endedAt) < WorkoutController.resumeWindow {
                resumeSet()
            } else {
                startSet()   // hands-free start
            }
        }
        guard phase == .active else { return }
        reps += 1
        lastActivity = Date()
        coach.repCounted(reps)
        if reps == targetReps { coach.guide("Target reached.") }
    }

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

    private func tick() {
        let now = Date()
        switch phase {
        case .active:
            guard source != .manual, reps > 0, autoFinishEnabled else { return }
            // A real pause ends the set: 5 s once the target is reached, 12 s before it.
            // "Pause" means no counted rep, no partial and no rep in progress, so slow or
            // half-counted reps keep the set open. The last set of the workout only ends
            // on its own once the target is reached.
            let lastSetOfWorkout = exerciseIndex == session.exercises.count - 1 && currentLog.sets.count + 1 >= plan.sets
            if reps < targetReps && lastSetOfWorkout { return }
            let wait: TimeInterval = reps >= targetReps ? 5 : 12
            if now.timeIntervalSince(lastActivity) > wait { finishSet(auto: true) }
        case .resting:
            if canResume, let a = autoEnded, now.timeIntervalSince(a.endedAt) >= WorkoutController.resumeWindow {
                clearResume()
            }
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
        case .ready, .finished:
            break
        }
    }
}
