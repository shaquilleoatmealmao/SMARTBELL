import Foundation
import CoreBluetooth

/// CoreBluetooth connection to the SmartBell ESP32.
///
/// Firmware contract (firmware/smartbell-esp32/smartbell-esp32.ino):
///   advertises name "SmartBell" and service 7b7e0001-…
///   notify characteristic 7b7e0002-… sends newline-terminated CSV "ax,ay,az,gx,gy,gz,dt_s"
///   at ~100 Hz. Notifications may split or merge lines, so bytes are buffered until '\n'.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "7b7e0001-9d8b-4f2a-a2b0-5c4e1a000001")
    static let dataUUID = CBUUID(string: "7b7e0002-9d8b-4f2a-a2b0-5c4e1a000001")
    private static let lastDeviceKey = "lastSmartBellPeripheral"

    enum Status: Equatable {
        case bluetoothOff, unauthorized, unsupported, idle, scanning, connecting, connected, disconnected
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var discovered: [CBPeripheral] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var malformedLines = 0

    var onSample: ((SensorSample) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var buffer = Data()
    private var wantsConnection = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    var statusText: String {
        switch status {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth permission needed (Settings › SmartBell)"
        case .unsupported: "Bluetooth isn't available on this device"
        case .idle: "Not connected"
        case .scanning: "Searching for SmartBell…"
        case .connecting: "Connecting…"
        case .connected: "Connected to \(deviceName ?? "SmartBell")"
        case .disconnected: "Disconnected, reconnecting…"
        }
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        status = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        // Stop scanning after 15 s to save battery.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.status == .scanning else { return }
            self.central.stopScan()
            self.status = .idle
        }
    }

    func connect(_ p: CBPeripheral) {
        central.stopScan()
        wantsConnection = true
        peripheral = p
        p.delegate = self
        deviceName = p.name
        status = .connecting
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastDeviceKey)
        central.connect(p, options: nil)
    }

    func disconnect() {
        wantsConnection = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        status = .idle
    }

    /// Reconnect to the last SmartBell without scanning. iOS keeps the request open
    /// until the device is in range, so turning the ESP32 on is enough.
    private func reconnectToLast() {
        guard let s = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(p)
    }

    private func handle(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { malformedLines += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("ax") { continue }
            if let s = SensorSample.parse(Substring(trimmed)) { onSample?(s) } else { malformedLines += 1 }
        }
        if buffer.count > 512 { buffer.removeAll(keepingCapacity: true) }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                status = .idle
                reconnectToLast()
            case .poweredOff: status = .bluetoothOff
            case .unauthorized: status = .unauthorized
            case .unsupported: status = .unsupported
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
                discovered.append(peripheral)
            }
            // Only one SmartBell around (the usual case): connect straight away.
            if discovered.count == 1 && peripheral.identifier.uuidString ==
                UserDefaults.standard.string(forKey: Self.lastDeviceKey) {
                connect(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            status = .connected
            deviceName = peripheral.name ?? "SmartBell"
            buffer.removeAll()
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            status = .disconnected
            if wantsConnection { central.connect(peripheral, options: nil) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if wantsConnection {
                status = .disconnected
                central.connect(peripheral, options: nil)  // auto-reconnect (e.g. cable bumped)
            } else {
                status = .idle
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] where s.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.dataUUID], for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] where c.uuid == Self.dataUUID {
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { handle(data) }
    }
}
