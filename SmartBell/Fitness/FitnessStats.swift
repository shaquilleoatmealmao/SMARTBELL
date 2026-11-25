//
//  FitnessStats.swift
//  SmartBell — Fitness
//
//  Read-only summaries computed from saved WorkoutSessions: this week's workouts,
//  weekly streak, weekly volume, a daily activity map, per-exercise trend points
//  (top weight, estimated 1RM, form score, speed, range, velocity loss) and records.
//  Nothing is cached; views build a FitnessStats from the store when they draw.
//

import Foundation

/// Aggregates for the Train and Progress tabs. Cheap enough to recompute on every render.
struct FitnessStats {
    let sessions: [WorkoutSession]           // newest first
    private let cal = Calendar.current

    init(sessions: [WorkoutSession]) { self.sessions = sessions }

    /// First moment of the calendar week containing `d` (locale decides Sunday vs Monday).
    private func weekStart(_ d: Date) -> Date {
        cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
    }

    var thisWeek: [WorkoutSession] {
        let start = weekStart(Date())
        return sessions.filter { $0.start >= start }
    }

    /// Consecutive weeks (ending this week, or last week if none yet this week) with at least one workout.
    var weekStreak: Int {
        let weeks = Set(sessions.map { weekStart($0.start) })
        var w = weekStart(Date())
        if !weeks.contains(w) { w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w }
        var n = 0
        while weeks.contains(w) {
            n += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: w) else { break }
            w = prev
        }
        return n
    }

    struct WeekPoint: Identifiable { var id: Date { week }; var week: Date; var volume: Double; var workouts: Int; var reps: Int }

    /// Last `count` weeks, oldest first (including empty weeks).
    func weekly(count: Int, unit: WeightUnit) -> [WeekPoint] {
        let now = weekStart(Date())
        return (0..<count).reversed().compactMap { i -> WeekPoint? in
            guard let w = cal.date(byAdding: .weekOfYear, value: -i, to: now),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: w) else { return nil }
            let s = sessions.filter { $0.start >= w && $0.start < end }
            return WeekPoint(week: w, volume: s.reduce(0) { $0 + $1.volume(in: unit) }, workouts: s.count,
                             reps: s.reduce(0) { $0 + $1.totalReps })
        }
    }

    /// Reps per day for the last `days` days (for the activity grid), keyed by start of day.
    func dailyReps(days: Int) -> [Date: Int] {
        let from = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date())) ?? Date()
        var d: [Date: Int] = [:]
        for s in sessions where s.start >= from {
            // max(…, 1) so a workout with no logged reps still shows as an active day.
            d[cal.startOfDay(for: s.start), default: 0] += max(s.totalReps, 1)
        }
        return d
    }

    /// Exercises that have at least one logged set, most recently trained first.
    var trainedExercises: [Exercise] {
        var seen: [String] = []
        for s in sessions { for e in s.exercises where !e.sets.isEmpty && !seen.contains(e.exerciseId) { seen.append(e.exerciseId) } }
        return seen.compactMap { ExerciseLibrary.exercise($0) }
    }

    /// One session's summary for one exercise (a point on the Progress charts).
    /// Optional fields are nil when that session has no data for them (e.g. manual sets).
    struct ExercisePoint: Identifiable {
        var id: Date { date }
        var date: Date
        var topWeight: Double
        var estimated1RM: Double?
        var totalReps: Int
        var formScore: Int?
        var speed: Double?
        var range: Double?
        var velocityLoss: Double?
    }

    /// One point per session for an exercise, oldest first, weights in `unit`.
    func points(for exerciseId: String, unit: WeightUnit) -> [ExercisePoint] {
        sessions.reversed().compactMap { s -> ExercisePoint? in
            let sets = s.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets)
            guard !sets.isEmpty else { return nil }
            func w(_ x: SetLog) -> Double { x.unit.convert(x.weight, to: unit) }
            let e1 = sets.compactMap { x in x.estimatedOneRepMax.map { x.unit.convert($0, to: unit) } }.max()
            let scores = sets.compactMap(\.formScore)
            let speeds = sets.compactMap(\.meanSpeed)
            let ranges = sets.compactMap(\.meanRange)
            let vls = sets.compactMap(\.velocityLoss)
            return ExercisePoint(date: s.start, topWeight: sets.map(w).max() ?? 0, estimated1RM: e1,
                                 totalReps: sets.reduce(0) { $0 + $1.reps },
                                 formScore: scores.isEmpty ? nil : scores.reduce(0, +) / scores.count,
                                 speed: speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count),
                                 range: ranges.isEmpty ? nil : ranges.reduce(0, +) / Double(ranges.count),
                                 velocityLoss: vls.isEmpty ? nil : vls.reduce(0, +) / Double(vls.count))
        }
    }

    struct Record: Identifiable { var id: String { exercise.id }; var exercise: Exercise; var best1RM: Double?; var maxWeight: Double; var maxReps: Int }

    /// Personal bests per trained exercise.
    func records(unit: WeightUnit) -> [Record] {
        trainedExercises.map { ex in
            let pts = points(for: ex.id, unit: unit)
            let sets = sessions.flatMap { $0.exercises.filter { $0.exerciseId == ex.id }.flatMap(\.sets) }
            return Record(exercise: ex, best1RM: pts.compactMap(\.estimated1RM).max(),
                          maxWeight: pts.map(\.topWeight).max() ?? 0, maxReps: sets.map(\.reps).max() ?? 0)
        }
    }
}
