#if false
import Foundation

enum AppGroup {
    // Replace this with your real App Group identifier in both app and widget targets
    static let id = "group.kyouku"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}
#endif // Reverted: disable duplicate AppGroup introduced by external tool
