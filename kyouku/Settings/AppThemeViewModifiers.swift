import SwiftUI

struct AppThemedRootModifier: ViewModifier {
    let themeID: AppColorThemeID

    func body(content: Content) -> some View {
        if themeID == .systemDefault {
            content
        } else {
            content
                .tint(Color.appAccent)
                .background(Color.appBackground.ignoresSafeArea())
        }
    }
}

extension View {
    func appThemedRoot(themeID: AppColorThemeID = AppTheme.currentThemeID) -> some View {
        modifier(AppThemedRootModifier(themeID: themeID))
    }

    /// Applies themed backgrounds to Lists/Forms (hides the default scroll background).
    func appThemedScrollBackground(themeID: AppColorThemeID = AppTheme.currentThemeID) -> some View {
        modifier(AppThemedScrollBackgroundModifier(themeID: themeID))
    }
}
