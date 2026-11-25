//
//  WorkoutPlayerView.swift
//  SmartBell — Views
//
//  Full-screen workout UI, driven entirely by WorkoutController's state:
//    header (progress dots, exercise, set n of m, tracking picker)
//    tracking area (arm model / taught-exercise progress / camera preview)
//    phase panel: ready (set weight & reps) → active (rep count, last-rep card) → rest (timer)
//  When the workout finishes it shows SessionSummaryView. Also defines LastSetCard,
//  ProgressBar and InfoCard, which other screens reuse.
//

import SwiftUI

/// Full-screen guided workout. Hands-free with SmartBell or camera tracking.
struct WorkoutPlayerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var workout: WorkoutController
    @ObservedObject var camera: PoseCamera
    // Whether this view has started the camera (so it stops exactly what it started).
    @State private var cameraStarted = false
    @State private var confirmEnd = false

    var body: some View {
        NavigationStack {
            Group {
                if workout.phase == .finished {
                    SessionSummaryView(session: workout.session)
                        .toolbar { Button("Done") { model.closeWorkout() } }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            trackingArea
                            switch workout.phase {
                            case .ready: readyPanel
                            case .active: activePanel
                            case .resting: restPanel
                            case .finished: EmptyView()
                            }
                        }
                        .padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("End") { confirmEnd = true }
                        }
                        ToolbarItem(placement: .principal) {
                            Text(workout.session.name).font(.headline)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button { workout.addSet() } label: { Label("Add a set", systemImage: "plus") }
                                Button { workout.skipExercise() } label: { Label("Skip exercise", systemImage: "forward.end") }
                                if let ex = workout.exercise, ex.supportsSensor, !ex.sensorBuiltIn, model.hasData {
                                    Button { model.startTeaching(ex) } label: {
                                        Label(model.profiles[ex.id] == nil ? "Teach SmartBell" : "Re-teach SmartBell", systemImage: "sensor")
                                    }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                    .confirmationDialog("End workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
                        Button("Finish and save") { workout.finish() }
                        Button("Discard", role: .destructive) { model.cancelWorkout() }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        // Calibration / teaching can be started mid-workout; their sheets show over this screen.
        .sheet(isPresented: Binding(get: { model.calibrationStep != nil }, set: { if !$0 { model.dismissCalibration() } })) {
            CalibrationView().environmentObject(model).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.teachStep != nil }, set: { if !$0 { model.dismissTeaching() } })) {
            TeachView().environmentObject(model).interactiveDismissDisabled()
        }
        .onAppear(perform: syncCamera)
        .onChange(of: workout.source) { _, _ in syncCamera() }
        .onChange(of: workout.phase) { _, _ in syncCamera() }
        .onDisappear { if cameraStarted { camera.stop(); cameraStarted = false } }
    }

    /// Run the camera only while the current exercise is counted by the camera.
    private func syncCamera() {
        let want = workout.source == .camera && workout.phase != .finished
        if want && !cameraStarted { camera.start(); cameraStarted = true }
        if !want && cameraStarted { camera.stop(); cameraStarted = false }
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                // One dot per exercise: green = done, accent = current, grey = to come.
                ForEach(Array(workout.session.exercises.enumerated()), id: \.element.id) { i, e in
                    Capsule()
                        .fill(i < workout.exerciseIndex ? Color.green : i == workout.exerciseIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 5)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.exercise?.name ?? "").font(.title.bold())
                    Text("Set \(min(workout.setNumber, workout.totalSets)) of \(workout.totalSets)")
                        .font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                if workout.session.isDemo { Text("DEMO").font(.caption.bold()).foregroundStyle(.orange) }
            }
            // Tracking method can be changed between sets, not during one.
            if workout.phase != .active && workout.availableSources.count > 1 {
                Picker("Tracking", selection: Binding(get: { workout.source }, set: { workout.setSource($0) })) {
                    ForEach(workout.availableSources) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - tracking area

    @ViewBuilder private var trackingArea: some View {
        switch workout.source {
        case .sensor:
            sensorArea
        case .camera:
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CameraPreview(session: camera.session)
                    SkeletonOverlay(frame: camera.frame)
                    Button { camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").padding(8).background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(8)
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                ProgressBar(value: workout.cameraProgress)
                Text(cameraStatus).font(.caption).foregroundStyle(.secondary)
            }
        case .manual:
            EmptyView()
        }
    }

    /// SmartBell area: a prompt if it isn't ready, else the live arm model (curls)
    /// or a % of range bar (taught exercises).
    @ViewBuilder private var sensorArea: some View {
        let ex = workout.exercise
        switch workout.sensorState {
        case .noData:
            Label("No SmartBell data. Check the connection.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold()).foregroundStyle(.red)
        case .needsCalibration:
            InfoCard(title: "Calibrate SmartBell first",
                     text: "15 seconds: let your arm hang still, then do 3 slow curls.",
                     button: "Calibrate") { model.startCalibration() }
        case .needsTeaching:
            InfoCard(title: "Teach SmartBell \(ex?.name.lowercased() ?? "this exercise")",
                     text: "About 10 seconds, once: hold the start position, do 3 reps, hold still. After that it counts this exercise like curls.",
                     button: "Teach SmartBell") { if let ex { model.startTeaching(ex) } }
        case .ready:
            if ex?.sensorBuiltIn ?? true {
                ArmModelView(hand: model.live.hand, path: model.live.currentPath, ghost: model.lastRep?.path ?? [],
                             bottomDeg: model.calibration?.bottomDeg ?? 8, topDeg: model.calibration?.topDeg ?? 140,
                             // Orange when body/elbow acceleration is over 4 m/s² (same as the swing check).
                             warning: model.live.linearAcceleration > 4, compact: true)
                    .frame(height: 190)
            } else {
                let pct = model.live.profileProgress ?? 0
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(max(0, pct).rounded()))%").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("of your range").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "sensor")
                    }
                    ProgressBar(value: pct / 100)
                    if let ex, let p = model.profiles[ex.id] {
                        Text("SmartBell · \(p.summary)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    private var cameraStatus: String {
        switch camera.status {
        case .denied: return "Camera access is off. Turn it on in Settings › SmartBell."
        case .unavailable: return "Camera unavailable."
        case .starting, .idle: return "Starting camera…"
        case .running:
            if camera.frame == nil { return workout.exercise?.camera?.setupHint ?? "Step into view." }
            return workout.exercise?.camera?.setupHint ?? ""
        }
    }

    // MARK: - phases

    /// Before a set: adjust target reps and weight, see last session, start.
    private var readyPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                VStack {
                    Text("Reps").font(.caption).foregroundStyle(.secondary)
                    Stepper("\(workout.targetReps)", value: $workout.targetReps, in: 1...50)
                        .font(.title2.bold().monospacedDigit())
                }
                if workout.exercise?.usesWeight ?? true {
                    VStack {
                        Text("Weight (\(workout.unit.rawValue))").font(.caption).foregroundStyle(.secondary)
                        Stepper(formatWeight(workout.weight), value: $workout.weight, in: 0...500,
                                step: workout.unit == .lb ? 2.5 : 1)
                            .font(.title2.bold().monospacedDigit())
                    }
                }
            }
            if let prev = workout.previous[workout.plan.exerciseId], !prev.isEmpty {
                Text("Last time: " + prev.map { "\($0.reps)×\(formatWeight($0.weight))" }.joined(separator: ", ") + " \(prev[0].unit.rawValue)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                workout.startSet()
            } label: {
                Label("Start set", systemImage: "play.fill").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            if workout.source != .manual {
                Text("Or just start lifting. The first rep starts the set. Tap Done when you finish.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    /// During a set: big rep counter, ± for manual, feedback on the last rep, Done.
    private var activePanel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(workout.reps)")
                    .font(.system(size: 96, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: workout.reps)
                Text("/ \(workout.targetReps)").font(.title).foregroundStyle(.secondary)
                Spacer()
                if workout.source == .manual {
                    HStack {
                        Button { workout.adjustReps(-1) } label: { Image(systemName: "minus.circle.fill") }
                        Button { workout.adjustReps(1) } label: { Image(systemName: "plus.circle.fill") }
                    }
                    .font(.system(size: 40))
                }
            }
            if let r = workout.lastSensorRep, workout.source == .sensor {
                RepCard(rep: r).id(r.id)
            } else if let c = workout.lastCameraRep, workout.source == .camera {
                HStack {
                    Image(systemName: c.counted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(c.counted ? .green : .orange).font(.title)
                    Text(c.counted ? String(format: "Up %.1fs · down %.1fs", c.upSeconds, c.downSeconds) : "Partial rep: go through the full range")
                    Spacer()
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            }
            Button {
                workout.finishSet()
            } label: {
                Label("Done", systemImage: "checkmark").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    /// Between sets: countdown ring (orange in the last 10 s), what's next, and the last set.
    private var restPanel: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.blue.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: workout.restTotal > 0 ? max(0, workout.restRemaining) / workout.restTotal : 0)
                    .stroke(workout.restRemaining <= 10 ? Color.orange : Color.blue, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: workout.restRemaining)
                VStack(spacing: 2) {
                    Text("Rest").font(.headline).foregroundStyle(.secondary)
                    Text(timeString(max(0, workout.restRemaining)))
                        .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                }
            }
            .frame(width: 200, height: 200)

            HStack(spacing: 12) {
                Button("+30 s") { workout.extendRest(30) }.buttonStyle(.bordered)
                Button("Skip rest") { workout.skipRest() }.buttonStyle(.borderedProminent)
            }

            Text("Next: \(workout.exercise?.name ?? "") · set \(workout.setNumber) of \(workout.totalSets) · \(workout.targetReps) reps"
                 + ((workout.exercise?.usesWeight ?? false) && workout.weight > 0 ? " × \(formatWeight(workout.weight)) \(workout.unit.rawValue)" : ""))
                .font(.subheadline).multilineTextAlignment(.center)

            if let last = workout.lastFinishedSet {
                LastSetCard(set: last, workout: workout)
            }
        }
    }

    /// Countdown text, rounded up so it shows 0:01 rather than 0:00 until rest is really over.
    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(s.rounded(.up))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The set you just finished: fix the count, rate the effort, see speed loss.
struct LastSetCard: View {
    var set: SetLog
    @ObservedObject var workout: WorkoutController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last set").font(.headline)
                Spacer()
                Stepper("\(set.reps) reps", value: Binding(get: { set.reps }, set: { workout.correctLastSet(reps: $0) }), in: 0...100)
                    .fixedSize()
            }
            HStack(spacing: 16) {
                if let s = set.formScore { Label("Form \(s)", systemImage: "checkmark.seal") }
                if let v = set.meanSpeed { Label("\(Int(v))\(set.speedUnit)", systemImage: "speedometer") }
                if let vl = set.velocityLoss { Label("−\(Int(vl * 100))% speed", systemImage: "arrow.down.right").foregroundStyle(vl >= 0.3 ? Color.orange : Color.secondary) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("How hard was it? (RPE)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([6.0, 7.0, 8.0, 9.0, 10.0], id: \.self) { r in
                        Button {
                            // Tapping the selected RPE again clears it.
                            workout.setRPE(set.rpe == r ? nil : r)
                        } label: {
                            Text("\(Int(r))").font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .tint(set.rpe == r ? .accentColor : .gray)
                    }
                }
                Text("10 = nothing left · 9 = one more rep · 8 = two more · 6 = easy").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// Thin horizontal bar for a 0...1 value; turns green from 0.8 (the full-rep threshold).
struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(value >= 0.8 ? Color.green : Color.accentColor)
                    .frame(width: g.size.width * CGFloat(max(0, min(1, value))))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: value)
    }
}

/// A small card with an explanation and one action.
struct InfoCard: View {
    var title: String
    var text: String
    var button: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}
