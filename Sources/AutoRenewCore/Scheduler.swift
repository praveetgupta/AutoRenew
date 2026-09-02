import Foundation

public enum Scheduler {
    public static func ageDays(_ entry: AppEntry, now: Date) -> Double? {
        entry.lastSuccessfulRefresh.map { now.timeIntervalSince($0) / 86400 }
    }

    /// Days until the signature expires (nil = never renewed by AutoRenew).
    public static func daysRemaining(_ entry: AppEntry, now: Date, validityDays: Double = 7) -> Double? {
        ageDays(entry, now: now).map { validityDays - $0 }
    }

    /// Apps needing a renewal: never renewed, or the threshold-many days of the 7 already used.
    public static func dueApps(_ apps: [AppEntry], settings: Settings, now: Date) -> [AppEntry] {
        apps.filter { entry in
            guard let age = ageDays(entry, now: now) else { return true }
            return age >= settings.renewThresholdDays
        }
    }

    /// Apps about to expire — worth an urgent notification if no device is reachable.
    public static func urgentApps(_ apps: [AppEntry], settings: Settings, now: Date) -> [AppEntry] {
        apps.filter { entry in
            guard let age = ageDays(entry, now: now) else { return false }
            return age >= settings.urgentDays
        }
    }

    /// Avoid hammering a failing build more than once per hour.
    public static func shouldAttempt(_ entry: AppEntry, now: Date, minRetryInterval: TimeInterval = 3600) -> Bool {
        if entry.lastResultOK { return true }
        guard let last = entry.lastAttempt else { return true }
        return now.timeIntervalSince(last) >= minRetryInterval
    }
}
