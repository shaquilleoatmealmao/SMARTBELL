import SwiftUI
import Charts

/// Summary of a whole workout: totals, then every exercise and set.
struct SessionSummaryView: View {
    var session: WorkoutSession
    @AppStorage("unit") private var unit = WeightUnit.lb

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.name).font(.title.bold())
                    Text(session.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    if session.isDemo { Text("Demo data").font(.caption.bold()).foregroundStyle(.orange) }
                    HStack(spacing: 0) {
                        stat(durationText(session.duration), "time")
                        stat("\(session.allSets.count)", "sets")
                        stat("\(session.totalReps)", "reps")
                        stat(String(Int(session.volume(in: unit).rounded())), "\(unit.rawValue) volume")
                    }
                    HStack(spacing: 0) {
                        stat(session.averageRest.map { durationText($0) } ?? "–", "avg rest")
                        stat(session.formScore.map { "\($0)" } ?? "–", "form score")
                    }
                }
                .padding(.vertical, 6)
            }

            ForEach(session.exercises.filter { !$0.sets.isEmpty }) { log in
                Section {
                    ForEach(Array(log.sets.enumerated()), id: \.element.id) { i, s in
                        NavigationLink {
                            SetDetailView(set: s, title: "\(log.name) · set \(i + 1)")
                        } label: {
                            SetRow(index: i + 1, set: s)
                        }
                    }
                    if let advice = Progression.text(for: log) {
                        Label(advice, systemImage: "arrow.up.forward.circle").font(.footnote)
                    }
                } header: {
                    Text(log.name)
                }
            }
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

func durationText(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct SetRow: View {
    var index: Int
    var set: SetLog

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)").font(.headline.monospacedDigit()).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.weight > 0 ? "\(set.reps) × \(formatWeight(set.weight)) \(set.unit.rawValue)" : "\(set.reps) reps")
                    .font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: set.source.symbol)
                    if let r = set.restBefore { Text("rest \(durationText(r))") }
                    if let rpe = set.rpe { Text("RPE \(Int(rpe))") }
                    if let v = set.meanSpeed { Text("\(Int(v))\(set.speedUnit)") }
                    if let vl = set.velocityLoss { Text("−\(Int(vl * 100))%") }
                    if set.partials > 0 { Text("\(set.partials) partial") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = set.formScore { ScoreRing(score: s, size: 34) }
        }
    }
}

/// One set in detail: rep-by-rep speed (velocity loss) and, for SmartBell sets, form per rep.
struct SetDetailView: View {
    var set: SetLog
    var title: String

    var body: some View {
        List {
            Section {
                LabeledContent("Reps", value: "\(set.reps)" + (set.partials > 0 ? " (+\(set.partials) partial)" : ""))
                if set.weight > 0 { LabeledContent("Weight", value: "\(formatWeight(set.weight)) \(set.unit.rawValue)") }
                LabeledContent("Duration", value: durationText(set.duration))
                if let r = set.restBefore { LabeledContent("Rest before", value: durationText(r)) }
                if let rpe = set.rpe { LabeledContent("RPE", value: "\(Int(rpe))") }
                LabeledContent("Tracked by", value: set.source.label)
                if let e = set.estimatedOneRepMax, set.reps <= 12 {
                    LabeledContent("Estimated 1-rep max", value: "\(formatWeight(e)) \(set.unit.rawValue)")
                }
            }

            let speeds = set.repSpeeds
            if speeds.count >= 2 {
                Section {
                    Chart(Array(speeds.enumerated()), id: \.offset) { i, v in
                        BarMark(x: .value("Rep", i + 1), y: .value("deg/s", v))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(height: 150)
                    if let vl = set.velocityLoss {
                        Text("Speed dropped \(Int(vl * 100))% from your fastest early rep." +
                             (vl >= 0.3 ? " That usually means you were close to failure." : vl < 0.1 ? " You had plenty left." : ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Lifting speed per rep") }
            }

            if !set.sensorReps.isEmpty {
                Section("Form per rep") {
                    Chart(Array(set.sensorReps.enumerated()), id: \.offset) { i, r in
                        BarMark(x: .value("Rep", i + 1), y: .value("Score", r.score))
                            .foregroundStyle(r.counted ? (r.score >= 85 ? Color.green : r.score >= 60 ? .orange : .red) : .gray)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 140)
                    ForEach(Array(set.sensorReps.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 12) {
                            RepPathThumbnail(rep: r).frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.counted ? "Rep \(i + 1)" : "Partial").font(.headline)
                                Text(r.issues.isEmpty ? "Good" : r.issues.map(\.label).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "lift %.1fs · lower %.1fs · %d–%d°", r.concentricSeconds, r.eccentricSeconds,
                                            Int(r.bottomDeg), Int(r.topDeg)))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ScoreRing(score: r.score, size: 36)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tiny side-view drawing of one rep's hand path.
struct RepPathThumbnail: View {
    var rep: RepResult

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) * 0.42
            let c = CGPoint(x: size.width * 0.4, y: size.height * 0.5)
            var p = Path()
            for (i, v) in rep.path.enumerated() {
                let q = CGPoint(x: c.x + CGFloat(v.x) * r, y: c.y - CGFloat(v.z) * r)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.stroke(p, with: .color(rep.issues.isEmpty ? .green : .orange), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.secondary))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
    }
}
