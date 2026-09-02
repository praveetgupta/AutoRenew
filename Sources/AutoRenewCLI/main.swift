import Foundation
import AutoRenewCore

let version = AutoRenewConstants.version
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())
let registry = Registry()

func fatal(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> String {
    """
    AutoRenew \(version) — keeps free-signed iPhone apps alive by rebuilding + reinstalling them before the 7-day expiry.

    USAGE: autorenew <command>

    COMMANDS
      add <path> [options]   Register an Xcode project (.xcodeproj/.xcworkspace or a folder containing one)
                             options: --scheme NAME  --team TEAMID  --configuration NAME
      list                   Show registered apps with countdowns
      remove <name>          Unregister an app (does not touch the app on your iPhone)
      renew [--all] [--app NAME]   Renew due apps now (--all forces everything)
      devices                List iPhones/macOS devicectl sees
      threshold <1-7>        Days since last refresh before an app is renewed (default 5)
      doctor                 Verify this Mac is ready (Xcode, devices, signing identity, apps)
      selftest               Run built-in logic tests
      version                Print version
      help                   Show this help
    """
}

func findApp(matching query: String) -> AppEntry {
    let matches = registry.apps.filter {
        $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.name.lowercased().contains(query.lowercased())
    }
    guard let entry = matches.first else {
        fatal("No registered app matching '\(query)'. Registered: \(registry.apps.map { $0.name }.joined(separator: ", "))")
    }
    return entry
}

func cmdAdd(_ rest: [String]) {
    var positional: [String] = []
    var schemeOverride: String?
    var teamOverride: String?
    var configOverride: String?
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--scheme" where i + 1 < rest.count:
            schemeOverride = rest[i + 1]; i += 2
        case "--team" where i + 1 < rest.count:
            teamOverride = rest[i + 1]; i += 2
        case "--configuration" where i + 1 < rest.count:
            configOverride = rest[i + 1]; i += 2
        default:
            positional.append(rest[i]); i += 1
        }
    }
    guard let path = positional.first else {
        print("Usage: autorenew add <path-to-xcodeproj-or-folder> [--scheme NAME] [--team TEAMID] [--configuration NAME]")
        exit(1)
    }

    guard let project = ProjectLocator.resolveProject(fromPath: path) else {
        fatal("No .xcodeproj or .xcworkspace found at \(path)")
    }
    let tools = XcodeTools(runner: RealProcessRunner())
    let projectName = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent

    print("Discovering schemes for \(project)…")
    guard case .success(let schemes) = tools.listSchemes(projectPath: project), !schemes.isEmpty else {
        fatal("Could not list schemes. Ensure full Xcode is installed and selected (xcode-select -p), then retry.")
    }
    let scheme = schemeOverride ?? Discovery.defaultScheme(projectName: projectName, schemes: schemes)

    var bundleID: String?
    var detectedTeam: String?
    if case .success(let settings) = tools.buildSettings(projectPath: project, scheme: scheme, configuration: configOverride ?? registry.settings.configuration) {
        bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"]
        detectedTeam = settings["DEVELOPMENT_TEAM"]
    }

    let entry = AppEntry(name: projectName,
                         projectPath: project,
                         scheme: scheme,
                         bundleID: bundleID,
                         teamID: teamOverride ?? detectedTeam,
                         configuration: configOverride ?? registry.settings.configuration)
    registry.add(entry)

    print("✅ Added \(projectName)")
    print("   scheme: \(scheme)")
    print("   bundle: \(bundleID ?? "unknown")")
    print("   team:   \(teamOverride ?? detectedTeam ?? "(project default)")")
    let count = registry.apps.count
    print("   registered apps: \(count)")
    if count > 3 {
        print("⚠️  A free Apple ID keeps only 3 apps alive per device. Add a 2nd free Apple ID in Xcode → Settings → Accounts and split your apps across teams (each project keeps the team set in Xcode).")
    }
    print("It will be built & installed on the next device connect (or run: autorenew renew --all).")
}

