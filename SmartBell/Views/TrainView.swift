import SwiftUI

/// Home tab: this week at a glance, your workouts, and quick start.
struct TrainView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("unit") private var unit = WeightUnit.lb
    @State private var editing: WorkoutTemplate?

    var body: some View {
        NavigationStack {
            List {
                Section { WeekStrip().listRowInsets(EdgeInsets()) }

                Section {
                    ConnectionCard().listRowInsets(EdgeInsets())
                    if model.hasData && model.calibration == nil {
                        Button {
                            model.startCalibration()
                        } label: {
                            Label("Calibrate SmartBell (15 s) to track curls", systemImage: "scope")
                        }
                    }
                }

                Section {
                    ForEach(model.store.templates) { t in
                        TemplateRow(template: t, unit: unit) {
                            model.startWorkout(t, unit: unit)
                        }
                        .contextMenu {
                            Button { editing = t } label: { Label(t.builtIn ? "Copy and edit" : "Edit", systemImage: "pencil") }
                            if !t.builtIn {
                                Button(role: .destructive) { model.store.deleteTemplate(t.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .swipeActions {
                            Button { editing = t } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    Button {
                        editing = WorkoutTemplate(name: "My workout", items: [])
                    } label: {
                        Label("New workout", systemImage: "plus")
                    }
                } header: { Text("Workouts") } footer: {
                    Text("Press and hold, or swipe, to edit. Weights carry forward: after each session the app suggests next time's weight.")
                }

                Section("Quick start") {
                    ForEach(MuscleGroup.allCases, id: \.self) { g in
                        let exs = ExerciseLibrary.all.filter { $0.group == g }
                        if !exs.isEmpty {
                            DisclosureGroup(g.rawValue) {
                                ForEach(exs) { ex in
                                    Button { model.quickStart(ex, unit: unit) } label: { ExerciseRow(exercise: ex) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Train")
            .toolbar {
                Picker("Unit", selection: $unit) {
                    ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
            .sheet(item: $editing) { t in
                NavigationStack { TemplateEditorView(template: t) }
            }
        }
    }
}

struct TemplateRow: View {
    var template: WorkoutTemplate
    var unit: WeightUnit
    var start: () -> Void

    private var minutes: Int {
        let s = template.items.reduce(0.0) { $0 + Double($1.sets) * (Double($1.reps) * 3.5 + Double($1.restSeconds)) }
        return max(1, Int((s / 60).rounded()))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name).font(.headline)
                Text(template.items.compactMap { $0.exercise?.name }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(template.items.count) exercises · ~\(minutes) min")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: start) {
                Image(systemName: "play.fill").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .disabled(template.items.isEmpty)
        }
        .padding(.vertical, 4)
    }
}

struct ExerciseRow: View {
    var exercise: Exercise

    var body: some View {
        HStack {
            Text(exercise.name).foregroundStyle(.primary)
            Spacer()
            ForEach(exercise.tracking.filter { $0 != .manual }) { m in
                Image(systemName: m.symbol).foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

/// This week: workouts, reps, volume and the weekly streak.
struct WeekStrip: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("unit") private var unit = WeightUnit.lb

    var body: some View {
        let stats = FitnessStats(sessions: model.store.sessions)
        HStack(spacing: 0) {
            tile("\(stats.thisWeek.count)", "workouts")
            tile("\(stats.thisWeek.reduce(0) { $0 + $1.totalReps })", "reps")
            tile(compact(stats.thisWeek.reduce(0) { $0 + $1.volume(in: unit) }), "\(unit.rawValue) lifted")
            tile("\(stats.weekStreak)", "week streak")
        }
        .padding(.vertical, 12)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func compact(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.1fk", v / 1000) : String(Int(v.rounded()))
    }
}

/// Builds and edits a workout. Built-in workouts are saved as your own copy.
struct TemplateEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("unit") private var unit = WeightUnit.lb
    @State var template: WorkoutTemplate

    var body: some View {
        Form {
            Section("Name") {
                TextField("Workout name", text: $template.name)
            }
            Section {
                ForEach($template.items) { $item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.exercise?.name ?? item.exerciseId).font(.headline)
                        Stepper("Sets: \(item.sets)", value: $item.sets, in: 1...10)
                        Stepper("Reps: \(item.reps)", value: $item.reps, in: 1...50)
                        if item.exercise?.usesWeight ?? true {
                            Stepper("Weight: \(formatWeight(item.weight)) \(unit.rawValue)", value: $item.weight,
                                    in: 0...500, step: unit == .lb ? 2.5 : 1)
                        }
                        Stepper("Rest: \(item.restSeconds) s", value: $item.restSeconds, in: 15...300, step: 15)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { template.items.remove(atOffsets: $0) }
                .onMove { template.items.move(fromOffsets: $0, toOffset: $1) }

                Menu {
                    ForEach(ExerciseLibrary.all) { ex in
                        Button(ex.name) {
                            template.items.append(PlannedExercise(exerciseId: ex.id, sets: 3, reps: 10,
                                                                  weight: ex.usesWeight ? (unit == .lb ? 15 : 7) : 0,
                                                                  restSeconds: 90))
                        }
                    }
                } label: {
                    Label("Add exercise", systemImage: "plus")
                }
            } header: { Text("Exercises") }
        }
        .navigationTitle(template.builtIn ? "Copy of \(template.name)" : "Edit workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var t = template
                    if t.builtIn { t.id = UUID().uuidString }
                    model.store.saveTemplate(t)
                    dismiss()
                }
                .disabled(template.items.isEmpty || template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
    }
}
