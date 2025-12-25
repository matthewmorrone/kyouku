import Foundation
import OSLog

enum DiagnosticsLogging {
    struct Area: Hashable {
        let rawValue: String
        let isEnabledByDefault: Bool

        static var tokenOverlayEvents: Area { area(enabled: false) }
        static var tokenOverlayGeometry: Area { area(enabled: true) }
        static var pasteSelection: Area { area(enabled: false) }
        static var furigana: Area { area(enabled: false) }
        static var notesStore: Area { area(enabled: false) }
        static var readingOverrides: Area { area(enabled: false) }

        private static func area(enabled: Bool = false, name: String = #function) -> Area {
            let cleanName = name.replacingOccurrences(of: ".getter", with: "")
            return Area(rawValue: cleanName, isEnabledByDefault: enabled)
        }
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "kyouku"

    static func isEnabled(_ area: Area) -> Bool {
        area.isEnabledByDefault
    }

    static func logger(_ area: Area) -> Logger {
        guard isEnabled(area) else {
            return Logger(OSLog.disabled)
        }
        return Logger(subsystem: subsystem, category: area.rawValue)
    }

}
