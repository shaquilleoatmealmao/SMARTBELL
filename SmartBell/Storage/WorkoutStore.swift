import Foundation

/// Persists sessions, custom workouts and next-time weights as JSON in the app's Documents folder.
@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var sessions: [WorkoutSession] = []      // newest first
    @Published private(set) var customTemplates: [WorkoutTemplate] = []
    @Published private(set) var nextWeights: [String: Double] = [:]  // exerciseId -> weight (in unit below)
    @Published private(set) var nextWeightUnits: [String: WeightUnit] = [:]

    private struct Saved: Codable {
        var sessions: [WorkoutSession]
        var customTemplates: [WorkoutTemplate]
        var nextWeights: [String: Double]
        var nextWeightUnits: [String: WeightUnit]
    }

    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var url: URL { Self.docs.appendingPathComponent("fitness.json") }
    private var legacyURL: URL { Self.docs.appendingPathComponent("workouts.json") }

    init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            sessions = s.sessions
            customTemplates = s.customTemplates
            nextWeights = s.nextWeights
            nextWeightUnits = s.nextWeightUnits
        } else {
            migrateLegacy()
        }
    }

    var templates: [WorkoutTemplate] { customTemplates + ExerciseLibrary.templates }

    // MARK: sessions

    func add(_ s: WorkoutSession) {
        sessions.insert(s, at: 0)
        for log in s.exercises {
            if let w = Progression.nextWeight(for: log), let u = log.sets.last?.unit {
                nextWeights[log.exerciseId] = w
                nextWeightUnits[log.exerciseId] = u
            }
        }
        save()
    }

    func deleteSessions(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        save()
    }

    /// Weight to pre-fill for an exercise: last session's suggestion, converted to `unit`.
    func suggestedWeight(_ exerciseId: String, unit: WeightUnit) -> Double? {
        guard let w = nextWeights[exerciseId] else { return nil }
        let from = nextWeightUnits[exerciseId] ?? unit
        let v = from.convert(w, to: unit)
        return (v * 2).rounded() / 2  // nearest 0.5
    }

    /// Every logged set of one exercise, oldest first, with its session date.
    func history(of exerciseId: String) -> [(date: Date, sets: [SetLog])] {
        sessions.reversed().compactMap { s -> (date: Date, sets: [SetLog])? in
            let sets = s.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets)
            return sets.isEmpty ? nil : (date: s.start, sets: sets)
        }
    }

    // MARK: templates

    func saveTemplate(_ t: WorkoutTemplate) {
        var t = t
        t.builtIn = false
        if let i = customTemplates.firstIndex(where: { $0.id == t.id }) { customTemplates[i] = t } else { customTemplates.insert(t, at: 0) }
        save()
    }

    func deleteTemplate(_ id: String) {
        customTemplates.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let s = Saved(sessions: sessions, customTemplates: customTemplates, nextWeights: nextWeights, nextWeightUnits: nextWeightUnits)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: migration from v2.0 (single sets)

    private struct LegacySet: Codable {
        var id: UUID
        var date: Date
        var exercise: String
        var weight: Double
        var unit: WeightUnit
        var targetReps: Int
        var reps: [RepResult]
        var duration: TimeInterval
        var isDemo: Bool
    }

    private func migrateLegacy() {
        guard let data = try? Data(contentsOf: legacyURL),
              let old = try? JSONDecoder().decode([LegacySet].self, from: data), !old.isEmpty else { return }
        sessions = old.map { o in
            let exId = o.exercise == "Hammer curl" ? "hammer-curl" : "bicep-curl"
            let set = SetLog(reps: o.reps.filter(\.counted).count, partials: o.reps.filter { !$0.counted }.count,
                             weight: o.weight, unit: o.unit, start: o.date, duration: o.duration,
                             source: .sensor, sensorReps: o.reps)
            let plan = PlannedExercise(exerciseId: exId, sets: 1, reps: o.targetReps, weight: o.weight, restSeconds: 90)
            return WorkoutSession(name: o.exercise, templateId: nil, start: o.date, end: o.date.addingTimeInterval(o.duration),
                                  exercises: [ExerciseLog(exerciseId: exId, plan: plan, sets: [set])], isDemo: o.isDemo)
        }
        save()
    }
}
