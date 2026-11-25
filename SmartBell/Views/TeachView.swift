//
//  TeachView.swift
//  SmartBell — Views
//
//  UI for teaching SmartBell a new exercise (logic: AppModel.handleTeaching +
//  Motion/ExerciseProfile.swift). Shows AppModel.teachStep: hold still → 3 reps →
//  learned / failed. Also defines TaughtExercisesSection for the Device tab.
//

import SwiftUI

/// "Teach SmartBell this exercise": hold the start position, do 3 reps, hold still.
struct TeachView: View {
    @EnvironmentObject var model: AppModel

    private var name: String { model.teachingExercise?.name ?? "this exercise" }

    /// Hide Cancel once teaching has succeeded (only Done is offered then).
    private var isDone: Bool {
        if case .done? = model.teachStep { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                switch model.teachStep {
                case .hold(let progress)?:
                    header(step: 1, title: "Start position",
                           text: "Get into the starting position for \(name), holding the weight, and keep still.")
                    ProgressRing(progress: progress, label: progress > 0 ? "Hold still…" : "Waiting for stillness")
                case .reps(let seconds, let level, let canFinish)?:
                    header(step: 2, title: "Do 3 reps",
                           text: "Your normal pace and full range. Then hold still at the start and it finishes by itself.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Movement").font(.caption).foregroundStyle(.secondary)
                        // Live motion meter so the user can see the sensor is picking up the movement.
                        ProgressBar(value: level)
                        Text(String(format: "%.0f s of movement", seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    Button("Done") { model.finishTeachingNow() }
                        .buttonStyle(.borderedProminent)
                        // Enabled after ~3 s of movement; otherwise it finishes itself after a pause.
                        .disabled(!canFinish)
                case .done(let p)?:
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green)
                    Text("Learned \(name)").font(.title2.bold()).multilineTextAlignment(.center)
                    VStack(spacing: 6) {
                        // Which channel was learned (arm angle vs up-down) and how reliable it is.
                        Label(p.summary, systemImage: p.channel == .orientation ? "angle" : "arrow.up.and.down")
                            .font(.headline)
                        Text(p.reliabilityNote).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("\(p.repsLearned) reps recognised").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("SmartBell will count this exercise from now on. Teach it again if you move the strap.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { model.dismissTeaching() } label: {
                        Text("Done").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                case .failed(let why)?:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(.orange)
                    Text(why).multilineTextAlignment(.center)
                    Button {
                        if let ex = model.teachingExercise { model.startTeaching(ex) }
                    } label: {
                        Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                case nil:
                    EmptyView()
                }
                Spacer()
                if !model.hasData {
                    Label("No sensor data. Check the connection.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .navigationTitle("Teach SmartBell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isDone {
                        Button("Cancel") { model.cancelTeaching() }
                    }
                }
            }
        }
    }

    /// Same step heading layout as CalibrationView.
    private func header(step: Int, title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Text("Step \(step) of 2").font(.subheadline.bold()).foregroundStyle(.secondary)
            Text(title).font(.largeTitle.bold())
            Text(text).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

/// Device tab section: which exercises SmartBell knows, with teach / re-teach / forget.
struct TaughtExercisesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            // Every exercise except curls (which use the calibration instead).
            ForEach(ExerciseLibrary.all.filter { !$0.sensorBuiltIn }) { ex in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ex.name)
                        if let p = model.profiles[ex.id] {
                            Text(p.summary).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not taught yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(model.profiles[ex.id] == nil ? "Teach" : "Re-teach") { model.startTeaching(ex) }
                        .buttonStyle(.bordered)
                        .disabled(!model.hasData)
                }
                .swipeActions {
                    if model.profiles[ex.id] != nil {
                        Button("Forget", role: .destructive) { model.forgetProfile(ex.id) }
                    }
                }
            }
        } header: {
            Text("SmartBell exercises")
        } footer: {
            Text("Curls work after the 15-second calibration. Any other exercise: tap Teach, hold the start position, do 3 reps. Arm-angle exercises (raises, push-ups, triceps) are tracked as precisely as curls; up-down exercises (squats, presses, rows) count reliably but range checks are approximate.")
        }
    }
}
