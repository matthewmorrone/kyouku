import Foundation
import OSLog

enum DiagnosticsLogging {
    struct Area: Hashable {
        let rawValue: String
        let isEnabledByDefault: Bool

        static var tokenOverlayEvents: Area { area(enabled: true) }
        static var tokenOverlayGeometry: Area { area(enabled: true) }
        static var pasteSelection: Area { area(enabled: true) }
        static var furigana: Area { area(enabled: true) }
        static var notesStore: Area { area(enabled: true) }
        static var readingOverrides: Area { area(enabled: true) }

        private static func area(enabled: Bool = false, name: String = #function) -> Area {
            let cleanName = name.replacingOccurrences(of: ".getter", with: "")
            return Area(rawValue: cleanName, isEnabledByDefault: enabled)
        }
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "kyouku"

    static func isEnabled(_ area: Area) -> Bool {
        if let override = override(for: area) {
            return override
        }
        return area.isEnabledByDefault
    }

    static func logger(_ area: Area) -> Logger {
        guard isEnabled(area) else {
            return Logger(OSLog.disabled)
        }
        return Logger(subsystem: subsystem, category: area.rawValue)
    }

    private static func override(for area: Area) -> Bool? {
        let key = "DiagnosticsLogging.\(area.rawValue)"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        if let envValue = ProcessInfo.processInfo.environment[key], let parsed = parseBool(envValue) {
            return parsed
        }
        return nil
    }

    private static func parseBool(_ value: String) -> Bool? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes", "on"].contains(normalized) { return true }
        if ["0", "false", "no", "off"].contains(normalized) { return false }
        return nil
    }

}
