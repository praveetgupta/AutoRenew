import XCTest
@testable import AutoRenewCore

final class SchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(refreshDaysAgo: Double?, attemptMinutesAgo: Double? = nil, lastOK: Bool = false) -> AppEntry {
        AppEntry(name: "TestApp",
                 projectPath: "/tmp/TestApp.xcodeproj",
                 scheme: "TestApp",
                 lastSuccessfulRefresh: refreshDaysAgo.map { now.addingTimeInterval(-$0 * 86400) },
                 lastAttempt: attemptMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                 lastResultMessage: lastOK ? nil : "boom",
                 lastResultOK: lastOK)
    }

    func testDaysRemaining() {
        XCTAssertEqual(makeEntry(refreshDaysAgo: 3).daysRemaining(now: now) ?? -99, 4, accuracy: 1e-9)
        XCTAssertNil(makeEntry(refreshDaysAgo: nil).daysRemaining(now: now))
    }

    func testDueApps() {
        let settings = Settings.default
        let due = Scheduler.dueApps([makeEntry(refreshDaysAgo: 3), makeEntry(refreshDaysAgo: 5.5), makeEntry(refreshDaysAgo: nil)], settings: settings, now: now)
        XCTAssertEqual(due.count, 2)
    }

    func testUrgentApps() {
        let settings = Settings.default
        let urgent = Scheduler.urgentApps([makeEntry(refreshDaysAgo: 3), makeEntry(refreshDaysAgo: 5.5), makeEntry(refreshDaysAgo: 6.5), makeEntry(refreshDaysAgo: nil)], settings: settings, now: now)
        XCTAssertEqual(urgent.count, 1)
    }

    func testFreshness() {
        XCTAssertEqual(makeEntry(refreshDaysAgo: 3).freshness(now: now), .fresh)
        XCTAssertEqual(makeEntry(refreshDaysAgo: 5.5).freshness(now: now), .dueSoon)
        XCTAssertEqual(makeEntry(refreshDaysAgo: 8).freshness(now: now), .expired)
        XCTAssertEqual(makeEntry(refreshDaysAgo: nil).freshness(now: now), .unknown)
    }

    func testShouldAttemptBackoff() {
        XCTAssertFalse(Scheduler.shouldAttempt(makeEntry(refreshDaysAgo: nil, attemptMinutesAgo: 30, lastOK: false), now: now))
        XCTAssertTrue(Scheduler.shouldAttempt(makeEntry(refreshDaysAgo: nil, attemptMinutesAgo: 120, lastOK: false), now: now))
        XCTAssertTrue(Scheduler.shouldAttempt(makeEntry(refreshDaysAgo: nil, attemptMinutesAgo: nil, lastOK: false), now: now))
        XCTAssertTrue(Scheduler.shouldAttempt(makeEntry(refreshDaysAgo: nil, attemptMinutesAgo: 30, lastOK: true), now: now))
    }
}

final class FormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(refreshDaysAgo: Double?) -> AppEntry {
        AppEntry(name: "TestApp",
                 projectPath: "/tmp/TestApp.xcodeproj",
                 scheme: "TestApp",
                 lastSuccessfulRefresh: refreshDaysAgo.map { now.addingTimeInterval(-$0 * 86400) })
    }

    func testCountdown() {
        XCTAssertEqual(Format.countdown(makeEntry(refreshDaysAgo: nil), now: now), "never renewed")
        XCTAssertEqual(Format.countdown(makeEntry(refreshDaysAgo: 3), now: now), "4d 0h left")
        XCTAssertEqual(Format.countdown(makeEntry(refreshDaysAgo: 8), now: now), "expired 1d 0h ago")
    }
}

final class ParsingTests: XCTestCase {
    func testParseDevices() {
        let output = """
        Name                  Hostname                                    Identifier                              State          Model
        Sample iPhone        00008101-000A11BB.tcp.local                 00008101-000A11BB0123456E               available      iPhone15,2
        Bench Phone           00009101-000C99DD.local                     00009101-000C99DD0123456E               unavailable    iPhone13,4
        """
        let devices = DeviceMonitor.parseDevices(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?.name, "Sample iPhone")
        XCTAssertEqual(devices.first?.identifier, "00008101-000A11BB0123456E")
        XCTAssertEqual(devices.first?.isAvailable, true)
        XCTAssertEqual(devices.first?.isIPhone, true)
        XCTAssertEqual(devices.last?.isAvailable, false)
    }

