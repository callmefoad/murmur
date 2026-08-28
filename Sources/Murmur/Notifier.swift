import Foundation
import UserNotifications

/// Posts user-facing error notifications.
///
/// Authorization is requested lazily — only when the first error actually
/// occurs — so Murmur never prompts at launch for something the user may
/// never see. Identical messages posted within 30 seconds are suppressed so
/// a repeating failure (e.g. every dictation hitting the same missing grant)
/// can't spam Notification Center; the red caption in the dashboard window
/// remains the in-app surface.
///
/// All entry points are main-thread-only (callers are AppDelegate state
/// mutations); `requestAuthorization`'s completion lands on a background
/// queue but only touches the thread-safe notification center.
enum Notifier {
    private static var authorizationRequested = false
    private static var lastMessage: String?
    private static var lastPostDate: Date?

    private static let duplicateWindow: TimeInterval = 30

    static func postError(_ message: String) {
        let now = Date()
        if message == lastMessage, let last = lastPostDate,
           now.timeIntervalSince(last) < duplicateWindow {
            return
        }
        lastMessage = message
        lastPostDate = now

        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                deliver(message, to: center)
            }
            return
        }
        deliver(message, to: center)
    }

    private static func deliver(_ message: String, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Murmur"
        content.body = message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

/// Keeps error notifications appearing as banners even when Murmur itself is
/// frontmost (the default is to silently drop them for the active app, which
/// for a menu-bar dictation tool is most of the time).
final class NotifierPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifierPresentationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
