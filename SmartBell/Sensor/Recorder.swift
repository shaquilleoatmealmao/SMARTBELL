//
//  Recorder.swift
//  SmartBell — Sensor
//
//  Saves and loads raw sensor recordings (Device › Record). File layout:
//      # SmartBell recording v1
//      # calibration: {JSON of the Calibration in use}
//      ax,ay,az,gx,gy,gz,dt_s
//      0.123,9.801,...            ← one line per sample, exactly as the firmware sent it
//  Files live in Documents/Recordings/ and can be shared from the app.
//

import Foundation

/// Records the raw sensor stream to CSV (same columns the ESP32 sends) so sessions can be
/// replayed in the app or analysed with tools/replay_csv.py. The calibration in use is
/// written as a comment line so a replay reproduces exactly what the app saw.
@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var recordedSamples = 0

    private var lines: [String] = []        // CSV rows held in memory until stop()
    private var calibration: Calibration?
    private var startDate = Date()          // used in the file name

    /// Documents/Recordings, created on first use.
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { refresh() }

    func start(calibration: Calibration?) {
        lines.removeAll(keepingCapacity: true)
        self.calibration = calibration
        startDate = Date()
        recordedSamples = 0
        isRecording = true
    }

    func append(_ s: SensorSample) {
        guard isRecording else { return }
        lines.append(s.csvLine)
        recordedSamples = lines.count
        if lines.count > 100 * 60 * 30 { _ = stop() } // 30 min cap
    }

    /// Write the recording to disk. Returns the file URL, or nil if nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        guard !lines.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = Recorder.folder.appendingPathComponent("smartbell-\(f.string(from: startDate)).csv")
        var text = "# SmartBell recording v1\n"
        if let calibration, let json = try? JSONEncoder().encode(calibration),
           let s = String(data: json, encoding: .utf8) {
            text += "# calibration: \(s)\n"
        }
        text += "ax,ay,az,gx,gy,gz,dt_s\n"
        text += lines.joined(separator: "\n")
        text += "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lines.removeAll()
        refresh()
        return url
    }

    /// Re-list the recordings folder, newest first (file names start with the date).
    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Recorder.folder, includingPropertiesForKeys: nil)) ?? []
        recordings = urls.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Reads a recording (or any CSV of firmware rows). Lines that don't parse are skipped.
    static func load(_ url: URL) -> (calibration: Calibration?, samples: [SensorSample])? {
        // Needed for files picked from outside the app's sandbox (e.g. the Files app).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var cal: Calibration?
        var samples: [SensorSample] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# calibration:") {
                let json = line.dropFirst("# calibration:".count).trimmingCharacters(in: .whitespaces)
                cal = try? JSONDecoder().decode(Calibration.self, from: Data(json.utf8))
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("ax") { continue }
            if let s = SensorSample.parse(line) { samples.append(s) }
        }
        return (cal, samples)
    }
}
