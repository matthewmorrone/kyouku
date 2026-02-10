import SwiftUI

struct ComponentPreviewSheet: View {
    let part: WordDefinitionsView.TokenPart
    let onOpenFullPage: (WordDefinitionsView.TokenPart) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookupViewModel = DictionaryLookupViewModel()

    private var displayKana: String? {
        let trimmed = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false, trimmed != part.surface else { return nil }
        return trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(part.surface)
                                .font(.title2.weight(.semibold))
                            if let displayKana {
                                Text(displayKana)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }

                        if let first = lookupViewModel.results.first, first.gloss.isEmpty == false {
                            Text(first.gloss)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if lookupViewModel.isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let error = lookupViewModel.errorMessage, error.isEmpty == false {
                    Section {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                } else if lookupViewModel.results.isEmpty {
                    Section {
                        Text("No matches.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Top matches") {
                        ForEach(Array(lookupViewModel.results.prefix(5))) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.kanji)
                                        .font(.body.weight(.semibold))
                                    if let kana = entry.kana, kana.isEmpty == false, kana != entry.kanji {
                                        Text(kana)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                if entry.gloss.isEmpty == false {
                                    Text(entry.gloss)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open full page") {
                        dismiss()
                        DispatchQueue.main.async {
                            onOpenFullPage(part)
                        }
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .task(id: part.id) {
                await lookupViewModel.lookup(term: part.surface, mode: .japanese)
                if lookupViewModel.results.isEmpty, let kana = part.kana, kana.isEmpty == false, kana != part.surface {
                    await lookupViewModel.lookup(term: kana, mode: .japanese)
                }
            }
        }
    }
}