    func testParseDevicesEmpty() {
        XCTAssertTrue(DeviceMonitor.parseDevices("No devices found.").isEmpty)
        XCTAssertTrue(DeviceMonitor.parseDevices("").isEmpty)
    }

    func testParseDevicesStateSpellings() {
        func state(_ raw: String, probed: Bool = false) -> Bool {
            DeviceInfo(name: "Phone", hostname: "h", identifier: "id", state: raw, model: "iPhone18,1",
                       probedReachable: probed).isAvailable
        }
        XCTAssertTrue(state("available"))
        XCTAssertTrue(state("available (wifi)"))
        XCTAssertTrue(state("connected"))
        XCTAssertTrue(state("Connected"))
        XCTAssertFalse(state("unavailable"))
        XCTAssertFalse(state("unavailable (wifi)"))
        XCTAssertFalse(state("connecting"))
        XCTAssertTrue(state("unavailable", probed: true)) // successful probe overrides the list state
    }

    func testDeviceKinds() {
        let phone = DeviceInfo(name: "Phone", hostname: "h", identifier: "1", state: "connected",
                               model: "iPhone18,1", deviceType: "iPhone", transport: "wired")
        let phoneLegacy = DeviceInfo(name: "Phone", hostname: "h", identifier: "2", state: "available", model: "iPhone15,2")
        let watch = DeviceInfo(name: "Watch", hostname: "h", identifier: "3", state: "unavailable",
                               model: "Watch6,11", deviceType: "appleWatch")
        XCTAssertTrue(phone.isIPhone && !phone.isWatch && phone.isWired && phone.connectionLabel == "USB")
        XCTAssertTrue(phoneLegacy.isIPhone && phoneLegacy.connectionLabel == "Wi-Fi")
        XCTAssertTrue(watch.isWatch && !watch.isIPhone && !watch.needsProbe)
        XCTAssertTrue(phone.needsProbe == false && phoneLegacy.needsProbe == false)
        let unreachablePhone = DeviceInfo(name: "Phone", hostname: "h", identifier: "4", state: "unavailable", model: "iPhone18,1")
        XCTAssertTrue(unreachablePhone.needsProbe)
    }

    private let devicesJSON = """
    {
      "info" : { "outcome" : "success" },
      "result" : {
        "devices" : [
          {
            "identifier" : "0A0B0C0D-0E0F-4A01-8B01-ABCDEF098765",
            "connectionProperties" : {
              "pairingState" : "paired",
              "tunnelState" : "unavailable",
              "potentialHostnames" : ["Sample-Watch.coredevice.local"]
            },
            "deviceProperties" : { "name" : "Sample Watch", "developerModeStatus" : "disabled" },
            "hardwareProperties" : { "deviceType" : "appleWatch", "productType" : "Watch6,11", "marketingName" : "Apple Watch SE" }
          },
          {
            "identifier" : "01020304-0506-4781-8901-ABCDEF012345",
            "connectionProperties" : {
              "pairingState" : "paired",
              "tunnelState" : "connected",
              "transportType" : "wired",
              "localHostnames" : ["Sample-iPhone.coredevice.local"]
            },
            "deviceProperties" : { "name" : "Sample iPhone", "developerModeStatus" : "enabled" },
            "hardwareProperties" : { "deviceType" : "iPhone", "productType" : "iPhone18,1", "marketingName" : "iPhone 17 Pro" }
          }
        ]
      }
    }
    """

    func testParseDevicesJSON() {
        guard let devices = DeviceMonitor.parseDevicesJSON(Data(devicesJSON.utf8)) else {
            return XCTFail("JSON devices should parse")
        }
        XCTAssertEqual(devices.count, 2)

        let watch = devices[0]
        XCTAssertEqual(watch.name, "Sample Watch")
        XCTAssertEqual(watch.identifier, "0A0B0C0D-0E0F-4A01-8B01-ABCDEF098765")
        XCTAssertEqual(watch.state, "unavailable")
        XCTAssertEqual(watch.displayName, "Apple Watch SE")
        XCTAssertFalse(watch.isAvailable)
        XCTAssertTrue(watch.isWatch)
        XCTAssertFalse(watch.isIPhone)
        XCTAssertEqual(watch.developerModeEnabled, false)

        let phone = devices[1]
        XCTAssertEqual(phone.name, "Sample iPhone")
        XCTAssertEqual(phone.hostname, "Sample-iPhone.coredevice.local")
        XCTAssertEqual(phone.state, "connected")
        XCTAssertTrue(phone.isAvailable)
        XCTAssertTrue(phone.isIPhone)
        XCTAssertTrue(phone.isWired)
        XCTAssertEqual(phone.connectionLabel, "USB")
        XCTAssertEqual(phone.developerModeEnabled, true)
    }

