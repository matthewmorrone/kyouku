import SwiftUI

// NOTE: This is UI theming (colors), not the semantic "Themes" feature.

enum AppColorThemeID: String, CaseIterable, Identifiable {
    case systemDefault
    case nord
    case tokyoNight
    case oneDark
    case catppuccinLatte
    case catppuccinMocha

    static let storageKey = "appColorThemeID"
    static let defaultValue: AppColorThemeID = .systemDefault

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: return "System Default"
        case .nord: return "Nord"
        case .tokyoNight: return "Tokyo Night"
        case .oneDark: return "One Dark"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .catppuccinMocha: return "Catppuccin Mocha"
        }
    }
}

struct AppColorTheme: Equatable {
    struct Palette: Equatable {
        let background: Color
        let surface: Color
        let textPrimary: Color
        let textSecondary: Color
        let accent: Color
        let highlight: Color
        let destructive: Color
        let tokenAlternateA: Color
        let tokenAlternateB: Color
        let unknownToken: Color
    }

    let id: AppColorThemeID
    let palette: Palette

    var displayName: String { id.displayName }

    static func from(rawValue: String, colorScheme: ColorScheme) -> AppColorTheme {
        let normalized = normalizeStorageRawValue(rawValue)
        let id = AppColorThemeID(rawValue: normalized) ?? AppColorThemeID.defaultValue
        return AppColorTheme.make(id, colorScheme: colorScheme)
    }

    static func normalizeStorageRawValue(_ raw: String) -> String {
        // Back-compat for earlier theme IDs.
        switch raw {
        case "solarizedLight":
            return AppColorThemeID.catppuccinLatte.rawValue
        case "solarizedDark":
            return AppColorThemeID.catppuccinMocha.rawValue
        case "dracula":
            return AppColorThemeID.tokyoNight.rawValue
        case "gruvboxDark":
            return AppColorThemeID.oneDark.rawValue
        default:
            return raw
        }
    }

    static func make(_ id: AppColorThemeID) -> AppColorTheme {
        make(id, colorScheme: .light)
    }

