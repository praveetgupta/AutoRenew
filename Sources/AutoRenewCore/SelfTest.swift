import Foundation

/// Toolchain-independent test suite (runs even on machines without full Xcode / XCTest).
/// Run via: autorenew selftest
public enum SelfTest {
    public static func run() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if condition {
                print("✅ \(name)")
            } else {
                failures += 1
                print("❌ \(name)")
            }
        }

        // MARK: Scheduler math

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(refreshDaysAgo: Double?, attemptMinutesAgo: Double? = nil, lastOK: Bool = false) -> AppEntry {
            AppEntry(name: "TestApp",
                     projectPath: "/tmp/TestApp.xcodeproj",
                     scheme: "TestApp",
                     lastSuccessfulRefresh: refreshDaysAgo.map { now.addingTimeInterval(-$0 * 86400) },
                     lastAttempt: attemptMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                     lastResultMessage: lastOK ? nil : "boom",
                     lastResultOK: lastOK)
        }

        let settings = Settings.default
        check(abs((entry(refreshDaysAgo: 3).daysRemaining(now: now) ?? 0) - 4) < 1e-9, "daysRemaining 3d ago → 4d left")
        check(entry(refreshDaysAgo: nil).daysRemaining(now: now) == nil, "daysRemaining nil for never-renewed")
        check(Scheduler.dueApps([entry(refreshDaysAgo: 3), entry(refreshDaysAgo: 5.5), entry(refreshDaysAgo: nil)], settings: settings, now: now).count == 2, "dueApps picks never + past threshold")
        check(Scheduler.urgentApps([entry(refreshDaysAgo: 3), entry(refreshDaysAgo: 5.5), entry(refreshDaysAgo: 6.5), entry(refreshDaysAgo: nil)], settings: settings, now: now).count == 1, "urgentApps picks only near-expiry")
        check(entry(refreshDaysAgo: 3).freshness(now: now) == .fresh, "freshness fresh")
        check(entry(refreshDaysAgo: 5.5).freshness(now: now) == .dueSoon, "freshness dueSoon")
        check(entry(refreshDaysAgo: 8).freshness(now: now) == .expired, "freshness expired")
        check(entry(refreshDaysAgo: nil).freshness(now: now) == .unknown, "freshness unknown")
        check(!Scheduler.shouldAttempt(entry(refreshDaysAgo: nil, attemptMinutesAgo: 30, lastOK: false), now: now), "shouldAttempt backs off after recent failure")
        check(Scheduler.shouldAttempt(entry(refreshDaysAgo: nil, attemptMinutesAgo: 120, lastOK: false), now: now), "shouldAttempt retries after 1h")
        check(Scheduler.shouldAttempt(entry(refreshDaysAgo: nil, attemptMinutesAgo: 30, lastOK: true), now: now), "shouldAttempt always true after success")

        // MARK: Formatting

        check(Format.countdown(entry(refreshDaysAgo: nil), now: now) == "never renewed", "countdown never renewed")
        check(Format.countdown(entry(refreshDaysAgo: 3), now: now) == "4d 0h left", "countdown 4d 0h left")
        check(Format.countdown(entry(refreshDaysAgo: 8), now: now) == "expired 1d 0h ago", "countdown expired 1d 0h ago")

        // MARK: Device table parsing

        let devicectlOutput = """
        Name                  Hostname                                    Identifier                              State          Model
        Sample iPhone        00008101-000A11BB.tcp.local                 00008101-000A11BB0123456E               available      iPhone15,2
        Bench Phone           00009101-000C99DD.local                     00009101-000C99DD0123456E               unavailable    iPhone13,4
        """
        let devices = DeviceMonitor.parseDevices(devicectlOutput)
        check(devices.count == 2, "parseDevices finds 2 rows")
        check(devices.first?.name == "Sample iPhone", "parseDevices name column")
        check(devices.first?.identifier == "00008101-000A11BB0123456E", "parseDevices identifier column")
        check(devices.first?.isAvailable == true, "parseDevices available state")
        check(devices.last?.isAvailable == false, "parseDevices unavailable state")
        check(devices.first?.isIPhone == true, "parseDevices iPhone model")
        check(DeviceMonitor.parseDevices("No devices found.").isEmpty, "parseDevices empty output")

        // MARK: Device state semantics + JSON parsing

        func isAvail(_ raw: String, probed: Bool = false) -> Bool {
            DeviceInfo(name: "Phone", hostname: "h", identifier: "id", state: raw, model: "iPhone18,1",
                       probedReachable: probed).isAvailable
        }
        check(isAvail("available"), "state available → reachable")
        check(isAvail("available (wifi)"), "state available (wifi) → reachable")
        check(isAvail("connected"), "state connected → reachable")
        check(!isAvail("unavailable"), "state unavailable → not reachable")
        check(isAvail("unavailable", probed: true), "successful probe overrides unavailable")

        let watch = DeviceInfo(name: "Watch", hostname: "h", identifier: "3", state: "unavailable",
                               model: "Watch6,11", deviceType: "appleWatch")
        check(watch.isWatch && !watch.isIPhone && !watch.needsProbe, "watch detected, never probed")
        let unreachablePhone = DeviceInfo(name: "Phone", hostname: "h", identifier: "4", state: "unavailable", model: "iPhone18,1")
        check(unreachablePhone.needsProbe, "unreachable iPhone is probe-worthy")

        let devicesJSON = """
        {
          "info" : { "outcome" : "success" },
          "result" : {
            "devices" : [
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
        let jsonDevices = DeviceMonitor.parseDevicesJSON(Data(devicesJSON.utf8))
        check(jsonDevices?.count == 1, "parseDevicesJSON finds 1 device")
        check(jsonDevices?.first?.name == "Sample iPhone", "parseDevicesJSON name")
        check(jsonDevices?.first?.isAvailable == true, "parseDevicesJSON tunnelState connected → available")
        check(jsonDevices?.first?.isIPhone == true, "parseDevicesJSON deviceType iPhone")
        check(jsonDevices?.first?.isWired == true, "parseDevicesJSON transport wired → USB")
        check(jsonDevices?.first?.developerModeEnabled == true, "parseDevicesJSON developer mode")
        check(DeviceMonitor.parseDevicesJSON(Data("{}".utf8)) == nil, "parseDevicesJSON rejects empty object")

        // MARK: Identity parsing

        let securityOutput = """
          1) 3F85A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8 "Apple Development: me@example.com (AB12CD34EF)"
          2) 84A7B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F809 "Apple Development: iOS Team (XY98765432)"
             2 valid identities found
        """
        let identities = Discovery.parseIdentities(securityOutput)
        check(identities.count == 2, "parseIdentities finds 2")
        check(identities.first?.teamID == "AB12CD34EF", "parseIdentities extracts team ID")

        // MARK: Build settings parsing

        let settingsOutput = """
        Build settings for action build and target TestApp:
            ACTION = build
            TARGET_BUILD_DIR = "/Users/me/Library/Developer/Xcode/DerivedData/TestApp-abc/Build/Products/Debug-iphoneos"
            FULL_PRODUCT_NAME = TestApp.app
            PRODUCT_BUNDLE_IDENTIFIER = com.me.TestApp
            DEVELOPMENT_TEAM = AB12CD34EF
        """
        let parsed = Discovery.parseBuildSettings(settingsOutput)
        check(parsed["TARGET_BUILD_DIR"] == "/Users/me/Library/Developer/Xcode/DerivedData/TestApp-abc/Build/Products/Debug-iphoneos", "parseBuildSettings quoted value")
        check(parsed["FULL_PRODUCT_NAME"] == "TestApp.app", "parseBuildSettings plain value")
        check(parsed["PRODUCT_BUNDLE_IDENTIFIER"] == "com.me.TestApp", "parseBuildSettings bundle ID")

        // MARK: Scheme list JSON

        let listJSON = """
        {
          "project" : {
            "name" : "TestApp",
            "schemes" : ["TestApp", "TestAppTests"],
            "targets" : { }
          }
        }
        """
        check(Discovery.parseSchemes(fromListJSON: listJSON) == ["TestApp", "TestAppTests"], "parseSchemes JSON")
        check(Discovery.defaultScheme(projectName: "TestApp", schemes: ["Helper", "TestApp", "TestAppTests"]) == "TestApp", "defaultScheme prefers project name")

        // MARK: Project locator

        do {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewSelfTest-\(UUID().uuidString)")
            let nested = base.appendingPathComponent("Sub").appendingPathComponent("Demo.xcodeproj")
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let resolved = ProjectLocator.resolveProject(fromPath: base.path)
            check(resolved == nested.path, "ProjectLocator finds nested .xcodeproj")
            try? FileManager.default.removeItem(at: base)
        }

        // MARK: Registry persistence

        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoRenewSelfTest-\(UUID().uuidString)")
            let registry = Registry(directory: dir)
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            var app = AppEntry(name: "Persist", projectPath: "/tmp/Persist.xcodeproj", scheme: "Persist")
            app.lastSuccessfulRefresh = fixedDate
            registry.add(app)
            let reloaded = Registry(directory: dir)
            check(reloaded.apps.count == 1, "registry roundtrip count")
            check(reloaded.apps.first?.lastSuccessfulRefresh == fixedDate, "registry roundtrip date")
            check(reloaded.apps.first?.id == app.id, "registry roundtrip id")
            reloaded.updateSettings { $0.renewThresholdDays = 6 }
            check(Registry(directory: dir).settings.renewThresholdDays == 6, "registry settings roundtrip")
            reloaded.remove(id: app.id)
            check(Registry(directory: dir).apps.isEmpty, "registry remove")
            try? FileManager.default.removeItem(at: dir)
        }

        return failures
    }
}