    func testParseDevicesJSONRejectsGarbage() {
        XCTAssertNil(DeviceMonitor.parseDevicesJSON(Data("not json".utf8)))
        XCTAssertNil(DeviceMonitor.parseDevicesJSON(Data("{}".utf8)))
    }

    func testParseIdentities() {
        let output = """
          1) 3F85A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8 "Apple Development: me@example.com (AB12CD34EF)"
          2) 84A7B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F809 "Apple Development: iOS Team (XY98765432)"
             2 valid identities found
        """
        let identities = Discovery.parseIdentities(output)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities.first?.teamID, "AB12CD34EF")
    }

    func testParseBuildSettings() {
        let output = """
        Build settings for action build and target TestApp:
            ACTION = build
            TARGET_BUILD_DIR = "/Users/me/Library/Developer/Xcode/DerivedData/TestApp-abc/Build/Products/Debug-iphoneos"
            FULL_PRODUCT_NAME = TestApp.app
            PRODUCT_BUNDLE_IDENTIFIER = com.me.TestApp
            DEVELOPMENT_TEAM = AB12CD34EF
        """
        let parsed = Discovery.parseBuildSettings(output)
        XCTAssertEqual(parsed["TARGET_BUILD_DIR"], "/Users/me/Library/Developer/Xcode/DerivedData/TestApp-abc/Build/Products/Debug-iphoneos")
        XCTAssertEqual(parsed["FULL_PRODUCT_NAME"], "TestApp.app")
        XCTAssertEqual(parsed["PRODUCT_BUNDLE_IDENTIFIER"], "com.me.TestApp")
    }

    func testParseSchemes() {
        let json = """
        {
          "project" : {
            "name" : "TestApp",
            "schemes" : ["TestApp", "TestAppTests"],
            "targets" : { }
          }
        }
        """
        XCTAssertEqual(Discovery.parseSchemes(fromListJSON: json), ["TestApp", "TestAppTests"])
        XCTAssertEqual(Discovery.defaultScheme(projectName: "TestApp", schemes: ["Helper", "TestApp", "TestAppTests"]), "TestApp")
        XCTAssertEqual(Discovery.defaultScheme(projectName: "Missing", schemes: ["A", "B"]), "A")
    }
}

final class RegistryTests: XCTestCase {
    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewTests-\(UUID().uuidString)")
    }

    func testRoundtrip() {
        let dir = tempDir()
        let registry = Registry(directory: dir)
        var app = AppEntry(name: "Persist", projectPath: "/tmp/Persist.xcodeproj", scheme: "Persist")
        app.lastSuccessfulRefresh = Date(timeIntervalSince1970: 1_700_000_000)
        registry.add(app)

        let reloaded = Registry(directory: dir)
        XCTAssertEqual(reloaded.apps.count, 1)
        XCTAssertEqual(reloaded.apps.first?.lastSuccessfulRefresh, app.lastSuccessfulRefresh)
        XCTAssertEqual(reloaded.apps.first?.id, app.id)
    }

    func testAddDeduplicatesByProjectPath() {
        let dir = tempDir()
        let registry = Registry(directory: dir)
        let first = AppEntry(name: "App", projectPath: "/tmp/App.xcodeproj", scheme: "Old")
        registry.add(first)
        registry.add(AppEntry(name: "App", projectPath: "/tmp/App.xcodeproj", scheme: "New"))

        let reloaded = Registry(directory: dir)
        XCTAssertEqual(reloaded.apps.count, 1)
        XCTAssertEqual(reloaded.apps.first?.scheme, "New")
        XCTAssertEqual(reloaded.apps.first?.id, first.id)
    }

    func testSettingsAndRemove() {
        let dir = tempDir()
        let registry = Registry(directory: dir)
        let app = AppEntry(name: "App", projectPath: "/tmp/App.xcodeproj", scheme: "App")
        registry.add(app)
        registry.updateSettings { $0.renewThresholdDays = 6 }
        XCTAssertEqual(Registry(directory: dir).settings.renewThresholdDays, 6)

        registry.remove(id: app.id)
        XCTAssertTrue(Registry(directory: dir).apps.isEmpty)
    }

    /// The menu-bar app and the CLI are separate long-lived readers of the same file.
    func testTwoInstancesShareTheFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewRegistry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = Registry(directory: dir)
        let cli = Registry(directory: dir)
        XCTAssertTrue(app.apps.isEmpty)

        cli.add(AppEntry(name: "AddedByCLI", projectPath: "/tmp/AddedByCLI.xcodeproj", scheme: "AddedByCLI"))
        XCTAssertEqual(app.apps.map { $0.name }, ["AddedByCLI"])

        app.add(AppEntry(name: "AddedByApp", projectPath: "/tmp/AddedByApp.xcodeproj", scheme: "AddedByApp"))
        XCTAssertEqual(Set(Registry(directory: dir).apps.map { $0.name }), ["AddedByCLI", "AddedByApp"])

        cli.updateSettings { $0.renewThresholdDays = 4 }
        XCTAssertEqual(app.settings.renewThresholdDays, 4)
    }
}

