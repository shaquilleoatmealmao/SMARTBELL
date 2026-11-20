import Foundation

enum Exercise: String, Codable, CaseIterable, Identifiable {
    case bicepCurl = "Bicep curl"
    case hammerCurl = "Hammer curl"
    var id: String { rawValue }
    var symbol: String { "figure.strengthtraining.traditional" }
}

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case lb, kg
    var id: String { rawValue }
}

struct WorkoutSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var exercise: Exercise
    var weight: Double
    var unit: WeightUnit
    var targetReps: Int
    var reps: [RepResult]          // counted reps and partials, in order
    var duration: TimeInterval
    var isDemo: Bool

    var countedReps: Int { reps.filter(\.counted).count }
    var partialReps: Int { reps.filter { !$0.counted }.count }

    var averageScore: Int {
        let c = reps.filter(\.counted)
        guard !c.isEmpty else { return 0 }
        return c.reduce(0) { $0 + $1.score } / c.count
    }

    var averageLift: Double { average(reps.filter(\.counted).map(\.concentricSeconds)) }
    var averageLower: Double { average(reps.filter(\.counted).map(\.eccentricSeconds)) }

    /// Most frequent problems, most frequent first.
    var issueCounts: [(issue: FormIssue, count: Int)] {
        var d: [FormIssue: Int] = [:]
        for r in reps { for i in r.issues { d[i, default: 0] += 1 } }
        return d.map { (issue: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.issue.priority < $1.issue.priority }
    }

    /// Gentle load hint based on reps vs target and whether form held up.
    /// This is a prompt to think about, not a prescription.
    var suggestion: String? {
        let counted = reps.filter(\.counted)
        guard counted.count >= 3 else { return nil }
        let third = max(1, counted.count / 3)
        let early = counted.prefix(third).reduce(0) { $0 + $1.score } / third
        let late = counted.suffix(third).reduce(0) { $0 + $1.score } / third
        if early - late >= 20 || countedReps < targetReps - 2 {
            return "Your form faded toward the end of the set. A slightly lighter weight or fewer reps may help."
        }
        if countedReps >= targetReps + 3 && averageScore >= 85 {
            return "That looked comfortable. If it felt easy, you could try a slightly heavier weight next set."
        }
        return nil
    }

    private func average(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
}

@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var sets: [WorkoutSet] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("workouts.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([WorkoutSet].self, from: data) {
            sets = decoded
        }
    }

    func add(_ s: WorkoutSet) {
        sets.insert(s, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        sets.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sets) { try? data.write(to: url, options: .atomic) }
    }
}
