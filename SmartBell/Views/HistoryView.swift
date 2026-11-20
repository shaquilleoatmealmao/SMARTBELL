import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("unit") private var unit = WeightUnit.lb

    var body: some View {
        NavigationStack {
            List {
                if model.store.sessions.isEmpty {
                    ContentUnavailableView("No workouts yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Finished workouts show up here."))
                } else {
                    ForEach(model.store.sessions) { s in
                        NavigationLink {
                            SessionSummaryView(session: s)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.name).font(.headline)
                                    if s.isDemo { Text("demo").font(.caption2.bold()).foregroundStyle(.orange) }
                                    Spacer()
                                    if let f = s.formScore { ScoreRing(score: f, size: 30) }
                                }
                                Text(s.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(s.allSets.count) sets · \(s.totalReps) reps · \(Int(s.volume(in: unit).rounded())) \(unit.rawValue) · \(durationText(s.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { model.store.deleteSessions(at: $0) }
                }
            }
            .navigationTitle("History")
        }
    }
}
