import Foundation

public enum DeviceMonitor {
    static let linePattern = "^(.+?)\\s{2,}(\\S+)\\s{2,}([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f-]{25,})\\s{2,}(\\S+(?:\\s+\\([^)]*\\))?)\\s{2,}(.+?)\\s*$"

    /// Parses the legacy `xcrun devicectl list devices` table output (fallback path).
    public static func parseDevices(_ output: String) -> [DeviceInfo] {
        var devices: [DeviceInfo] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("Name") { continue }
            if !trimmed.contains(where: { $0.isLetter || $0.isNumber }) { continue } // dashed header rule
            if trimmed.lowercased().contains("no devices") { continue }

            let groups = RegexHelp.firstMatches(line, linePattern)
            guard groups.count >= 6 else { continue }
            let device = DeviceInfo(name: groups[1],
                                    hostname: groups[2],
                                    identifier: groups[3],
                                    state: groups[4].lowercased(),
                                    model: groups[5])
            if !devices.contains(where: { $0.identifier == device.identifier }) {
                devices.append(device)
            }
        }
        return devices
    }

    // MARK: - JSON output (the officially supported script interface)

    struct DeviceListJSON: Decodable {
        struct Info: Decodable { var outcome: String? }
        struct Payload: Decodable { var devices: [DeviceJSON]? }
        struct DeviceJSON: Decodable {
            var identifier: String?
            var connectionProperties: ConnectionProperties?
            var deviceProperties: DeviceProperties?
            var hardwareProperties: HardwareProperties?
        }
        struct ConnectionProperties: Decodable {
            var pairingState: String?
            var tunnelState: String?
            var transportType: String?
            var potentialHostnames: [String]?
            var localHostnames: [String]?
        }
        struct DeviceProperties: Decodable {
            var name: String?
            var developerModeStatus: String?
        }
        struct HardwareProperties: Decodable {
            var deviceType: String?
            var productType: String?
            var marketingName: String?
        }
        var info: Info?
        var result: Payload?
    }

    /// Parses the JSON written by `devicectl list devices --json-output <file>`.
    /// Returns nil when the payload isn't the expected shape (caller falls back to table parsing).
    public static func parseDevicesJSON(_ data: Data) -> [DeviceInfo]? {
        guard let decoded = try? JSONDecoder().decode(DeviceListJSON.self, from: data),
              let jsonDevices = decoded.result?.devices, !jsonDevices.isEmpty else { return nil }
        var devices: [DeviceInfo] = []
        for d in jsonDevices {
            guard let identifier = d.identifier, !identifier.isEmpty else { continue }
            let name = d.deviceProperties?.name
                ?? d.hardwareProperties?.marketingName
                ?? d.connectionProperties?.potentialHostnames?.first
                ?? identifier
            let hostname = d.connectionProperties?.localHostnames?.first
                ?? d.connectionProperties?.potentialHostnames?.first ?? ""
            let state = (d.connectionProperties?.tunnelState ?? "unknown").lowercased()
            let device = DeviceInfo(name: name,
                                    hostname: hostname,
                                    identifier: identifier,
                                    state: state,
                                    model: d.hardwareProperties?.productType ?? "",
                                    marketingName: d.hardwareProperties?.marketingName,
                                    deviceType: d.hardwareProperties?.deviceType,
                                    transport: d.connectionProperties?.transportType,
                                    developerModeEnabled: d.deviceProperties?.developerModeStatus.map {
                                        $0.caseInsensitiveCompare("enabled") == .orderedSame
                                    })
            if !devices.contains(where: { $0.identifier == device.identifier }) {
                devices.append(device)
            }
        }
        return devices.isEmpty ? nil : devices
    }
}

public final class DeviceWatcher {
    let runner: ProcessRunning
    private let probeLock = NSLock()
    private var lastProbeAttempt: [String: Date] = [:]

    /// How long a reachability probe of one device may take.
    public var probeTimeout: TimeInterval = 25
    /// Minimum interval between probes of the same device (unreachable phones are common;
    /// probing should not stall every pass).
    public var probeCooldown: TimeInterval = 300

    public init(runner: ProcessRunning = RealProcessRunner()) {
        self.runner = runner
    }

    /// Lists paired devices. Devices that are paired but show "unavailable" (typical for an iPhone
    /// on Wi-Fi only) are probed with a real connection attempt, which both verifies reachability
    /// and wakes the phone's network listener — this is what turns "visible but unavailable" into
    /// a working Wi-Fi renewal.
    @discardableResult
    public func refresh(probeUnreachable: Bool = true) -> [DeviceInfo] {
        var devices = listDevices()
        guard probeUnreachable else { return devices }

        let now = Date()
        for index in devices.indices where devices[index].needsProbe {
            let identifier = devices[index].identifier
            probeLock.lock()
            let last = lastProbeAttempt[identifier]
            probeLock.unlock()
            if let last, now.timeIntervalSince(last) < probeCooldown { continue }
            probeLock.lock()
            lastProbeAttempt[identifier] = now
            probeLock.unlock()

            if Self.probe(identifier: identifier, runner: runner, timeout: probeTimeout) {
                Log.event("Probe: \(devices[index].name) is reachable (list state was “\(devices[index].state)”)")
                devices[index].probedReachable = true
            } else {
                Log.event("Probe: \(devices[index].name) not reachable (list state “\(devices[index].state)”)")
            }
        }
        return devices
    }

    private func listDevices() -> [DeviceInfo] {
        let jsonFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autorenew-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonFile) }

        let result = runner.run(executable: "/usr/bin/xcrun",
                                arguments: ["devicectl", "list", "devices", "--json-output", jsonFile.path],
                                timeout: 90)
        if result.exitCode == 0, let data = try? Data(contentsOf: jsonFile),
           let parsed = DeviceMonitor.parseDevicesJSON(data) {
            return parsed
        }
        guard result.exitCode == 0 else {
            Log.event("devicectl failed (\(result.exitCode)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
            return []
        }
        return DeviceMonitor.parseDevices(result.stdout)
    }

    /// A real connection attempt. `devicectl device info details` forces CoreDevice to (re)connect
    /// to the paired device; over Wi-Fi this often succeeds even right after `list devices`
    /// reported the device as unavailable.
    public static func probe(identifier: String, runner: ProcessRunning, timeout: TimeInterval) -> Bool {
        let result = runner.run(executable: "/usr/bin/xcrun",
                                arguments: ["devicectl", "device", "info", "details", "--device", identifier],
                                timeout: timeout)
        return result.exitCode == 0
    }
}