func cmdList() {
    let apps = registry.apps
    if apps.isEmpty {
        print("No apps registered. Add one:  autorenew add /path/to/Project.xcodeproj")
        return
    }
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
    let now = Date()
    print(pad("NAME", 24) + " " + pad("SCHEME", 18) + " " + pad("STATE", 10) + " " + pad("COUNTDOWN", 20) + "LAST RESULT")
    for app in apps {
        let state: String
        switch app.freshness(now: now) {
        case .fresh: state = "fresh"
        case .dueSoon: state = "due soon"
        case .expired: state = "EXPIRED"
        case .unknown: state = "never"
        }
        let result: String
        if app.lastResultOK {
            result = "✓"
        } else if let message = app.lastResultMessage {
            result = "✗ " + String(message.prefix(60))
        } else {
            result = "—"
        }
        print(pad(app.name, 24) + " " + pad(app.scheme, 18) + " " + pad(state, 10) + " " + pad(Format.countdown(app, now: now), 20) + result)
    }
}

func cmdRemove(_ rest: [String]) {
    guard let query = rest.first else {
        print("Usage: autorenew remove <name>")
        exit(1)
    }
    let entry = findApp(matching: query)
    registry.remove(id: entry.id)
    print("✅ Removed \(entry.name) from AutoRenew (the app itself on your iPhone is untouched).")
}

func cmdRenew(_ rest: [String]) {
    var force = false
    var appName: String?
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--all", "-a", "--force", "-f":
            force = true; i += 1
        case "--app" where i + 1 < rest.count:
            appName = rest[i + 1]; i += 2
        default:
            appName = rest[i]; i += 1
        }
    }

    var onlyID: String?
    if let appName = appName {
        onlyID = findApp(matching: appName).id
    }

    print("Looking for iPhone…")
    let service = RenewService(registry: registry, notifier: LogNotifier())
    let records = service.run(force: force, only: onlyID, progress: { print($0) })

    guard !records.isEmpty else { return }
    var failures = 0
    for record in records {
        print((record.success ? "✅ " : "❌ ") + record.appName + " — " + record.message)
        if !record.success { failures += 1 }
    }
    exit(failures > 0 ? 1 : 0)
}

func cmdDevices() {
    print("Looking for devices (probing paired-but-unreachable iPhones)…")
    let devices = DeviceWatcher(runner: RealProcessRunner()).refresh()
    if devices.isEmpty {
        print("No devices found (connect the iPhone via USB, or ensure it is paired and on the same Wi-Fi; Developer Mode must be on).")
        exit(1)
    }
    for device in devices {
        let mode = device.developerModeEnabled.map { $0 ? " · Developer Mode on" : " · Developer Mode OFF" } ?? ""
        print("\(device.isAvailable ? "🟢" : "🔴") \(device.name) [\(device.displayName)] state=\(device.state) via=\(device.connectionLabel)\(mode) id=\(device.identifier)")
    }
}

func cmdThreshold(_ rest: [String]) {
    guard let raw = rest.first, let days = Double(raw), days >= 1, days <= 7 else {
        print("Usage: autorenew threshold <1-7>   (default 5 — renews when 5 of the 7 days are used)")
        exit(1)
    }
    registry.updateSettings { $0.renewThresholdDays = days }
    print("✅ Renew threshold set to \(days) day\(days == 1 ? "" : "s").")
}

func cmdDoctor() {
    let checks = Doctor.run(registry: registry)
    var allOK = true
    for check in checks {
        print("\(check.ok ? "✅" : "❌") \(check.name): \(check.detail)")
        if !check.ok { allOK = false }
    }
    exit(allOK ? 0 : 1)
}

switch command {
case "add": cmdAdd(rest)
case "list", "ls": cmdList()
case "remove", "rm": cmdRemove(rest)
case "renew": cmdRenew(rest)
case "devices": cmdDevices()
case "threshold": cmdThreshold(rest)
case "doctor": cmdDoctor()
case "selftest": exit(SelfTest.run() == 0 ? 0 : 1)
case "version", "--version", "-v": print("AutoRenew \(version)")
case "help", "--help", "-h": print(usage())
default:
    print("Unknown command: \(command)\n")
    print(usage())
    exit(1)
}
