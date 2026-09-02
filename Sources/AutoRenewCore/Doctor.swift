import Foundation

public struct DoctorCheck {
    public let name: String
    public let ok: Bool
    public let detail: String

    public init(name: String, ok: Bool, detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }
}

public enum Doctor {
    public static func run(runner: ProcessRunning = RealProcessRunner(), registry: Registry? = nil) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let sel = runner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], timeout: 15)
        let devDir = sel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let selOK = sel.exitCode == 0 && !devDir.contains("CommandLineTools")
        checks.append(DoctorCheck(
            name: "Active developer directory",
            ok: selOK,
            detail: selOK
                ? devDir
                : "\(devDir.isEmpty ? sel.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : devDir) — fix with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        ))

        let xb = runner.run(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "-version"], timeout: 60)
        let xbVersion = xb.stdout.split(separator: "\n").first.map(String.init) ?? xb.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        checks.append(DoctorCheck(
            name: "xcodebuild",
            ok: xb.exitCode == 0,
            detail: xb.exitCode == 0 ? xbVersion : "unavailable — install full Xcode from the App Store"
        ))

        // One listing, reused below — devicectl is slow enough that asking it twice is noticeable.
        // Probing is worth the wait here: a Wi-Fi iPhone usually lists as disconnected or
        // unavailable, and only the probe says whether a renewal could actually reach it. Reporting
        // the unprobed state would tell the user their phone is unreachable when it is not.
        let listing = DeviceWatcher(runner: runner).listing()
        let devices = listing.devices
        let available = devices.filter { $0.isAvailable }
        let deviceSummary = devices.isEmpty
            ? "none seen"
            : devices.map { device in
                let reached = device.probedReachable ? "\(device.listedState), reachable when probed" : device.listedState
                return "\(device.name): \(reached) (\(device.displayName))"
            }.joined(separator: " · ")
        checks.append(DoctorCheck(
            name: "devicectl / devices",
            ok: listing.ranSuccessfully,
            detail: listing.ranSuccessfully
                ? "\(devices.count) device(s) seen, \(available.count) available — \(deviceSummary)"
                : "unavailable: \((listing.toolFailure ?? "unknown error").prefix(200))"
        ))

        if let phone = devices.first(where: { $0.isIPhone }) {
            if let devMode = phone.developerModeEnabled {
                checks.append(DoctorCheck(
                    name: "Developer Mode on \(phone.name)",
                    ok: devMode,
                    detail: devMode
                        ? "enabled"
                        : "disabled — enable it on the iPhone: Settings → Privacy & Security → Developer Mode (renewals cannot install apps without it)"
                ))
            }
        }

        let ids = runner.run(executable: "/usr/bin/security", arguments: ["find-identity", "-v", "-p", "codesigning"], timeout: 30)
        let identities = Discovery.parseIdentities(ids.stdout).filter { $0.displayName.contains("Apple Development") }
        checks.append(DoctorCheck(
            name: "Signing identity",
            ok: !identities.isEmpty,
            detail: identities.first.map { $0.displayName }
                ?? "none found — open Xcode once and build any project with your free Apple ID to create one"
        ))

        if let registry = registry {
            let apps = registry.apps
            let missing = apps.filter { !FileManager.default.fileExists(atPath: $0.projectPath) }
            checks.append(DoctorCheck(
                name: "Registered apps (\(apps.count))",
                ok: missing.isEmpty,
                detail: missing.isEmpty
                    ? "all project paths exist"
                    : "missing: " + missing.map { $0.projectPath }.joined(separator: ", ")
            ))
        }

        checks.append(DoctorCheck(
            name: "Apple ID in Xcode",
            ok: true,
            detail: "verify signed in: Xcode → Settings → Accounts (required for automatic provisioning)"
        ))

        return checks
    }
}