    static func make(_ id: AppColorThemeID, colorScheme: ColorScheme) -> AppColorTheme {
        switch id {
        case .systemDefault:
            return .init(
                id: id,
                palette: .init(
                    background: Color(UIColor.systemBackground),
                    surface: Color(UIColor.secondarySystemBackground),
                    textPrimary: .primary,
                    textSecondary: .secondary,
                    // `accentColor` ensures we don't fight SwiftUI's default tint.
                    accent: .accentColor,
                    highlight: Color(UIColor.systemYellow),
                    destructive: Color(UIColor.systemRed),
                    tokenAlternateA: Color(UIColor.systemBlue),
                    tokenAlternateB: Color(UIColor.systemPink),
                    unknownToken: Color(UIColor.systemOrange)
                )
            )

        case .nord:
            // Nord (Arctic Studio)
            switch colorScheme {
            case .dark:
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#2E3440", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#3B4252", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#ECEFF4", fallback: .primary),
                        textSecondary: Color(hexString: "#D8DEE9", fallback: .secondary),
                        accent: Color(hexString: "#88C0D0", fallback: Color(UIColor.systemTeal)),
                        highlight: Color(hexString: "#EBCB8B", fallback: Color(UIColor.systemYellow)),
                        destructive: Color(hexString: "#BF616A", fallback: .red),
                        tokenAlternateA: Color(hexString: "#88C0D0", fallback: Color(UIColor.systemTeal)),
                        tokenAlternateB: Color(hexString: "#A3BE8C", fallback: Color(UIColor.systemGreen)),
                        unknownToken: Color(hexString: "#D08770", fallback: Color(UIColor.systemOrange))
                    )
                )
            default:
                // Light-friendly Nord-ish variant
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#ECEFF4", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#E5E9F0", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#2E3440", fallback: .primary),
                        textSecondary: Color(hexString: "#4C566A", fallback: .secondary),
                        accent: Color(hexString: "#5E81AC", fallback: Color(UIColor.systemBlue)),
                        highlight: Color(hexString: "#EBCB8B", fallback: Color(UIColor.systemYellow)),
                        destructive: Color(hexString: "#BF616A", fallback: .red),
                        tokenAlternateA: Color(hexString: "#5E81AC", fallback: Color(UIColor.systemBlue)),
                        tokenAlternateB: Color(hexString: "#A3BE8C", fallback: Color(UIColor.systemGreen)),
                        unknownToken: Color(hexString: "#D08770", fallback: Color(UIColor.systemOrange))
                    )
                )
            }

        case .tokyoNight:
            // Tokyo Night
            switch colorScheme {
            case .dark:
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#1A1B26", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#24283B", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#C0CAF5", fallback: .primary),
                        textSecondary: Color(hexString: "#A9B1D6", fallback: .secondary),
                        accent: Color(hexString: "#7AA2F7", fallback: Color(UIColor.systemBlue)),
                        highlight: Color(hexString: "#9ECE6A", fallback: Color(UIColor.systemGreen)),
                        destructive: Color(hexString: "#F7768E", fallback: .red),
                        tokenAlternateA: Color(hexString: "#7AA2F7", fallback: Color(UIColor.systemBlue)),
                        tokenAlternateB: Color(hexString: "#BB9AF7", fallback: Color(UIColor.systemPurple)),
                        unknownToken: Color(hexString: "#E0AF68", fallback: Color(UIColor.systemOrange))
                    )
                )
            default:
                // Tokyo Night Day-inspired variant
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#E1E2E7", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#D5D6DB", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#3760BF", fallback: .primary),
                        textSecondary: Color(hexString: "#6172B0", fallback: .secondary),
                        accent: Color(hexString: "#2E7DE9", fallback: Color(UIColor.systemBlue)),
                        highlight: Color(hexString: "#587539", fallback: Color(UIColor.systemGreen)),
                        destructive: Color(hexString: "#F52A65", fallback: .red),
                        tokenAlternateA: Color(hexString: "#2E7DE9", fallback: Color(UIColor.systemBlue)),
                        tokenAlternateB: Color(hexString: "#9854F1", fallback: Color(UIColor.systemPurple)),
                        unknownToken: Color(hexString: "#8C6C3E", fallback: Color(UIColor.systemOrange))
                    )
                )
            }

        case .oneDark:
            // One Dark (Atom)
            switch colorScheme {
            case .dark:
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#282C34", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#21252B", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#ABB2BF", fallback: .primary),
                        textSecondary: Color(hexString: "#7F848E", fallback: .secondary),
                        accent: Color(hexString: "#61AFEF", fallback: Color(UIColor.systemBlue)),
                        highlight: Color(hexString: "#E5C07B", fallback: Color(UIColor.systemYellow)),
                        destructive: Color(hexString: "#E06C75", fallback: .red),
                        tokenAlternateA: Color(hexString: "#61AFEF", fallback: Color(UIColor.systemBlue)),
                        tokenAlternateB: Color(hexString: "#C678DD", fallback: Color(UIColor.systemPurple)),
                        unknownToken: Color(hexString: "#D19A66", fallback: Color(UIColor.systemOrange))
                    )
                )
            default:
                // One Light-inspired variant
                return .init(
                    id: id,
                    palette: .init(
                        background: Color(hexString: "#FAFAFA", fallback: Color(UIColor.systemBackground)),
                        surface: Color(hexString: "#F0F0F1", fallback: Color(UIColor.secondarySystemBackground)),
                        textPrimary: Color(hexString: "#383A42", fallback: .primary),
                        textSecondary: Color(hexString: "#696C77", fallback: .secondary),
                        accent: Color(hexString: "#4078F2", fallback: Color(UIColor.systemBlue)),
                        highlight: Color(hexString: "#C18401", fallback: Color(UIColor.systemYellow)),
                        destructive: Color(hexString: "#E45649", fallback: .red),
                        tokenAlternateA: Color(hexString: "#4078F2", fallback: Color(UIColor.systemBlue)),
                        tokenAlternateB: Color(hexString: "#A626A4", fallback: Color(UIColor.systemPurple)),
                        unknownToken: Color(hexString: "#986801", fallback: Color(UIColor.systemOrange))
                    )
                )
            }

        case .catppuccinLatte:
            // Catppuccin Latte
            return .init(
                id: id,
                palette: .init(
                    background: Color(hexString: "#EFF1F5", fallback: Color(UIColor.systemBackground)),
                    surface: Color(hexString: "#E6E9EF", fallback: Color(UIColor.secondarySystemBackground)),
                    textPrimary: Color(hexString: "#4C4F69", fallback: .primary),
                    textSecondary: Color(hexString: "#6C6F85", fallback: .secondary),
                    accent: Color(hexString: "#1E66F5", fallback: Color(UIColor.systemBlue)),
                    highlight: Color(hexString: "#40A02B", fallback: Color(UIColor.systemGreen)),
                    destructive: Color(hexString: "#D20F39", fallback: .red),
                    tokenAlternateA: Color(hexString: "#1E66F5", fallback: Color(UIColor.systemBlue)),
                    tokenAlternateB: Color(hexString: "#8839EF", fallback: Color(UIColor.systemPurple)),
                    unknownToken: Color(hexString: "#FE640B", fallback: Color(UIColor.systemOrange))
                )
            )

        case .catppuccinMocha:
            // Catppuccin Mocha
            return .init(
                id: id,
                palette: .init(
                    background: Color(hexString: "#1E1E2E", fallback: Color(UIColor.systemBackground)),
                    surface: Color(hexString: "#313244", fallback: Color(UIColor.secondarySystemBackground)),
                    textPrimary: Color(hexString: "#CDD6F4", fallback: .primary),
                    textSecondary: Color(hexString: "#A6ADC8", fallback: .secondary),
                    accent: Color(hexString: "#89B4FA", fallback: Color(UIColor.systemBlue)),
                    highlight: Color(hexString: "#A6E3A1", fallback: Color(UIColor.systemGreen)),
                    destructive: Color(hexString: "#F38BA8", fallback: .red),
                    tokenAlternateA: Color(hexString: "#89B4FA", fallback: Color(UIColor.systemBlue)),
                    tokenAlternateB: Color(hexString: "#CBA6F7", fallback: Color(UIColor.systemPurple)),
                    unknownToken: Color(hexString: "#FAB387", fallback: Color(UIColor.systemOrange))
                )
            )
        }
    }
}

extension EnvironmentValues {
    var appColorTheme: AppColorTheme {
        get { self[AppColorThemeKey.self] }
        set { self[AppColorThemeKey.self] = newValue }
    }
}
