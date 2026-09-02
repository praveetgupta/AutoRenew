import Foundation

public struct RenewRecord {
    public let appName: String
    public let success: Bool
    public let message: String

    public init(appName: String, success: Bool, message: String) {
        self.appName = appName
        self.success = success
        self.message = message
    }
}

/// One renewal pass: find the iPhone, renew every due app, update the registry, notify.
public final class RenewService {
    let registry: Registry
    let runner: ProcessRunning
    let notifier: Notifying

    public init(registry: Registry, runner: ProcessRunning = RealProcessRunner(), notifier: Notifying = SystemNotifier()) {
        self.registry = registry
        self.runner = runner
        self.notifier = notifier
    }

    @discardableResult
    public func run(force: Bool = false,
                    only entryID: String? = nil,
                    preFetchedDevices: [DeviceInfo]? = nil,
                    progress: @escaping (String) -> Void = { _ in }) -> [RenewRecord] {
        let now = Date()

        let devices: [DeviceInfo]
        if let preFetchedDevices = preFetchedDevices {
            devices = preFetchedDevices
        } else {
            devices = DeviceWatcher(runner: runner).refresh()
        }

        let available = devices.filter { $0.isAvailable }
        let iPhones = available.filter { $0.isIPhone }
        let others = available.filter { !$0.isIPhone && !$0.isWatch } // iPad etc. — never a watch
        guard let device = iPhones.first ?? others.first else {
            let urgent = Scheduler.urgentApps(registry.apps, settings: registry.settings, now: now)
            let names = urgent.map { $0.name }.joined(separator: ", ")
            if let phone = devices.first(where: { $0.isIPhone }) {
                progress("iPhone “\(phone.name)” is paired but not reachable right now (state: \(phone.state)). Unlock the iPhone once, make sure it is on the same Wi-Fi as this Mac, or plug it in via USB — AutoRenew retries automatically.")
                if !urgent.isEmpty {
                    notifier.notify(title: "AutoRenew — iPhone unreachable",
                                    body: "\(names) will expire soon. “\(phone.name)” is seen but not reachable: unlock the iPhone, check it is on the same Wi-Fi as this Mac, or plug it in via USB.",
                                    urgent: true)
                }
            } else {
                progress("No available iPhone found. Connect it via USB, or put it on the same Wi-Fi network as this Mac (previously paired).")
                if !urgent.isEmpty {
                    notifier.notify(title: "AutoRenew — connect your iPhone",
                                    body: "\(names) will expire soon. Plug the iPhone into this Mac or put it on the same Wi-Fi network.",
                                    urgent: true)
                }
            }
            return []
        }

        let targets: [AppEntry]
        if let entryID = entryID, let entry = registry.apps.first(where: { $0.id == entryID }) {
            targets = [entry]
        } else if force {
            targets = registry.apps
        } else {
            targets = Scheduler.dueApps(registry.apps, settings: registry.settings, now: now)
        }

        guard !targets.isEmpty else {
            progress("Nothing due — all apps are fresh.")
            return []
        }

        let engine = RenewEngine(runner: runner)
        var records: [RenewRecord] = []

        for entry in targets {
            if !force && entryID == nil && !Scheduler.shouldAttempt(entry, now: now) {
                progress("Skipping \(entry.name) (recent attempt failed; will retry later)")
                continue
            }

            var attempt = entry
            attempt.lastAttempt = Date()
            registry.update(attempt)

            progress("Renewing \(entry.name)…")
            let outcome = engine.renew(attempt, device: device, progress: progress)

            var finished = attempt
            finished.lastResultOK = outcome.success
            finished.lastResultMessage = outcome.message
            if outcome.success { finished.lastSuccessfulRefresh = Date() }
            registry.update(finished)

            Log.event("Renew \(entry.name): \(outcome.success ? "OK" : "FAILED") — \(outcome.message)")
            records.append(RenewRecord(appName: entry.name, success: outcome.success, message: outcome.message))
        }

        let ok = records.filter { $0.success }
        let failed = records.filter { !$0.success }
        if !ok.isEmpty {
            notifier.notify(title: "AutoRenew — refreshed \(ok.count) app\(ok.count == 1 ? "" : "s")",
                            body: ok.map { $0.appName }.joined(separator: ", "),
                            urgent: false)
        }
        if !failed.isEmpty {
            let body = failed.map { "\($0.appName): \($0.message)" }.joined(separator: "\n")
            notifier.notify(title: "AutoRenew — \(failed.count) renewal\(failed.count == 1 ? "" : "s") failed",
                            body: String(body.prefix(400)),
                            urgent: true)
        }
        return records
    }
}
