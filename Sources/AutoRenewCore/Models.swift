import Foundation

public struct AppEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var projectPath: String
    public var scheme: String
    public var bundleID: String?
    public var teamID: String?
    public var configuration: String
    public var lastSuccessfulRefresh: Date?
    public var lastAttempt: Date?
    public var lastResultMessage: String?
    public var lastResultOK: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                projectPath: String,
                scheme: String,
                bundleID: String? = nil,
                teamID: String? = nil,
                configuration: String = "Debug",
                lastSuccessfulRefresh: Date? = nil,
                lastAttempt: Date? = nil,
                lastResultMessage: String? = nil,
                lastResultOK: Bool = false) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.scheme = scheme
        self.bundleID = bundleID
        self.teamID = teamID
        self.configuration = configuration
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastAttempt = lastAttempt
        self.lastResultMessage = lastResultMessage
        self.lastResultOK = lastResultOK
    }
}

public struct Settings: Codable, Equatable {
    /// Renew when this many days have passed since the last successful install (7-day certs, 2-day buffer).
    public var renewThresholdDays: Double
    /// Warn urgently when an app is this close to expiry and no device is reachable.
    public var urgentDays: Double
    public var configuration: String

    public init(renewThresholdDays: Double = 5, urgentDays: Double = 6, configuration: String = "Debug") {
        self.renewThresholdDays = renewThresholdDays
        self.urgentDays = urgentDays
        self.configuration = configuration
    }

    public static let `default` = Settings()
}

public struct DeviceInfo: Equatable {
    public var name: String
    public var hostname: String
    public var identifier: String
    public var state: String
    /// devicectl's own State column ("connected", "available (paired)", "unavailable"). `state`
    /// holds the raw tunnelState, which is useful in logs but misleading on screen — an idle phone
    /// on Wi-Fi reports "disconnected" there while devicectl calls it "available (paired)". Show
    /// this to people; keep `state` for diagnostics.
    public var listedState: String
    public var model: String
    public var marketingName: String?
    public var deviceType: String?
    public var transport: String?
    public var developerModeEnabled: Bool?
    public var probedReachable: Bool

    public init(name: String, hostname: String, identifier: String, state: String, model: String,
                listedState: String? = nil,
                marketingName: String? = nil, deviceType: String? = nil, transport: String? = nil,
                developerModeEnabled: Bool? = nil, probedReachable: Bool = false) {
        self.name = name
        self.hostname = hostname
        self.identifier = identifier
        self.state = state
        // The legacy table already prints devicectl's combined verdict in its State column, so
        // there is nothing to reconstruct on that path.
        self.listedState = listedState ?? state
        self.model = model
        self.marketingName = marketingName
        self.deviceType = deviceType
        self.transport = transport
        self.developerModeEnabled = developerModeEnabled
        self.probedReachable = probedReachable
    }

    /// devicectl spells the state differently depending on where it comes from: the JSON
    /// `tunnelState` is one of connected / disconnected / unavailable / connecting, while the legacy
    /// table prints "connected" for USB, "available" (sometimes "available (wifi)") for a reachable
    /// Wi-Fi device, and "unavailable" for a paired one that is not answering.
    ///
    /// Only the first word carries the meaning, so compare that rather than searching for a
    /// substring — "disconnected" contains "connected" and would otherwise read as reachable.
    public var isAvailable: Bool {
        if probedReachable { return true }
        let word = state.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return word == "available" || word == "connected"
    }

    public var isIPhone: Bool {
        if let deviceType = deviceType { return deviceType.caseInsensitiveCompare("iPhone") == .orderedSame }
        return model.lowercased().contains("iphone")
    }

    public var isWatch: Bool {
        if let deviceType = deviceType { return deviceType.lowercased().contains("watch") }
        return model.lowercased().contains("watch")
    }

    public var isWired: Bool {
        if let transport = transport { return transport.caseInsensitiveCompare("wired") == .orderedSame }
        return state.lowercased().hasPrefix("connected") // legacy table output: USB shows "connected"
    }

    public var connectionLabel: String { isWired ? "USB" : "Wi-Fi" }

    public var displayName: String { marketingName ?? model }

    /// Only iPhones matter for renewals; probe those that are paired but not currently reachable.
    public var needsProbe: Bool { !isAvailable && isIPhone }
}

public enum AppFreshness: Equatable {
    case unknown   // never renewed by AutoRenew
    case fresh
    case dueSoon
    case expired
}

public extension AppEntry {
    func daysRemaining(now: Date = Date(), validityDays: Double = 7) -> Double? {
        guard let last = lastSuccessfulRefresh else { return nil }
        return validityDays - now.timeIntervalSince(last) / 86400
    }

    func freshness(now: Date = Date(), validityDays: Double = 7) -> AppFreshness {
        guard let remaining = daysRemaining(now: now, validityDays: validityDays) else { return .unknown }
        if remaining <= 0 { return .expired }
        if remaining <= 2 { return .dueSoon }
        return .fresh
    }
}

public enum Format {
    public static func countdown(_ entry: AppEntry, now: Date = Date(), validityDays: Double = 7) -> String {
        guard let remaining = entry.daysRemaining(now: now, validityDays: validityDays) else { return "never renewed" }
        if remaining >= 0 {
            return duration(days: remaining) + " left"
        } else {
            return "expired " + duration(days: -remaining) + " ago"
        }
    }

    public static func duration(days: Double) -> String {
        let totalMinutes = Int(days * 24 * 60)
        let d = totalMinutes / (60 * 24)
        let h = (totalMinutes % (60 * 24)) / 60
        let m = totalMinutes % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

public enum AutoRenewConstants {
    public static let version = "1.3.2"
}
