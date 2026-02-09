import SwiftUI
import UIKit

// Global accessors for the currently-selected UI theme.
//
// We intentionally keep these as pure computed properties backed by UserDefaults so
// any view can opt into them without threading Environment values everywhere.
// `ContentView` still reads `@AppStorage` so theme changes trigger view refresh.

enum AppTheme {
    static var currentThemeID: AppColorThemeID {
        let raw = UserDefaults.standard.string(forKey: AppColorThemeID.storageKey) ?? AppColorThemeID.defaultValue.rawValue
        let normalized = AppColorTheme.normalizeStorageRawValue(raw)
        return AppColorThemeID(rawValue: normalized) ?? AppColorThemeID.defaultValue
    }

    private static func dynamicUIColor(_ builder: @escaping (AppColorTheme) -> UIColor) -> UIColor {
        UIColor { traits in
            let raw = UserDefaults.standard.string(forKey: AppColorThemeID.storageKey) ?? AppColorThemeID.defaultValue.rawValue
            let scheme: ColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            let theme = AppColorTheme.from(rawValue: raw, colorScheme: scheme)
            return builder(theme)
        }
    }

    static func color(_ role: @escaping (AppColorTheme.Palette) -> Color) -> Color {
        Color(
            AppTheme.dynamicUIColor { theme in
                UIColor(role(theme.palette))
            }
        )
    }
}

extension Color {
    static var appBackground: Color { AppTheme.color { $0.background } }
    static var appSurface: Color { AppTheme.color { $0.surface } }
    static var appTextPrimary: Color { AppTheme.color { $0.textPrimary } }
    static var appTextSecondary: Color { AppTheme.color { $0.textSecondary } }
    static var appAccent: Color { AppTheme.color { $0.accent } }
    static var appHighlight: Color { AppTheme.color { $0.highlight } }
    static var appDestructive: Color { AppTheme.color { $0.destructive } }

    static var appBorder: Color {
        // Prefer system separators for System Default to avoid subtle deltas.
        if AppTheme.currentThemeID == .systemDefault {
            return Color(UIColor.separator)
        }
        return Color.appTextPrimary.opacity(0.14)
    }

    static var appSoftFill: Color {
        if AppTheme.currentThemeID == .systemDefault {
            return Color(UIColor.secondarySystemFill)
        }
        return Color.appTextPrimary.opacity(0.06)
    }
}


