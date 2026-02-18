import SwiftUI
import UIKit

struct SearchResultsView: View {
    @ObservedObject var viewModel: SearchViewModel

    let showCameraButton: Bool
    let onCameraTap: (() -> Void)?

    let listOptionsForRow: (DictionaryResultRow) -> [SearchResultRow.ListOption]
    let isFavorite: (DictionaryResultRow) -> Bool
    let isCustom: (DictionaryResultRow) -> Bool

    let onToggleFavorite: (DictionaryResultRow) -> Void
    let onAddToList: (DictionaryResultRow, UUID) -> Void
    let onCreateListAndAdd: (DictionaryResultRow) -> Void
    let onAddNewCard: (DictionaryResultRow) -> Void
    let onCopy: (DictionaryResultRow) -> Void
    let onViewHistory: (DictionaryResultRow) -> Void
    let onOpenResult: (DictionaryResultRow) -> Void

    var body: some View {
        List {
            Section {
                searchBar
            }
            .listRowSeparator(.hidden)

            if viewModel.isLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = viewModel.errorMessage, error.isEmpty == false {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.bestMatches.isEmpty && viewModel.additionalMatches.isEmpty {
                Section {
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                }
            } else {
                if viewModel.bestMatches.isEmpty == false {
                    Section(header: SearchSectionHeader(title: "Best Matches")) {
                        rows(viewModel.bestMatches)
                    }
                }

                if viewModel.additionalMatches.isEmpty == false {
                    Section(header: SearchSectionHeader(title: "Additional Matches")) {
                        rows(viewModel.additionalMatches)
                    }
                }
            }
        }
        .listStyle(.plain)
        .appThemedScrollBackground()
        .onAppear {
            // Ensure results refresh when returning to this screen.
            viewModel.query = viewModel.query
        }
    }

    @ViewBuilder
    private func rows(_ rows: [DictionaryResultRow]) -> some View {
        ForEach(rows) { row in
            NavigationLink {
                WordDefinitionView(
                    request: .init(
                        term: .init(surface: row.surface, kana: row.kana),
                        context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                        metadata: .init(sourceNoteID: nil)
                    )
                )
            } label: {
                SearchResultRow(
                    row: row,
                    displayMode: viewModel.displayMode,
                    indicatorSymbol: indicator(for: row),
                    listOptions: listOptionsForRow(row),
                    isFavorite: isFavorite(row),
                    onToggleFavorite: { onToggleFavorite(row) },
                    onAddToList: { listID in onAddToList(row, listID) },
                    onCreateListAndAdd: { onCreateListAndAdd(row) },
                    onAddNewCard: { onAddNewCard(row) },
                    onCopy: { onCopy(row) },
                    onViewHistory: { onViewHistory(row) }
                )
            }
            .simultaneousGesture(
                TapGesture().onEnded { onOpenResult(row) }
            )
        }
    }

    private var emptyStateText: String {
        if viewModel.trimmedQuery.isEmpty {
            return "Search Japanese or English to get started."
        }
        return "No matches found for \(viewModel.trimmedQuery)."
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search Japanese or English", text: $viewModel.query)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.search)

                    if viewModel.query.isEmpty == false {
                        Button {
                            viewModel.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.vertical, SearchResultStyle.searchBarVerticalPadding)
                .padding(.horizontal, SearchResultStyle.searchBarHorizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appBorder, lineWidth: 1)
                )

                if showCameraButton, let onCameraTap {
                    Button(action: onCameraTap) {
                        Image(systemName: "camera")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Camera")
                }
            }

            HStack(spacing: 8) {
                Picker("Search language", selection: $viewModel.lookupMode) {
                    Text("JP").tag(DictionarySearchMode.japanese)
                    Text("EN").tag(DictionarySearchMode.english)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Search language")

                Picker("Display", selection: $viewModel.displayMode) {
                    ForEach(SearchViewModel.DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Display mode")
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .background(Color.clear)
    }

    private func indicator(for row: DictionaryResultRow) -> String {
        if isCustom(row) { return "◇" }
        if isFavorite(row) { return "☆" }
        return "○"
    }
}
