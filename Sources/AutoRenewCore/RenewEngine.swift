import Foundation

public struct RenewOutcome {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}

/// Rebuilds an app from source with a fresh provisioning signature and reinstalls it on the iPhone.
public final class RenewEngine {
    let runner: ProcessRunning

    public init(runner: ProcessRunning = RealProcessRunner()) {
        self.runner = runner
    }

    public func renew(_ entry: AppEntry, device: DeviceInfo, progress: @escaping (String) -> Void = { _ in }) -> RenewOutcome {
        let projectPath = entry.projectPath
        guard FileManager.default.fileExists(atPath: projectPath) else {
            return RenewOutcome(success: false, message: "Project not found: \(projectPath)")
        }

        let flag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"

        var buildArgs = ["xcodebuild", flag, projectPath,
                         "-scheme", entry.scheme,
                         "-configuration", entry.configuration,
                         "-destination", "id=\(device.identifier)",
                         "-allowProvisioningUpdates",
                         "-allowProvisioningDeviceRegistration",
                         "-quiet",
                         "build"]
        if let team = entry.teamID, !team.isEmpty {
            buildArgs.append("DEVELOPMENT_TEAM=\(team)")
        }

        progress("Building \(entry.name) for \(device.name)…")
        let build = runner.run(executable: "/usr/bin/xcrun", arguments: buildArgs, timeout: 1800)
        guard build.exitCode == 0 else {
            return RenewOutcome(success: false, message: "Build failed: \(Self.errorTail(build))")
        }

        let settingsArgs = ["xcodebuild", flag, projectPath,
                            "-scheme", entry.scheme,
                            "-configuration", entry.configuration,
                            "-destination", "generic/platform=iOS",
                            "-showBuildSettings"]
        let settings = runner.run(executable: "/usr/bin/xcrun", arguments: settingsArgs, timeout: 300)
        let dict = Discovery.parseBuildSettings(settings.stdout)
        guard let buildDir = dict["TARGET_BUILD_DIR"], let product = dict["FULL_PRODUCT_NAME"] else {
            return RenewOutcome(success: false, message: "Could not locate built product (TARGET_BUILD_DIR / FULL_PRODUCT_NAME missing)")
        }
        let appPath = buildDir + "/" + product
        guard FileManager.default.fileExists(atPath: appPath) else {
            return RenewOutcome(success: false, message: "Built product missing at \(appPath)")
        }

        progress("Installing \(product) on \(device.name)…")
        let install = runner.run(executable: "/usr/bin/xcrun",
                                 arguments: ["devicectl", "device", "install", "app", "--device", device.identifier, appPath],
                                 timeout: 600)
        guard install.exitCode == 0 else {
            return RenewOutcome(success: false, message: "Install failed: \(Self.errorTail(install))")
        }

        return RenewOutcome(success: true, message: "Installed \(product) on \(device.name)")
    }

    static func errorTail(_ result: ProcessResult, maxLines: Int = 30) -> String {
        let combined = result.stderr.isEmpty ? result.stdout : result.stderr + "\n" + result.stdout
        let lines = combined.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = lines.suffix(maxLines).joined(separator: " | ")
        return tail.isEmpty ? "exit code \(result.exitCode)" : String(tail.prefix(800))
    }
}
