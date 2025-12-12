import Foundation
import UIKit

/// A small helper that simulates a shared "inbox" for text sent from
/// other parts of the app (e.g., a Share Extension). This implementation
/// uses UserDefaults so it works even without an app group configured.
///
/// If you later add a Share Extension, consider switching `defaults`
/// to a suite-based UserDefaults with your App Group identifier.
/// Example:
///   let defaults = UserDefaults(suiteName: "group.your.identifier")
/// and keep the same keys.
struct SharedInbox {
    /// Set this to your App Group identifier to share data between the app and extension.
    /// Example: "group.com.yourcompany.yourapp"
    private static let appGroupID: String? = "group.matthewmorrone.kyouku"

    /// Returns UserDefaults backed by the App Group if configured, else falls back to standard.
    private static var sharedDefaults: UserDefaults {
        if let id = appGroupID, let d = UserDefaults(suiteName: id) {
            return d
        } else {
            return .standard
        }
    }

    /// The key used to store pending shared text.
    private static let pendingTextKey = "SharedInbox.pendingText"

    /// Retrieves the most recently shared text, if any, and clears it so
    /// subsequent calls don't return the same value again.
    /// - Returns: A String if there is pending text, otherwise nil.
    static func takeLatestText() -> String? {
        // Prefer an app group if configured, otherwise fall back to standard defaults.
        let defaults = sharedDefaults
        guard let text = defaults.string(forKey: pendingTextKey) else {
            return nil
        }
        // Clear after reading to mimic a one-time inbox fetch.
        defaults.removeObject(forKey: pendingTextKey)
        return text
    }

    /// Allows other parts of the app (or tests) to place text into the inbox.
    /// Not strictly required by PasteView, but useful for integration points.
    static func put(text: String) {
        let defaults = sharedDefaults
        defaults.set(text, forKey: pendingTextKey)
    }
}
