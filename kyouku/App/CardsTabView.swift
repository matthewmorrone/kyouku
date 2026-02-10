import SwiftUI

enum CardsPage: Int, CaseIterable, Identifiable {
    case flashcards
    case cloze

    var id: Int { rawValue }
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
