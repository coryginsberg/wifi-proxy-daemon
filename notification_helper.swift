import AppKit
import Foundation
import UserNotifications

@main
struct WiFiProxyNotifier {
    static func main() {
        _ = NSApplication.shared

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--request-permission") {
            requestPermission(sendConfirmation: true)
            return
        }

        guard let payload = NotificationPayload(arguments: arguments) else {
            fputs("Usage: WiFiProxyNotifier --request-permission | --notify --title <title> --subtitle <subtitle> --body <body>\n", stderr)
            exit(2)
        }

        deliverNotification(payload)
    }

    private static func requestPermission(sendConfirmation: Bool) {
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)
        var didGrantAuthorization = false

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                fputs("Failed to request notification authorization: \(error)\n", stderr)
            }

            didGrantAuthorization = granted
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 10)

        guard sendConfirmation, didGrantAuthorization else {
            return
        }

        let payload = NotificationPayload(
            title: "Wi-Fi Proxy",
            subtitle: "Notifications enabled",
            body: "System notifications are ready for proxy state changes."
        )
        deliverNotification(payload)
    }

    private static func deliverNotification(_ payload: NotificationPayload) {
        let center = UNUserNotificationCenter.current()
        let authorizationSemaphore = DispatchSemaphore(value: 0)
        var authorizationStatus: UNAuthorizationStatus = .notDetermined

        center.getNotificationSettings { settings in
            authorizationStatus = settings.authorizationStatus
            authorizationSemaphore.signal()
        }

        _ = authorizationSemaphore.wait(timeout: .now() + 10)

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            postNotification(payload, center: center)
        case .notDetermined:
            let permissionSemaphore = DispatchSemaphore(value: 0)
            var didGrantAuthorization = false

            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    fputs("Failed to request notification authorization: \(error)\n", stderr)
                }

                didGrantAuthorization = granted
                permissionSemaphore.signal()
            }

            _ = permissionSemaphore.wait(timeout: .now() + 10)

            if didGrantAuthorization {
                postNotification(payload, center: center)
            }
        case .denied:
            fputs("Notification authorization denied.\n", stderr)
        @unknown default:
            fputs("Notification authorization unavailable.\n", stderr)
        }
    }

    private static func postNotification(_ payload: NotificationPayload, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)

        center.add(request) { error in
            if let error {
                fputs("Failed to deliver notification: \(error)\n", stderr)
            }

            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 10)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
}

private struct NotificationPayload {
    let title: String
    let subtitle: String
    let body: String

    init?(arguments: [String]) {
        guard arguments.first == "--notify" else {
            return nil
        }

        var title: String?
        var subtitle: String?
        var body: String?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                return nil
            }

            let value = arguments[index + 1]
            switch argument {
            case "--title":
                title = value
            case "--subtitle":
                subtitle = value
            case "--body":
                body = value
            default:
                return nil
            }

            index += 2
        }

        guard let title, let subtitle, let body else {
            return nil
        }

        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    init(title: String, subtitle: String, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}