final class DeviceStateTests: XCTestCase {
    private func device(_ state: String, probed: Bool = false) -> DeviceInfo {
        DeviceInfo(name: "Phone", hostname: "h", identifier: "id", state: state, model: "iPhone18,1",
                   probedReachable: probed)
    }

    func testReachableStates() {
        XCTAssertTrue(device("available").isAvailable)
        XCTAssertTrue(device("available (wifi)").isAvailable)
        XCTAssertTrue(device("connected").isAvailable)
        XCTAssertTrue(device("Connected").isAvailable)
    }

    func testUnreachableStates() {
        XCTAssertFalse(device("unavailable").isAvailable)
        // "disconnected" contains "connected"; a substring test would call this reachable.
        XCTAssertFalse(device("disconnected").isAvailable)
        XCTAssertFalse(device("connecting").isAvailable)
        XCTAssertFalse(device("unknown").isAvailable)
    }

    func testProbeOverridesListedState() {
        XCTAssertTrue(device("unavailable", probed: true).isAvailable)
        XCTAssertTrue(device("disconnected", probed: true).isAvailable)
    }
}

/// Answers `devicectl list devices` from a fixed table and refuses everything else.
private struct StubRunner: ProcessRunning {
    let deviceTable: String

    func run(executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) -> ProcessResult {
        if arguments.first == "devicectl", arguments.dropFirst().first == "list" {
            return ProcessResult(exitCode: 0, stdout: deviceTable, stderr: "")
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "stub")
    }
}

private struct SilentNotifier: Notifying {
    func notify(title: String, body: String, urgent: Bool) {}
}

/// Lists one unreachable iPhone and counts how often it is probed.
private final class ProbeCountingRunner: ProcessRunning {
    let probeSucceeds: Bool
    private(set) var probeCount = 0

    init(probeSucceeds: Bool) {
        self.probeSucceeds = probeSucceeds
    }

    func run(executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) -> ProcessResult {
        if arguments.first == "devicectl", arguments.dropFirst().first == "list" {
            let table = """
            Name         Hostname                 Identifier                  State          Model
            Test Phone   test.coredevice.local    00008101-000A11BB0123456E   unavailable    iPhone15,2
            """
            return ProcessResult(exitCode: 0, stdout: table, stderr: "")
        }
        if arguments.first == "devicectl", arguments.dropFirst().first == "device" {
            probeCount += 1
            return ProcessResult(exitCode: probeSucceeds ? 0 : 1, stdout: "", stderr: "")
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "stub")
    }
}

final class ProbeCacheTests: XCTestCase {
    /// A phone that answered a probe must stay reachable for the rest of the cooldown. Dropping the
    /// result made a phone on Wi-Fi flip to "unreachable" seconds after a successful renewal.
    func testSuccessfulProbeSurvivesTheCooldown() {
        let runner = ProbeCountingRunner(probeSucceeds: true)
        let watcher = DeviceWatcher(runner: runner)

        XCTAssertEqual(watcher.refresh().first?.isAvailable, true)
        XCTAssertEqual(runner.probeCount, 1)

        // Second pass is inside the cooldown: no new probe, but the phone is still reachable.
        XCTAssertEqual(watcher.refresh().first?.isAvailable, true)
        XCTAssertEqual(runner.probeCount, 1)
    }

    func testFailedProbeIsAlsoRemembered() {
        let runner = ProbeCountingRunner(probeSucceeds: false)
        let watcher = DeviceWatcher(runner: runner)

        XCTAssertEqual(watcher.refresh().first?.isAvailable, false)
        XCTAssertEqual(watcher.refresh().first?.isAvailable, false)
        XCTAssertEqual(runner.probeCount, 1, "an unreachable phone must not be re-probed every pass")
    }

