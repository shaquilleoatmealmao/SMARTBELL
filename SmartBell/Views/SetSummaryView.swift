import SwiftUI
import Charts

struct SetSummaryView: View {
    var set: WorkoutSet

    var body: some View {
        List {
            Section {
                HStack(spacing: 20) {
                    ScoreRing(score: set.averageScore, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(set.countedReps) reps").font(.title.bold())
                        Text("\(set.exercise.rawValue) · \(set.weight.formatted(.number.precision(.fractionLength(0...1)))) \(set.unit.rawValue)")
                            .foregroundStyle(.secondary)
                        Text("Target \(set.targetReps)" + (set.partialReps > 0 ? " · \(set.partialReps) partial" : ""))
                            .font(.footnote).foregroundStyle(.secondary)
                        if set.isDemo { Text("Demo data").font(.caption.bold()).foregroundStyle(.orange) }
                    }
                }
                .padding(.vertical, 6)
                if let s = set.suggestion {
                    Label(s, systemImage: "lightbulb").font(.subheadline)
                }
            }

            Section("Tempo") {
                LabeledContent("Average lift", value: String(format: "%.1f s", set.averageLift))
                LabeledContent("Average lower", value: String(format: "%.1f s", set.averageLower))
            }

            if !set.reps.isEmpty {
                Section("Form score per rep") {
                    Chart(Array(set.reps.enumerated()), id: \.offset) { i, r in
                        BarMark(x: .value("Rep", i + 1), y: .value("Score", r.score))
                            .foregroundStyle(r.counted ? (r.score >= 85 ? Color.green : r.score >= 60 ? .orange : .red) : .gray)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 160)
                }
            }

            if !set.issueCounts.isEmpty {
                Section("What to work on") {
                    ForEach(set.issueCounts, id: \.issue) { item in
                        HStack {
                            Text(item.issue.label)
                            Spacer()
                            Text("\(item.count)×").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }

            Section("Reps") {
                ForEach(Array(set.reps.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 12) {
                        RepPathThumbnail(rep: r).frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.counted ? "Rep \(set.reps[0...i].filter(\.counted).count)" : "Partial")
                                .font(.headline)
                            Text(r.issues.isEmpty ? "Good" : r.issues.map(\.label).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "lift %.1fs · lower %.1fs · %d–%d°", r.concentricSeconds, r.eccentricSeconds,
                                        Int(r.bottomDeg), Int(r.topDeg)))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ScoreRing(score: r.score, size: 38)
                    }
                }
            }
        }
        .navigationTitle(set.date.formatted(date: .abbreviated, time: .shortened))
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
