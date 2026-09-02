import Foundation
import UserNotifications

public protocol Notifying {
    func notify(title: String, body: String, urgent: Bool)
}

/// macOS notification center (works when running as a bundled .app; logs otherwise).
public struct SystemNotifier: Notifying {
    public init() {}

    public func notify(title: String, body: String, urgent: Bool) {
        Log.event("NOTIFY: \(title) — \(body)")
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if urgent { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.event("Notification failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Log-only notifier used by the CLI.
public struct LogNotifier: Notifying {
    public init() {}

    public func notify(title: String, body: String, urgent: Bool) {
        Log.event("NOTIFY: \(title) — \(body)")
    }
}

public enum NotifierArming {
    private static let delegate = NotificationCenterDelegate()

    public static func arm() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.event("Notification authorization granted=\(granted) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }
}

final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
