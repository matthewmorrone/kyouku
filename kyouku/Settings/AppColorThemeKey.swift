import SwiftUI

struct AppColorThemeKey: EnvironmentKey {
    static let defaultValue: AppColorTheme = AppColorTheme.make(AppColorThemeID.defaultValue)
}

