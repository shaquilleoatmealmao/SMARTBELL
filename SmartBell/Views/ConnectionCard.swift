//
//  ConnectionCard.swift
//  SmartBell — Views
//
//  Reusable card showing whether sensor data is flowing, the sample rate, and buttons
//  to scan for the ESP32, connect to a found device, or start/stop the demo sensor.
//

import SwiftUI

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
            // Action buttons only when there's something to fix (no data) or the demo is on.
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
                // One button per SmartBell found by the scan.
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

    /// Status line; "connected but no data" usually means notifications haven't started.
    private var statusText: String {
        if model.isDemo { return "Demo sensor (simulated)" }
        if model.hasData { return model.ble.statusText }
        if model.ble.status == .connected { return "Connected, waiting for data…" }
        return model.ble.statusText
    }
}
