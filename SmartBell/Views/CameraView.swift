import SwiftUI
import Charts

/// Camera tab: live body-pose skeleton, camera rep counting for any supported exercise,
/// and a SmartBell-vs-camera comparison for measuring the sensor's accuracy.
struct CameraView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var camera: PoseCamera
    @ObservedObject var lab: CameraLab
    @State private var savedComparison: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    countCard
                    anglesCard
                    compareCard
                }
                .padding()
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            camera.start()
            lab.isActive = true
        }
        .onDisappear {
            lab.isActive = false
            if lab.isMeasuring { savedComparison = lab.stopMeasuring() }
            camera.stop()
        }
    }

    // MARK: preview

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            CameraPreview(session: camera.session)
            SkeletonOverlay(frame: camera.frame, highlight: highlightedJoints)
            VStack(alignment: .trailing, spacing: 6) {
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").padding(10).background(.ultraThinMaterial, in: Circle())
                }
                if camera.status == .running {
                    Text("\(Int(camera.fps.rounded())) fps").font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(10)
            if let msg = statusMessage {
                Text(msg).font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusMessage: String? {
        switch camera.status {
        case .denied: return "Camera access is off.\nTurn it on in Settings › SmartBell."
        case .unavailable: return "Camera unavailable."
        case .starting, .idle: return "Starting camera…"
        case .running: return camera.frame == nil ? "Step into view" : nil
        }
    }

    private var highlightedJoints: Set<Joint> {
        switch lab.exercise.camera?.metric {
        case .forearmFromVertical?, .elbowFlexion?:
            return [.leftShoulder, .leftElbow, .leftWrist, .rightShoulder, .rightElbow, .rightWrist]
        case .kneeFlexion?:
            return [.leftHip, .leftKnee, .leftAnkle, .rightHip, .rightKnee, .rightAnkle]
        case .armRaise?:
            return [.leftHip, .leftShoulder, .leftElbow, .rightHip, .rightShoulder, .rightElbow]
        case nil:
            return []
        }
    }

    // MARK: counting

    private var countCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    ForEach(ExerciseLibrary.cameraExercises) { ex in
                        Button(ex.name) { lab.exercise = ex }
                    }
                } label: {
                    Label(lab.exercise.name, systemImage: "chevron.down").font(.headline)
                }
                Spacer()
                Button("Reset") { lab.resetCount() }.buttonStyle(.bordered)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(lab.counter?.count ?? 0)")
                    .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: lab.counter?.count ?? 0)
                Text("reps").foregroundStyle(.secondary)
                Spacer()
                if let a = lab.trackedAngle {
                    VStack(alignment: .trailing) {
                        Text("\(Int(a))°").font(.title2.bold().monospacedDigit())
                        Text(lab.exercise.camera?.metric.label ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ProgressBar(value: lab.counter?.progress ?? 0)
            if let r = lab.lastRep {
                Text(r.counted ? String(format: "Last rep: up %.1fs, down %.1fs", r.upSeconds, r.downSeconds)
                               : "Last rep was partial. Go through the full range.")
                    .font(.footnote).foregroundStyle(r.counted ? Color.secondary : Color.orange)
            }
            Text(lab.exercise.camera?.setupHint ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var anglesCard: some View {
        HStack(spacing: 0) {
            angle(lab.elbowAngle, "Elbow bend (camera)")
            angle(lab.forearmAngle, "Forearm (camera)")
            angle(lab.sensorAngle, "Forearm (SmartBell)")
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func angle(_ v: Double?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v.map { "\(Int($0))°" } ?? "–").font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: comparison

    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SmartBell vs camera").font(.headline)
            if lab.sensorAngle == nil {
                Text("Connect and calibrate the SmartBell to compare its forearm angle with the camera's. Stand side-on so your arm moves across the picture.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(lab.series.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("t", p.t), y: .value("deg", p.sensor), series: .value("Source", "SmartBell"))
                            .foregroundStyle(by: .value("Source", "SmartBell"))
                        LineMark(x: .value("t", p.t), y: .value("deg", p.camera), series: .value("Source", "Camera"))
                            .foregroundStyle(by: .value("Source", "Camera"))
                    }
                }
                .chartYScale(domain: 0...180)
                .chartXAxis(.hidden)
                .frame(height: 150)

                if lab.isMeasuring || lab.stats.n > 0 {
                    HStack(spacing: 0) {
                        angle(lab.stats.mean, "mean difference")
                        angle(lab.stats.rmse, "RMS error")
                        angle(lab.stats.maxAbs, "max error")
                    }
                    Text("\(lab.stats.n) paired frames").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button(lab.isMeasuring ? "Stop and save" : "Start measuring") {
                        if lab.isMeasuring { savedComparison = lab.stopMeasuring() } else { lab.startMeasuring() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(lab.isMeasuring ? .red : .accentColor)
                    if let url = savedComparison {
                        ShareLink(item: url) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                    }
                }
                Text("Camera angles are 2D, so they only match the sensor when your arm moves side-on to the camera. Use this to report the SmartBell's accuracy against an independent measurement.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}