    func testCooldownExpiryAllowsANewProbe() {
        let runner = ProbeCountingRunner(probeSucceeds: true)
        let watcher = DeviceWatcher(runner: runner)
        watcher.probeCooldown = 0

        _ = watcher.refresh()
        _ = watcher.refresh()
        XCTAssertEqual(runner.probeCount, 2)
    }
}

final class ListedStateTests: XCTestCase {
    private func listedState(tunnelState: String, transport: String?, pairing: String) -> String? {
        let transportLine = transport.map { "\"transportType\" : \"\($0)\"," } ?? ""
        let json = """
        {
          "result" : {
            "devices" : [
              {
                "identifier" : "01020304-0506-4781-8901-ABCDEF012345",
                "connectionProperties" : {
                  "pairingState" : "\(pairing)",
                  \(transportLine)
                  "tunnelState" : "\(tunnelState)"
                },
                "deviceProperties" : { "name" : "Test Phone" },
                "hardwareProperties" : { "deviceType" : "iPhone", "productType" : "iPhone18,1" }
              }
            ]
          }
        }
        """
        return DeviceMonitor.parseDevicesJSON(Data(json.utf8))?.first?.listedState
    }

    /// An idle phone on Wi-Fi reports tunnelState "disconnected" while devicectl's own table calls
    /// it "available (paired)". Showing the raw tunnelState made AutoRenew contradict Xcode.
    func testIdleWiFiPhoneReadsAsAvailable() {
        XCTAssertEqual(listedState(tunnelState: "disconnected", transport: "localNetwork", pairing: "paired"),
                       "available (paired)")
    }

    func testLiveTunnelReadsAsConnected() {
        XCTAssertEqual(listedState(tunnelState: "connected", transport: "wired", pairing: "paired"), "connected")
    }

    func testNoTransportReadsAsUnavailable() {
        XCTAssertEqual(listedState(tunnelState: "unavailable", transport: nil, pairing: "paired"), "unavailable")
    }

    func testTableRowsKeepTheirOwnStateColumn() {
        let table = """
        Name         Hostname                 Identifier                  State          Model
        Test Phone   test.coredevice.local    00008101-000A11BB0123456E   available      iPhone15,2
        """
        XCTAssertEqual(DeviceMonitor.parseDevices(table).first?.listedState, "available")
    }
}

final class RenewServiceTests: XCTestCase {
    private static let deviceTable = """
    Name           Hostname                     Identifier                  State        Model
    Test Phone     test.coredevice.local        00008101-000A11BB0123456E   available    iPhone15,2
    """

    private func registryWithFreshApp() throws -> Registry {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewService-\(UUID().uuidString)")
        let registry = Registry(directory: dir)
        var entry = AppEntry(name: "Fresh", projectPath: "/tmp/Fresh.xcodeproj", scheme: "Fresh")
        entry.lastSuccessfulRefresh = Date()
        registry.add(entry)
        return registry
    }

    func testNoDeviceIsReportedSeparatelyFromNothingDue() throws {
        let registry = try registryWithFreshApp()
        let service = RenewService(registry: registry, runner: StubRunner(deviceTable: ""), notifier: SilentNotifier())
        XCTAssertEqual(service.run().result, .noDeviceAvailable)
    }

    func testNothingDueWhenAppsAreFresh() throws {
        let registry = try registryWithFreshApp()
        let service = RenewService(registry: registry, runner: StubRunner(deviceTable: Self.deviceTable), notifier: SilentNotifier())
        XCTAssertEqual(service.run().result, .nothingDue)
    }

    func testUnknownAppIDDoesNotRenewEverything() throws {
        let registry = try registryWithFreshApp()
        let service = RenewService(registry: registry, runner: StubRunner(deviceTable: Self.deviceTable), notifier: SilentNotifier())
        let pass = service.run(force: true, only: "not-a-real-id")
        XCTAssertEqual(pass.result, .nothingDue)
        XCTAssertTrue(pass.records.isEmpty)
    }
}

final class ProjectLocatorTests: XCTestCase {
    func testFindsNestedProject() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewLocator-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("Sub").appendingPathComponent("Demo.xcodeproj")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectLocator.resolveProject(fromPath: base.path), nested.path)
        XCTAssertEqual(ProjectLocator.resolveProject(fromPath: nested.path), nested.path)
        try? FileManager.default.removeItem(at: base)
    }
}
