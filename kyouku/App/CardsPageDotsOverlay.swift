import SwiftUI

struct CardsPageDotsOverlay: View {
    let selectedPage: CardsPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CardsPage.allCases) { page in
                Circle()
                    .fill(page == selectedPage ? Color.appTextPrimary : Color.appTextSecondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .opacity(0.9)
    }
}

