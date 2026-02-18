import SwiftUI

struct SearchResultRow: View {
    struct ListOption: Identifiable {
        let id: UUID
        let name: String
        let isSelected: Bool
    }

    let row: DictionaryResultRow
    let displayMode: SearchViewModel.DisplayMode
    let indicatorSymbol: String
    let listOptions: [ListOption]
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onAddToList: (UUID) -> Void
    let onCreateListAndAdd: () -> Void
    let onAddNewCard: () -> Void
    let onCopy: () -> Void
    let onViewHistory: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SearchResultStyle.rowHorizontalSpacing) {
            Text(indicatorSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .center)

            VStack(alignment: .leading, spacing: SearchResultStyle.verticalItemSpacing) {
                if displayMode == .japanese {
                    japaneseFirstBody
                } else {
                    englishFirstBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.vertical, SearchResultStyle.rowVerticalPadding)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }

            Menu {
                if listOptions.isEmpty {
                    Text("No lists")
                } else {
                    ForEach(listOptions) { option in
                        Button {
                            onAddToList(option.id)
                        } label: {
                            Label(option.name, systemImage: option.isSelected ? "checkmark" : "")
                        }
                    }
                }
                Divider()
                Button {
                    onCreateListAndAdd()
                } label: {
                    Label("Create New List", systemImage: "plus")
                }
            } label: {
                Label("Add to List", systemImage: "text.badge.plus")
            }

            Button {
                onAddNewCard()
            } label: {
                Label("Add New Card", systemImage: "plus.rectangle.on.rectangle")
            }

            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onViewHistory()
            } label: {
                Label("View History", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder
    private var japaneseFirstBody: some View {
        if let kana = row.kana, kana.isEmpty == false, kana != row.surface {
            Text(kana)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Text(row.surface)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

        if row.gloss.isEmpty == false {
            Text(row.gloss)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var englishFirstBody: some View {
        if row.gloss.isEmpty == false {
            Text(row.gloss)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }

        if let kana = row.kana, kana.isEmpty == false, kana != row.surface {
            Text(kana)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Text(row.surface)
            .font(.headline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct SearchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .textCase(.uppercase)
            .padding(.vertical, SearchResultStyle.sectionHeaderVerticalPadding)
    }
}

enum SearchResultStyle {
    static let rowHorizontalSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 6
    static let verticalItemSpacing: CGFloat = 2
    static let sectionHeaderVerticalPadding: CGFloat = 2
    static let searchBarVerticalPadding: CGFloat = 10
    static let searchBarHorizontalPadding: CGFloat = 14
}
