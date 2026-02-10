import Foundation
import UserNotifications

enum LegacyNotificationCleanup {
    private static let didRunKey = "didClearLegacyNotifications"

    static func runIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: didRunKey) == false else { return }

        let center = UNUserNotificationCenter.current()
        let pendingCount = await center.pendingRequestCount()
        let deliveredCount = await center.deliveredNotificationCount()

        if pendingCount > 0 || deliveredCount > 0 {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            CustomLogger.shared.info("Cleared legacy notifications pending=\(pendingCount) delivered=\(deliveredCount)")
        } else {
            CustomLogger.shared.debug("No legacy notifications found")
        }

        defaults.set(true, forKey: didRunKey)
    }
}

private extension UNUserNotificationCenter {
    func pendingRequestCount() async -> Int {
        await withCheckedContinuation { continuation in
            getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.count)
            }
        }
    }

    func deliveredNotificationCount() async -> Int {
        await withCheckedContinuation { continuation in
            getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.count)
            }
        }
    }
}
