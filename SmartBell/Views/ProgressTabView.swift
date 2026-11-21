import SwiftUI
import Charts

/// Progress over time: activity, weekly volume, personal records, and per-exercise trends.
struct ProgressTabView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("unit") private var unit = WeightUnit.lb
    @State private var exerciseId: String?

    var body: some View {
        let stats = FitnessStats(sessions: model.store.sessions)
        NavigationStack {
            List {
                if model.store.sessions.isEmpty {
                    ContentUnavailableView("No workouts yet", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("Finish a workout and your progress shows up here."))
                } else {
                    Section { WeekStrip().listRowInsets(EdgeInsets()) }

                    Section("Activity, last 12 weeks") {
                        ActivityGrid(daily: stats.dailyReps(days: 84))
                            .frame(height: 110)
                    }

                    Section("Weekly volume (\(unit.rawValue))") {
                        Chart(stats.weekly(count: 8, unit: unit)) { w in
                            BarMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Volume", w.volume))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(height: 160)
                    }

                    let trained = stats.trainedExercises
                    if !trained.isEmpty {
                        Section {
                            Picker("Exercise", selection: Binding(get: { exerciseId ?? trained[0].id }, set: { exerciseId = $0 })) {
                                ForEach(trained) { Text($0.name).tag($0.id) }
                            }
                            ExerciseTrends(points: stats.points(for: exerciseId ?? trained[0].id, unit: unit), unit: unit)
                        } header: { Text("Exercise trends") }

                        Section("Personal records") {
                            ForEach(stats.records(unit: unit)) { r in
                                HStack {
                                    Text(r.exercise.name)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if r.exercise.usesWeight && r.maxWeight > 0 {
                                            Text("\(formatWeight(r.maxWeight)) \(unit.rawValue) top set").font(.subheadline.bold())
                                        }
                                        if let e = r.best1RM, r.exercise.usesWeight {
                                            Text("est. 1RM \(formatWeight(e))").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text("\(r.maxReps) reps best set").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Progress")
        }
    }
}

/// Line charts for one exercise, one point per session. Charts only appear when there's data.
struct ExerciseTrends: View {
    var points: [FitnessStats.ExercisePoint]
    var unit: WeightUnit

    var body: some View {
        if points.count < 2 {
            Text("Do this exercise in at least two workouts to see trends.").font(.footnote).foregroundStyle(.secondary)
        }
        if points.contains(where: { $0.estimated1RM != nil }) {
            trend("Estimated 1-rep max (\(unit.rawValue))", points.compactMap { p in p.estimated1RM.map { (p.date, $0) } })
        }
        if points.contains(where: { $0.topWeight > 0 }) {
            trend("Top set weight (\(unit.rawValue))", points.map { ($0.date, $0.topWeight) })
        }
        trend("Total reps", points.map { ($0.date, Double($0.totalReps)) })
        if points.contains(where: { $0.formScore != nil }) {
            trend("Form score", points.compactMap { p in p.formScore.map { (p.date, Double($0)) } }, domain: 0...100)
        }
        if points.contains(where: { $0.speed != nil }) {
            trend("Average lifting speed", points.compactMap { p in p.speed.map { (p.date, $0) } })
        }
        if points.contains(where: { $0.range != nil }) {
            trend("Range of motion", points.compactMap { p in p.range.map { (p.date, $0) } })
        }
    }

    @ViewBuilder
    private func trend(_ title: String, _ data: [(Date, Double)], domain: ClosedRange<Double>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                if let first = data.first?.1, let last = data.last?.1, data.count >= 2, first != 0 {
                    let change = (last - first) / abs(first) * 100
                    Text(String(format: "%+.0f%%", change)).font(.caption.bold())
                        .foregroundStyle(change >= 0 ? Color.green : Color.orange)
                }
            }
            Chart(Array(data.enumerated()), id: \.offset) { _, d in
                LineMark(x: .value("Date", d.0), y: .value(title, d.1))
                PointMark(x: .value("Date", d.0), y: .value(title, d.1))
            }
            .chartYScale(domain: domain ?? autoDomain(data.map(\.1)))
            .frame(height: 120)
        }
        .padding(.vertical, 4)
    }

    private func autoDomain(_ ys: [Double]) -> ClosedRange<Double> {
        let lo = ys.min() ?? 0, hi = ys.max() ?? 1
        let pad = max((hi - lo) * 0.2, 1)
        return max(0, lo - pad)...(hi + pad)
    }
}

/// GitHub-style grid: one square per day, darker = more reps.
struct ActivityGrid: View {
    var daily: [Date: Int]

    var body: some View {
        GeometryReader { g in
            let weeks = 12
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1), to: today) ?? today
            let cell = min((g.size.width - CGFloat(weeks - 1) * 3) / CGFloat(weeks), (g.size.height - 18) / 7)
            let maxReps = max(daily.values.max() ?? 1, 1)
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) ?? today
                            let reps = daily[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(reps == 0 ? Color.secondary.opacity(0.15)
                                      : Color.green.opacity(0.35 + 0.65 * Double(reps) / Double(maxReps)))
                                .frame(width: cell, height: cell)
                                .opacity(day > today ? 0 : 1)
                        }
                    }
                }
            }
        }
    }
}
