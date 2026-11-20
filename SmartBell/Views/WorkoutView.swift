import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("exercise") private var exercise = Exercise.bicepCurl
    @AppStorage("weight") private var weight = 15.0
    @AppStorage("unit") private var unit = WeightUnit.lb
    @AppStorage("targetReps") private var targetReps = 10

    var body: some View {
        NavigationStack {
            Group {
                if model.activeSet != nil {
                    LiveSetView()
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            ConnectionCard()
                            if model.calibration == nil {
                                calibrateCard
                            } else {
                                setupCard
                                if model.hasData { previewCard }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(model.activeSet == nil ? "SmartBell" : model.activeSet!.exercise.rawValue)
            .navigationBarTitleDisplayMode(model.activeSet == nil ? .large : .inline)
            .sheet(isPresented: Binding(get: { model.lastFinishedSet != nil },
                                        set: { if !$0 { model.clearFinishedSet() } })) {
                if let s = model.lastFinishedSet {
                    NavigationStack {
                        SetSummaryView(set: s)
                            .toolbar { Button("Done") { model.clearFinishedSet() } }
                    }
                }
            }
        }
    }

    private var calibrateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Calibrate once", systemImage: "scope").font(.title3.bold())
            Text("Strap SmartBell to the back of your forearm, just below the elbow. Calibration takes about 15 seconds: let your arm hang still, then do three slow curls. Redo it if the strap moves.")
                .foregroundStyle(.secondary)
            Button {
                model.startCalibration()
            } label: {
                Text("Calibrate").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasData)
            if !model.hasData {
                Text("Connect the sensor or start the demo first.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Exercise", selection: $exercise) {
                ForEach(Exercise.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Weight").font(.headline)
                Spacer()
                Button { weight = max(0, weight - (unit == .lb ? 2.5 : 1)) } label: { Image(systemName: "minus.circle.fill") }
                Text(weight.formatted(.number.precision(.fractionLength(0...1)))).font(.title2.monospacedDigit().bold())
                    .frame(minWidth: 56)
                Button { weight += unit == .lb ? 2.5 : 1 } label: { Image(systemName: "plus.circle.fill") }
                Picker("Unit", selection: $unit) {
                    ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
            .font(.title2)

            Stepper(value: $targetReps, in: 1...50) {
                HStack {
                    Text("Target reps").font(.headline)
                    Spacer()
                    Text("\(targetReps)").font(.title2.monospacedDigit().bold())
                }
            }

            Button {
                model.startSet(exercise: exercise, weight: weight, unit: unit, targetReps: targetReps)
            } label: {
                Label("Start set", systemImage: "play.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasData)

            Text("Put the phone in your pocket. It counts out loud and buzzes after each rep; a cue is spoken when form slips.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live").font(.headline)
                Spacer()
                Text("\(Int(model.live.beta))°").font(.headline.monospacedDigit())
            }
            ArmModelView(hand: model.live.hand, path: model.live.currentPath, ghost: model.lastRep?.path ?? [],
                         bottomDeg: model.calibration?.bottomDeg ?? 8, topDeg: model.calibration?.topDeg ?? 140,
                         compact: true)
                .frame(height: 180)
            Button("Recalibrate") { model.startCalibration() }
                .font(.footnote)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// The screen during a set: big count, live arm, last rep feedback.
struct LiveSetView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDiscard = false

    var body: some View {
        if let set = model.activeSet {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(set.count)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: set.count)
                    Text("/ \(set.targetReps)").font(.title).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("\(set.weight.formatted(.number.precision(.fractionLength(0...1)))) \(set.unit.rawValue)")
                            .font(.title3.bold())
                        if set.isDemo { Text("DEMO DATA").font(.caption.bold()).foregroundStyle(.orange) }
                        if !model.hasData {
                            Label("No sensor data", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                ArmModelView(hand: model.live.hand, path: model.live.currentPath, ghost: model.lastRep?.path ?? [],
                             bottomDeg: model.calibration?.bottomDeg ?? 8, topDeg: model.calibration?.topDeg ?? 140,
                             warning: model.live.linearAcceleration > 4)
                    .frame(maxHeight: 280)

                if let r = model.lastRep {
                    RepCard(rep: r)
                        .transition(.opacity)
                        .id(r.id)
                } else {
                    Text("Start curling. Reps are counted on the way down.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 88)
                }

                Spacer(minLength: 0)

                Button {
                    model.endSet()
                } label: {
                    Label("End set", systemImage: "stop.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("Discard set", role: .destructive) { confirmDiscard = true }
                    .font(.footnote)
                    .confirmationDialog("Discard this set?", isPresented: $confirmDiscard) {
                        Button("Discard", role: .destructive) { model.discardSet() }
                    }
            }
            .padding()
            .animation(.easeOut(duration: 0.2), value: model.lastRep?.id)
        }
    }
}

/// Connection status + the actions to get data flowing.
struct ConnectionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.hasData ? Color.green : Color.orange).frame(width: 10, height: 10)
                Text(statusText).font(.headline)
                Spacer()
                if model.hasData {
                    Text("\(Int(model.live.sampleRate.rounded())) Hz").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !model.hasData || model.isDemo {
                HStack {
                    if !model.isDemo {
                        Button {
                            model.ble.scan()
                        } label: { Label("Find SmartBell", systemImage: "antenna.radiowaves.left.and.right") }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        model.isDemo ? model.stopDemo() : model.startDemo()
                    } label: { Label(model.isDemo ? "Stop demo" : "Try demo", systemImage: "play.circle") }
                    .buttonStyle(.bordered)
                }
                ForEach(model.ble.discovered, id: \.identifier) { p in
                    Button { model.ble.connect(p) } label: {
                        Label("Connect to \(p.name ?? "SmartBell")", systemImage: "link")
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var statusText: String {
        if model.isDemo { return "Demo sensor (simulated)" }
        if model.hasData { return model.ble.statusText }
        if model.ble.status == .connected { return "Connected, waiting for data…" }
        return model.ble.statusText
    }
}
