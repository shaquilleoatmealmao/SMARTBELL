import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.store.sets.isEmpty {
                    ContentUnavailableView("No sets yet", systemImage: "dumbbell",
                                           description: Text("Finished sets show up here."))
                } else {
                    if model.store.sets.count >= 2 {
                        Section("Form score over time") {
                            Chart(Array(model.store.sets.reversed())) { s in
                                LineMark(x: .value("Date", s.date), y: .value("Score", s.averageScore))
                                PointMark(x: .value("Date", s.date), y: .value("Score", s.averageScore))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 150)
                        }
                    }
                    Section("Sets") {
                        ForEach(model.store.sets) { s in
                            NavigationLink {
                                SetSummaryView(set: s)
                            } label: {
                                HStack(spacing: 12) {
                                    ScoreRing(score: s.averageScore, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(s.countedReps) × \(s.exercise.rawValue)").font(.headline)
                                        Text("\(s.weight.formatted(.number.precision(.fractionLength(0...1)))) \(s.unit.rawValue) · \(s.date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if s.isDemo { Text("demo").font(.caption2.bold()).foregroundStyle(.orange) }
                                }
                            }
                        }
                        .onDelete { model.store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}
