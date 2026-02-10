import Foundation
import UserNotifications

final class NotificationDeepLinkHandler: NSObject, UNUserNotificationCenterDelegate {
    private weak var router: AppRouter?

    init(router: AppRouter) {
        self.router = router
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // Show the notification while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard let idStr = userInfo["wordID"] as? String, let wordID = UUID(uuidString: idStr) else {
            return
        }

        Task { @MainActor [weak router] in
            router?.openWordDetails(wordID: wordID)
        }
    }
}
