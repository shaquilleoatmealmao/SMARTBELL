import Foundation

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case lb, kg
    var id: String { rawValue }

    /// Convert a weight in this unit to `other`.
    func convert(_ w: Double, to other: WeightUnit) -> Double {
        if self == other { return w }
        return self == .lb ? w * 0.45359237 : w / 0.45359237
    }
}

func formatWeight(_ w: Double) -> String {
    w.formatted(.number.precision(.fractionLength(0...1)))
}

// MARK: - Plans

struct PlannedExercise: Codable, Identifiable, Equatable {
    var id = UUID()
    var exerciseId: String
    var sets: Int
    var reps: Int
    var weight: Double           // in the user's unit at the time the plan was made
    var restSeconds: Int

    var exercise: Exercise? { ExerciseLibrary.exercise(exerciseId) }
}

struct WorkoutTemplate: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var builtIn: Bool = false
    var items: [PlannedExercise]
}

// MARK: - What actually happened

/// Per-rep summary from the camera counter.
struct CameraRep: Codable, Equatable {
    var upSeconds: Double
    var downSeconds: Double
    var romDeg: Double
    var counted: Bool
}

struct SetLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var reps: Int
    var partials: Int = 0
    var weight: Double
    var unit: WeightUnit
    var rpe: Double? = nil                 // rate of perceived exertion 6...10
    var start: Date
    var duration: TimeInterval
    var restBefore: TimeInterval? = nil    // measured rest since the previous set
    var source: TrackingMode
    var sensorReps: [RepResult] = []       // full SmartBell analysis, if tracked by the sensor
    var cameraReps: [CameraRep] = []

    var volume: Double { Double(reps) * weight }

    /// Average form score (sensor sets only).
    var formScore: Int? {
        let c = sensorReps.filter(\.counted)
        guard !c.isEmpty else { return nil }
        return c.reduce(0) { $0 + $1.score } / c.count
    }

    /// Lifting speed per counted rep, deg/s (range of motion / lift time).
    var repSpeeds: [Double] {
        if !sensorReps.isEmpty {
            return sensorReps.filter(\.counted).map { ($0.topDeg - $0.bottomDeg) / max($0.concentricSeconds, 0.1) }
        }
        return cameraReps.filter(\.counted).map { $0.romDeg / max($0.upSeconds, 0.1) }
    }

    var meanSpeed: Double? {
        let s = repSpeeds
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    /// Velocity loss: how much slower the last reps were than the best of the first two (0...1).
    /// Sports-science rule of thumb: a 20-30% loss means you're getting close to failure.
    var velocityLoss: Double? {
        let s = repSpeeds
        guard s.count >= 4 else { return nil }
        let best = max(s[0], s[1])
        let last = (s[s.count - 1] + s[s.count - 2]) / 2
        guard best > 0 else { return nil }
        return max(0, (best - last) / best)
    }

    /// Mean range of motion (sensor: forearm angle; camera: tracked joint angle).
    var meanRange: Double? {
        if !sensorReps.isEmpty {
            let c = sensorReps.filter(\.counted)
            return c.isEmpty ? nil : c.reduce(0) { $0 + ($1.topDeg - $1.bottomDeg) } / Double(c.count)
        }
        let c = cameraReps.filter(\.counted)
        return c.isEmpty ? nil : c.reduce(0) { $0 + $1.romDeg } / Double(c.count)
    }

    /// Estimated one-rep max (Epley). Only meaningful for weighted sets of up to ~12 reps.
    var estimatedOneRepMax: Double? {
        guard weight > 0, reps > 0 else { return nil }
        return weight * (1 + Double(reps) / 30)
    }
}

struct ExerciseLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var exerciseId: String
    var plan: PlannedExercise
    var sets: [SetLog] = []

    var exercise: Exercise? { ExerciseLibrary.exercise(exerciseId) }
    var name: String { exercise?.name ?? exerciseId }
}

struct WorkoutSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var templateId: String?
    var start: Date
    var end: Date?
    var exercises: [ExerciseLog]
    var isDemo = false

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var allSets: [SetLog] { exercises.flatMap(\.sets) }
    var totalReps: Int { allSets.reduce(0) { $0 + $1.reps } }

    /// Total volume (reps x weight) in `unit`.
    func volume(in unit: WeightUnit) -> Double {
        allSets.reduce(0) { $0 + Double($1.reps) * $1.unit.convert($1.weight, to: unit) }
    }

    var averageRest: TimeInterval? {
        let r = allSets.compactMap(\.restBefore)
        return r.isEmpty ? nil : r.reduce(0, +) / Double(r.count)
    }

    var formScore: Int? {
        let s = allSets.compactMap(\.formScore)
        return s.isEmpty ? nil : s.reduce(0, +) / s.count
    }
}

// MARK: - Progressive overload

enum Progression {
    enum Advice: Equatable { case increase(Double), keep, decrease(Double) }

    /// Suggest next session's weight for one exercise:
    /// all sets hit the target, effort wasn't maximal (RPE <= 8 if logged) and form held up -> add one step;
    /// missed the target by 2+ reps on any set -> drop one step; otherwise keep it.
    static func advice(for log: ExerciseLog) -> Advice {
        guard let ex = log.exercise, ex.usesWeight, !log.sets.isEmpty else { return .keep }
        let unit = log.sets[0].unit
        let step = unit == .lb ? ex.increment : max(1, (ex.increment * 0.45359237).rounded())
        let target = log.plan.reps
        let worstMiss = log.sets.map { target - $0.reps }.max() ?? 0
        if worstMiss >= 2 { return .decrease(step) }
        let allHit = log.sets.count >= log.plan.sets && log.sets.allSatisfy { $0.reps >= target }
        let rpes = log.sets.compactMap(\.rpe)
        let easyEnough = rpes.isEmpty || rpes.max()! <= 8
        let scores = log.sets.compactMap(\.formScore)
        let formOK = scores.isEmpty || scores.reduce(0, +) / scores.count >= 75
        if allHit && easyEnough && formOK { return .increase(step) }
        return .keep
    }

    static func nextWeight(for log: ExerciseLog) -> Double? {
        guard let w = log.sets.last?.weight else { return nil }
        switch advice(for: log) {
        case .increase(let s): return w + s
        case .decrease(let s): return max(0, w - s)
        case .keep: return w
        }
    }

    static func text(for log: ExerciseLog) -> String? {
        guard let unit = log.sets.last?.unit, let next = nextWeight(for: log) else { return nil }
        switch advice(for: log) {
        case .increase: return "All sets hit the target with good form. Next time: \(formatWeight(next)) \(unit.rawValue)."
        case .decrease: return "You missed the target. Next time: \(formatWeight(next)) \(unit.rawValue)."
        case .keep: return "Stay at \(formatWeight(next)) \(unit.rawValue) until every set hits the target."
        }
    }
}
