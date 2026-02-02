import SwiftUI

fileprivate enum CardsPage: Int, CaseIterable, Identifiable {
    case flashcards
    case cloze

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .flashcards:
            return "Flashcards"
        case .cloze:
            return "Cloze"
        }
    }
}

struct CardsTabView: View {
    private static let pages: [CardsPage] = CardsPage.allCases
    private static let copies: Int = 3

    private static var totalCount: Int {
        pages.count * copies
    }

    private static func initialIndex(for page: CardsPage) -> Int {
        let middleStart = pages.count // start on the middle copy
        return middleStart + page.rawValue
    }

    @State private var selectedIndex: Int = CardsTabView.initialIndex(for: .flashcards)
    @State private var flashcardsWantsPageDotsHidden: Bool = false

    private var currentPage: CardsPage {
        CardsTabView.pages[selectedIndex % CardsTabView.pages.count]
    }

    var body: some View {
        TabView(selection: $selectedIndex) {
            ForEach(0..<CardsTabView.totalCount, id: \.self) { index in
                let page = CardsTabView.pages[index % CardsTabView.pages.count]
                Group {
                    switch page {
                    case .flashcards:
                        FlashcardsView()
                    case .cloze:
                        ClozeStudyHomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: selectedIndex) { _, newValue in
            let pageCount = CardsTabView.pages.count

            // Keep the user in the middle copy so swipes can continue indefinitely.
            if newValue < pageCount {
                jumpSelection(to: newValue + pageCount)
            } else if newValue >= pageCount * 2 {
                jumpSelection(to: newValue - pageCount)
            }
        }
        .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { newValue in
            flashcardsWantsPageDotsHidden = newValue
        }
        .overlay {
            let shouldHideDots = (currentPage == .flashcards && flashcardsWantsPageDotsHidden)

            if !shouldHideDots {
                CardsPageDotsOverlay(selectedPage: currentPage)
                    .allowsHitTesting(false)
            }
        }
    }

    private func jumpSelection(to index: Int) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedIndex = index
        }
    }
}

struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct CardsPageDotsOverlay: View {
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
