import SwiftUI

struct AppThemedScrollBackgroundModifier: ViewModifier {
    let themeID: AppColorThemeID

    func body(content: Content) -> some View {
        if themeID == .systemDefault {
            return AnyView(content)
        }
        if #available(iOS 16.0, *) {
            return AnyView(
                content
                    .scrollContentBackground(.hidden)
                    .background(Color.appBackground)
            )
        } else {
            return AnyView(
                content
                    .background(Color.appBackground)
            )
        }
    }
}

