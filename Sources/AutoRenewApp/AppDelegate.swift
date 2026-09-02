import Cocoa
import ServiceManagement
import AutoRenewCore

final class AtomicFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Returns true only if the flag transitioned (was unset).
    @discardableResult
    func set(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = value != newValue
        value = newValue
        return changed
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let registry = Registry()
    private let watcher = DeviceWatcher(runner: RealProcessRunner())
    private var statusItem: NSStatusItem?
    private var devices: [DeviceInfo] = []
    private let busy = AtomicFlag()
    private weak var deviceHeaderItem: NSMenuItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarImage()
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        NotifierArming.arm()

        let timer = Timer(timeInterval: 900, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck(after: 10)
        }

        Log.event("AutoRenew launched")
        scheduleCheck(after: 5)

        if ProcessInfo.processInfo.environment["AUTORENEW_SMOKE_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }

    @objc private func timerFired() {
        scheduleCheck(after: 0)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.autoCheck(force: false)
        }
    }

    // MARK: - Renewal passes

    private func autoCheck(force: Bool) {
        guard busy.set(true) else { return }
        DispatchQueue.global(qos: force ? .userInitiated : .utility).async { [weak self] in
            guard let self = self else { return }
            let devices = self.watcher.refresh()
            let service = RenewService(registry: self.registry, notifier: SystemNotifier())
            _ = service.run(force: force, preFetchedDevices: devices, progress: { Log.event($0) })
            DispatchQueue.main.async {
                self.devices = devices
                self.busy.set(false)
                self.refreshIcon()
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildItems(into: menu)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let devices = self.watcher.refresh()
            DispatchQueue.main.async {
                self.devices = devices
                self.refreshIcon()
                // The menu is already open — update the status line in place.
                self.deviceHeaderItem?.title = self.deviceStatusLine()
                self.deviceHeaderItem?.toolTip = self.deviceToolTip()
            }
        }
    }

    /// One-line iPhone status for the menu header.
    private func deviceStatusLine() -> String {
        let reachableIPhone = devices.first { $0.isAvailable && $0.isIPhone }
        let reachableOther = devices.first { $0.isAvailable && !$0.isWatch }
        if let device = reachableIPhone ?? reachableOther {
            return "iPhone connected: \(device.name) (\(device.connectionLabel))"
        }
        if let seen = devices.first(where: { $0.isIPhone }) {
            return "iPhone seen but unreachable: \(seen.name) — wake it or plug in"
        }
        if !devices.isEmpty {
            return "iPhone: not detected"
        }
        return "iPhone: not detected"
    }

    private func deviceToolTip() -> String {
        guard !devices.isEmpty else { return "No paired devices visible to devicectl" }
        return devices.map { "\($0.name) — \($0.state) (\($0.displayName))" }.joined(separator: "\n")
    }

    private func buildItems(into menu: NSMenu) {
        let now = Date()

        let header = NSMenuItem(title: deviceStatusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = deviceToolTip()
        menu.addItem(header)
        deviceHeaderItem = header
        menu.addItem(.separator())

        if registry.apps.isEmpty {
            let hint = NSMenuItem(title: "No apps registered — use “Add App…”", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else {
            for entry in registry.apps {
                let symbol: String
                switch entry.freshness(now: now) {
                case .fresh: symbol = "✅"
                case .dueSoon: symbol = "⚠️"
                case .expired: symbol = "❌"
                case .unknown: symbol = "❔"
                }
                let row = NSMenuItem(title: "\(symbol) \(entry.name) — \(Format.countdown(entry, now: now))", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())

        menu.addItem(item("Renew all now", #selector(renewAllNow(_:))))
        if !registry.apps.isEmpty {
            let sub = NSMenu()
            for entry in registry.apps {
                let subItem = NSMenuItem(title: entry.name, action: #selector(renewOne(_:)), keyEquivalent: "")
                subItem.representedObject = entry.id
                subItem.target = self
                sub.addItem(subItem)
            }
            let holder = NSMenuItem(title: "Renew specific app", action: nil, keyEquivalent: "")
            holder.submenu = sub
            menu.addItem(holder)
        }
        menu.addItem(.separator())

        menu.addItem(item("Add App…", #selector(addApp(_:))))
        if !registry.apps.isEmpty {
            let sub = NSMenu()
            for entry in registry.apps {
                let subItem = NSMenuItem(title: entry.name, action: #selector(removeOne(_:)), keyEquivalent: "")
                subItem.representedObject = entry.id
                subItem.target = self
                sub.addItem(subItem)
            }
            let holder = NSMenuItem(title: "Remove app", action: nil, keyEquivalent: "")
            holder.submenu = sub
            menu.addItem(holder)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = isLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Open Log", #selector(openLog(_:))))
        menu.addItem(item("Run Doctor", #selector(runDoctor(_:))))
        menu.addItem(item("Troubleshoot Device…", #selector(troubleshootDevice(_:))))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AutoRenew", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // MARK: - Actions

    @objc private func renewAllNow(_ sender: Any?) {
        autoCheck(force: true)
    }

    @objc private func renewOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard busy.set(true) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let devices = self.watcher.refresh()
            let service = RenewService(registry: self.registry, notifier: SystemNotifier())
            _ = service.run(force: true, only: id, preFetchedDevices: devices, progress: { Log.event($0) })
            DispatchQueue.main.async {
                self.busy.set(false)
                self.refreshIcon()
            }
        }
    }

    @objc private func addApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an .xcodeproj/.xcworkspace (or a folder containing one)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = url.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.registerApp(fromPath: chosen)
            DispatchQueue.main.async { self.showResult(result) }
        }
    }

    private func registerApp(fromPath path: String) -> Result<String, ToolError> {
        guard let project = ProjectLocator.resolveProject(fromPath: path) else {
            return .failure(ToolError(message: "No .xcodeproj or .xcworkspace found in \(path)"))
        }
        let tools = XcodeTools(runner: RealProcessRunner())
        let projectName = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent
        guard case .success(let schemes) = tools.listSchemes(projectPath: project), !schemes.isEmpty else {
            return .failure(ToolError(message: "Could not list schemes for \(project). Ensure full Xcode is installed and selected."))
        }
        let scheme = Discovery.defaultScheme(projectName: projectName, schemes: schemes)
        var bundleID: String?
        var team: String?
        if case .success(let settings) = tools.buildSettings(projectPath: project, scheme: scheme, configuration: registry.settings.configuration) {
            bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"]
            team = settings["DEVELOPMENT_TEAM"]
        }
        let entry = AppEntry(name: projectName,
                             projectPath: project,
                             scheme: scheme,
                             bundleID: bundleID,
                             teamID: team,
                             configuration: registry.settings.configuration)
        registry.add(entry)
        let count = registry.apps.count
        var text = "Added “\(projectName)”\nscheme: \(scheme)\nbundle: \(bundleID ?? "unknown")\nteam: \(team ?? "(project default)")\nRegistered apps: \(count)"
        if count > 3 {
            text += "\n\n⚠️ Free Apple ID limit: 3 apps alive per device. Add a 2nd free Apple ID in Xcode → Settings → Accounts and split your apps across teams."
        }
        return .success(text)
    }

    private func showResult(_ result: Result<String, ToolError>) {
        let alert = NSAlert()
        switch result {
        case .success(let message):
            alert.alertStyle = .informational
            alert.messageText = "App registered"
            alert.informativeText = message
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Could not add app"
            alert.informativeText = error.message
        }
        alert.runModal()
    }

    @objc private func removeOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        registry.remove(id: id)
        refreshIcon()
    }

    private var isLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            showAlert("Launch at Login becomes available once AutoRenew.app is installed in /Applications (run install.sh).")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Login item error: \(error.localizedDescription)")
        }
    }

    @objc private func openLog(_ sender: Any?) {
        Log.event("Log opened")
        NSWorkspace.shared.open(Log.logURL)
    }

    @objc private func runDoctor(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let checks = Doctor.run(registry: self.registry)
            DispatchQueue.main.async {
                let alert = NSAlert()
                let failures = checks.filter { !$0.ok }
                alert.alertStyle = failures.isEmpty ? .informational : .warning
                alert.messageText = failures.isEmpty ? "Doctor: all good ✅" : "Doctor: \(failures.count) issue(s) ⚠️"
                alert.informativeText = checks.map { "\($0.ok ? "✅" : "❌") \($0.name)\n    \($0.detail)" }.joined(separator: "\n")
                alert.runModal()
            }
        }
    }

    @objc private func troubleshootDevice(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let devices = self.watcher.refresh()
            DispatchQueue.main.async {
                self.devices = devices
                self.refreshIcon()
                self.deviceHeaderItem?.title = self.deviceStatusLine()

                let alert = NSAlert()
                alert.alertStyle = devices.contains(where: { $0.isAvailable }) ? .informational : .warning
                alert.messageText = "iPhone connectivity"

                var lines = devices.isEmpty
                    ? ["devicectl sees no paired devices."]
                    : devices.map { "• \($0.name) (\($0.displayName)) — \($0.state)\n    via \($0.connectionLabel), id \($0.identifier)" }
                if !devices.contains(where: { $0.isAvailable && $0.isIPhone }) {
                    lines.append("")
                    lines.append("To make Wi-Fi renewals work:")
                    lines.append("1. Unlock the iPhone once — a sleeping phone can drop off Wi-Fi.")
                    lines.append("2. Put the Mac and iPhone on the same Wi-Fi network (no guest network, VPN off).")
                    lines.append("3. Connect the iPhone by USB, select it in Finder and enable")
                    lines.append("   “Show this iPhone when on Wi-Fi”.")
                    lines.append("4. Leave the iPhone on charge — Wi-Fi renewals are most reliable while it charges.")
                    lines.append("5. If it still shows unavailable, plug it in by USB once and run Renew all now.")
                }
                alert.informativeText = lines.joined(separator: "\n")
                alert.runModal()
            }
        }
    }

    // MARK: - Icon

    /// The custom refresh glyph rendered by make_icon.swift (white on transparent, template-style),
    /// falling back to the system symbol when running outside an installed bundle.
    private static func menuBarImage() -> NSImage? {
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "MenuBar", withExtension: "png"),
           let custom = NSImage(contentsOf: url) {
            custom.size = NSSize(width: 18, height: 18)
            image = custom
        } else {
            image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "AutoRenew")
        }
        image?.isTemplate = true
        return image
    }

    private func refreshIcon() {
        let now = Date()
        let apps = registry.apps
        let color: NSColor
        if apps.isEmpty {
            color = .systemGray
        } else if apps.contains(where: { $0.freshness(now: now) == .expired }) {
            color = .systemRed
        } else if devices.first(where: { $0.isAvailable }) == nil && apps.contains(where: { $0.freshness(now: now) != .fresh }) {
            color = .systemOrange
        } else if apps.contains(where: { $0.freshness(now: now) != .fresh }) {
            color = .systemYellow
        } else {
            color = .systemGreen
        }
        statusItem?.button?.contentTintColor = color
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "AutoRenew"
        alert.informativeText = message
        alert.runModal()
    }
}
