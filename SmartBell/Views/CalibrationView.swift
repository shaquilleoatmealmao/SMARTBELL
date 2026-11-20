import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch model.calibrationStep {
                case .hang(let progress)?:
                    step(number: 1, title: "Let your arm hang",
                         text: "Hold the dumbbell, arm straight down by your side, relaxed. Stay still for 2 seconds.")
                    ProgressRing(progress: progress, label: progress > 0 ? "Hold still…" : "Waiting for stillness")
                case .curls(let count, let angle)?:
                    step(number: 2, title: "Do 3 slow curls",
                         text: "Full range: all the way up, all the way down. About 2 seconds up and 2 seconds down.")
                    HStack(spacing: 18) {
                        ForEach(0..<Calibrator.curlsNeeded, id: \.self) { i in
                            Image(systemName: i < count ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 44))
                                .foregroundStyle(i < count ? .green : .secondary)
                        }
                    }
                    Text("\(Int(angle))°").font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("forearm angle").font(.caption).foregroundStyle(.secondary)
                    if count >= 2 {
                        Button("Finish with \(count) curls") { model.finishCalibrationNow() }
                    }
                case .done?:
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green)
                    Text("Calibrated").font(.title.bold())
                    if let c = model.calibration {
                        Text("Your range: \(Int(c.bottomDeg))° to \(Int(c.topDeg))°")
                            .foregroundStyle(.secondary)
                    }
                    Button { model.dismissCalibration() } label: {
                        Text("Done").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                case .failed(let why)?:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.orange)
                    Text(why).multilineTextAlignment(.center)
                    Button { model.startCalibration() } label: {
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
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.calibrationStep != .done {
                        Button("Cancel") { model.cancelCalibration() }
                    }
                }
            }
        }
    }

    private func step(number: Int, title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Text("Step \(number) of 2").font(.subheadline.bold()).foregroundStyle(.secondary)
            Text(title).font(.largeTitle.bold())
            Text(text).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.blue.opacity(0.15), lineWidth: 14)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
            Text(label).font(.headline).multilineTextAlignment(.center).padding()
        }
        .frame(width: 180, height: 180)
    }
}
