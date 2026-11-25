//
//  ArmModelView.swift
//  SmartBell — Views
//
//  Drawing components for curl feedback:
//    • ArmModelView – side and front stick-figure views of the arm, with the rep's hand path
//    • ScoreRing    – circular 0–100 form-score badge
//    • RepCard      – one-rep summary (score, main cue, lift/lower time, range)
//

import SwiftUI

/// Live picture of the rep, built only from drift-free quantities:
///  - side view: upper arm assumed vertical, forearm drawn at the measured angle
///  - front view: how far the forearm leaves the curl plane (per-rep, re-anchored every rep)
/// The traced line is the hand path of the current rep; the grey line is the previous rep.
struct ArmModelView: View {
    var hand: Vec3                 // (forward, side, up) unit forearm vector
    var path: [Vec3]               // current rep
    var ghost: [Vec3]              // previous rep
    // Calibrated range, drawn as the green target arc in the side view.
    var bottomDeg: Double
    var topDeg: Double
    // warning: draw the path and dumbbell in orange (last rep had a form issue).
    var warning: Bool = false
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 8 : 16) {
            panel(title: "Side", front: false)
            panel(title: "Front", front: true)
                .frame(maxWidth: compact ? 110 : 150)
        }
    }

    /// One labelled drawing panel.
    private func panel(title: String, front: Bool) -> some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, front: front)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Draw one view. Layout is proportional to the panel size; the elbow is the fixed pivot.
    /// Side view uses the hand's (forward, up) components, front view uses (side, up).
    private func draw(ctx: GraphicsContext, size: CGSize, front: Bool) {
        let upper = min(size.height * 0.30, size.width * (front ? 0.45 : 0.32))
        let lower = upper * 1.05
        let elbow = CGPoint(x: front ? size.width / 2 : size.width * 0.38, y: size.height * 0.48)
        let shoulder = CGPoint(x: elbow.x, y: elbow.y - upper)

        // Unit forearm vector → screen point at forearm length from the elbow (screen y grows down).
        func project(_ v: Vec3) -> CGPoint {
            let x = front ? v.y : v.x
            return CGPoint(x: elbow.x + CGFloat(x) * lower, y: elbow.y - CGFloat(v.z) * lower)
        }

        // target range (side view): arc from the calibrated bottom to top angle
        if !front {
            var arc = Path()
            let r = lower + 10
            // forearm angle beta from straight down, drawn swinging forward (to the right)
            let steps = 30
            for i in 0...steps {
                let b = (bottomDeg + (topDeg - bottomDeg) * Double(i) / Double(steps)) * radPerDeg
                let p = CGPoint(x: elbow.x + CGFloat(sin(b)) * r, y: elbow.y + CGFloat(cos(b)) * r)
                if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
            }
            ctx.stroke(arc, with: .color(.green.opacity(0.35)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        } else {
            // straight-path guide
            var guide = Path()
            guide.move(to: CGPoint(x: elbow.x, y: elbow.y - lower - 6))
            guide.addLine(to: CGPoint(x: elbow.x, y: elbow.y + lower + 6))
            ctx.stroke(guide, with: .color(.green.opacity(0.35)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }

        // body + upper arm
        var torso = Path()
        torso.move(to: CGPoint(x: shoulder.x, y: shoulder.y - 18))
        torso.addLine(to: shoulder)
        torso.addLine(to: elbow)
        ctx.stroke(torso, with: .color(.secondary), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: shoulder.x - 9, y: shoulder.y - 40, width: 18, height: 18)),
                 with: .color(.secondary.opacity(0.6)))

        // previous rep (ghost) and current rep path
        func polyline(_ pts: [Vec3]) -> Path {
            var p = Path()
            for (i, v) in pts.enumerated() {
                let q = project(v)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            return p
        }
        if ghost.count > 1 {
            ctx.stroke(polyline(ghost), with: .color(.gray.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        }
        if path.count > 1 {
            ctx.stroke(polyline(path), with: .color(warning ? .orange : .blue), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }

        // forearm + dumbbell
        let handPt = project(hand)
        var fore = Path()
        fore.move(to: elbow)
        fore.addLine(to: handPt)
        ctx.stroke(fore, with: .color(.primary), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: elbow.x - 6, y: elbow.y - 6, width: 12, height: 12)), with: .color(.primary))
        let bell = CGRect(x: handPt.x - 11, y: handPt.y - 11, width: 22, height: 22)
        ctx.fill(Path(roundedRect: bell, cornerRadius: 5), with: .color(warning ? .orange : .blue))
    }
}

/// Small circular score badge.
struct ScoreRing: View {
    var score: Int
    var size: CGFloat = 56

    // Green ≥ 85, orange ≥ 60, red below.
    var color: Color { score >= 85 ? .green : score >= 60 ? .orange : .red }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: size * 0.12)
            // Arc length = score; rotated so it starts at 12 o'clock.
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: size * 0.34, weight: .bold, design: .rounded))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Form score \(score) out of 100")
    }
}

/// One-line summary of a rep: score, main cue, timings.
struct RepCard: View {
    var rep: RepResult

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(score: rep.score)
            VStack(alignment: .leading, spacing: 4) {
                if let issue = rep.issues.first {
                    Text(issue.cueText(generic: rep.isGeneric)).font(.headline)
                    if rep.issues.count > 1 {
                        Text(rep.issues.dropFirst().map(\.label).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Good rep").font(.headline).foregroundStyle(.green)
                }
                HStack(spacing: 12) {
                    metric("Lift", String(format: "%.1fs", rep.concentricSeconds))
                    metric("Lower", String(format: "%.1fs", rep.eccentricSeconds))
                    // Taught exercises: peak as % of learned range. Curls: degrees moved.
                    metric("Range", rep.isGeneric ? "\(Int(rep.topDeg.rounded()))%" : "\(Int(rep.topDeg - rep.bottomDeg))°")
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
