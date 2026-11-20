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
    private let sensorReady: @MainActor () -> Bool
    /// Called once when the workout finishes normally (not on cancel).
    var onFinished: (@MainActor () -> Void)?
    private let suggestedWeights: [String: Double]
    private var setStart: Date?
    private var lastSetEnd: Date?
    private var lastRepTime = Date()
    private var sensorReps: [RepResult] = []
    private var cameraReps: [CameraRep] = []
    private var cameraCounter: AngleRepCounter?
    private var timer: Timer?
    private var restWarned = false
    private var restAnnounced = false

    init(template: WorkoutTemplate, unit: WeightUnit, isDemo: Bool, coach: Coach, store: WorkoutStore,
         sensorReady: @escaping @MainActor () -> Bool) {
        self.unit = unit
        self.coach = coach
        self.sensorReady = sensorReady
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

    var availableSources: [TrackingMode] {
        (exercise?.tracking ?? [.manual]).filter { $0 != .sensor || sensorReady() }
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
        lastRepTime = Date()
        reps = 0
        partials = 0
        sensorReps = []
        cameraReps = []
        lastSensorRep = nil
        lastCameraRep = nil
        if source == .manual { reps = targetReps }  // pre-fill; adjust with − / +
    }

    /// Manual end, or called automatically after a pause.
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

    private func repDetected() {
        if phase == .ready || phase == .resting { startSet() }   // hands-free start
        guard phase == .active else { return }
        reps += 1
        lastRepTime = Date()
        coach.repCounted(reps)
        if reps == targetReps { coach.guide("Target reached.") }
    }

    private func prepareExercise() {
        let ex = exercise
        let p = plan
        weight = suggestedWeights[p.exerciseId] ?? p.weight
        targetReps = p.reps
        if let ex, ex.supportsSensor, sensorReady() { source = .sensor }
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
            guard source != .manual, reps > 0 else { return }
            // a pause ends the set: shorter once the target is reached
            let wait: TimeInterval = reps >= targetReps ? 4 : 8
            if now.timeIntervalSince(lastRepTime) > wait { finishSet() }
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
        case .ready, .finished:
            break
        }
    }
}
