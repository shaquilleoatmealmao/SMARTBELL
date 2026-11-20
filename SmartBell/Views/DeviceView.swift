import SwiftUI
import Charts
import UniformTypeIdentifiers

struct DeviceView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Coach.speakCountKey) private var speakCount = true
    @AppStorage(Coach.speakCuesKey) private var speakCues = true
    @AppStorage(Coach.hapticsKey) private var haptics = true
    @AppStorage(Coach.speakGuidanceKey) private var speakGuidance = true
    @State private var importing = false
    @State private var report: ReplayReport?
    @State private var replayError = false

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionCard().listRowInsets(EdgeInsets()) }

                if model.ble.status == .connected || model.ble.status == .disconnected {
                    Section { Button("Disconnect", role: .destructive) { model.ble.disconnect() } }
                }

                Section("Live sensor") {
                    LabeledContent("Forearm angle", value: "\(Int(model.live.beta))°")
                    LabeledContent("Sample rate", value: "\(Int(model.live.sampleRate.rounded())) Hz")
                    LabeledContent("Still", value: model.live.isStill ? "yes (learning gyro bias)" : "no")
                    LabeledContent("Body/elbow accel", value: String(format: "%.1f m/s²", model.live.linearAcceleration))
                    LabeledContent("Gyro bias", value: String(format: "%.1f, %.1f, %.1f °/s",
                                                              model.live.gyroBias.x, model.live.gyroBias.y, model.live.gyroBias.z))
                    if model.ble.malformedLines > 0 {
                        LabeledContent("Malformed lines", value: "\(model.ble.malformedLines)")
                    }
                    Chart(Array(model.live.angleHistory.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("t", Double(i) / 30.0), y: .value("deg", v))
                    }
                    .chartYScale(domain: 0...180)
                    .chartXAxis(.hidden)
                    .frame(height: 140)
                }

                Section {
                    if let c = model.calibration {
                        LabeledContent("Calibrated", value: c.date.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Your range", value: "\(Int(c.bottomDeg))° – \(Int(c.topDeg))°")
                    } else {
                        Text("Not calibrated")
                    }
                    Button("Calibrate") { model.startCalibration() }.disabled(!model.hasData)
                } header: { Text("Calibration") } footer: {
                    Text("Recalibrate whenever the strap is moved or re-tightened.")
                }

                Section {
                    Button {
                        model.toggleRecording()
                    } label: {
                        Label(model.recorder.isRecording ? "Stop recording (\(model.recorder.recordedSamples) samples)" : "Record raw data",
                              systemImage: model.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    }
                    .tint(model.recorder.isRecording ? .red : .accentColor)
                    ForEach(model.recorder.recordings, id: \.self) { url in
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent).font(.footnote.monospaced())
                            Spacer()
                            Button("Replay") { runReplay(url) }.buttonStyle(.borderless)
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        }
                    }
                    .onDelete { idx in idx.map { model.recorder.recordings[$0] }.forEach(model.recorder.delete) }
                    Button("Replay a CSV from Files…") { importing = true }
                } header: { Text("Recordings") } footer: {
                    Text("Recordings are the raw ESP32 rows plus your calibration. Replay runs them through the same rep counter, and tools/replay_csv.py does the same on a laptop for tuning.")
                }

                Section("Feedback") {
                    Toggle("Count reps out loud", isOn: $speakCount)
                    Toggle("Speak form cues", isOn: $speakCues)
                    Toggle("Speak workout guidance and rest timer", isOn: $speakGuidance)
                    Toggle("Vibrate", isOn: $haptics)
                }

                Section("How it works") {
                    Text("The forearm angle is measured against gravity, so it can't drift: the gyro gives smooth motion, the accelerometer keeps correcting it toward true down, and the gyro bias is re-learned every time you hold still. The 3D path of each rep is re-anchored when the rep starts, so errors never carry over from one rep to the next.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Device")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                if case .success(let url) = result { runReplay(url) }
            }
            .sheet(item: $report) { r in
                NavigationStack {
                    ReplayView(report: r).toolbar { Button("Done") { report = nil } }
                }
            }
            .alert("Couldn't replay that file", isPresented: $replayError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It needs rows of ax,ay,az,gx,gy,gz,dt_s, and either a calibration line in the file or a calibration on this phone.")
            }
        }
    }

    private func runReplay(_ url: URL) {
        if let r = model.replay(url) { report = r } else { replayError = true }
    }
}

struct ReplayView: View {
    var report: ReplayReport

    var body: some View {
        List {
            Section {
                LabeledContent("File", value: report.fileName)
                LabeledContent("Length", value: String(format: "%.1f s (%d samples)", report.duration, report.samples))
                LabeledContent("Reps counted", value: "\(report.reps.filter(\.counted).count)")
                LabeledContent("Partials", value: "\(report.reps.filter { !$0.counted }.count)")
                LabeledContent("Calibration", value: report.usedRecordedCalibration ? "from the recording" : "current phone calibration")
            }
            Section("Forearm angle") {
                Chart {
                    ForEach(Array(report.angles.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("s", Double(i) * 0.05), y: .value("deg", v))
                    }
                    ForEach(report.reps) { r in
                        RectangleMark(xStart: .value("s", r.startT), xEnd: .value("s", r.endT),
                                      yStart: .value("deg", 0), yEnd: .value("deg", 180))
                            .foregroundStyle((r.counted ? Color.green : Color.yellow).opacity(0.18))
                    }
                }
                .chartYScale(domain: 0...180)
                .frame(height: 180)
            }
            Section("Reps") {
                ForEach(report.reps) { r in
                    HStack {
                        RepPathThumbnail(rep: r).frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(String(format: "%.1f s · %@", r.startT, r.counted ? "counted" : "partial")).font(.subheadline.bold())
                            Text(r.issues.isEmpty ? "Good" : r.issues.map(\.label).joined(separator: ", ")).font(.caption)
                            Text(String(format: "lift %.1fs lower %.1fs · %d–%d° · twist %.0f° · sway %.0f° · swing %.1f",
                                        r.concentricSeconds, r.eccentricSeconds, Int(r.bottomDeg), Int(r.topDeg),
                                        r.twistRange, r.swayRange, r.swing))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ScoreRing(score: r.score, size: 34)
                    }
                }
            }
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
    }
}
