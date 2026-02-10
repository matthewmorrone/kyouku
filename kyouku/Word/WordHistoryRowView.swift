import Foundation
import SwiftUI

struct WordHistoryRowView: View {
    let item: ViewedDictionaryHistoryStore.Item

    @State private var englishGloss: String? = nil
    @State private var didAttemptLookup: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.surface)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let kana = item.kana, kana.isEmpty == false, kana != item.surface {
                    Text(kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let displayedGloss = (item.meaning ?? englishGloss), displayedGloss.isEmpty == false {
                    Text(displayedGloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .task(id: item.id) {
            await loadEnglishGlossIfNeeded()
        }
    }

    private func loadEnglishGlossIfNeeded() async {
        if let existing = item.meaning?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), existing.isEmpty == false {
            await MainActor.run {
                if englishGloss == nil {
                    englishGloss = existing
                }
            }
            return
        }

        let terms: [String] = {
            var out: [String] = [item.surface]
            if let kana = item.kana, kana.isEmpty == false, kana != item.surface {
                out.append(kana)
            }
            return out
        }()

        let shouldStart: Bool = await MainActor.run {
            guard didAttemptLookup == false else { return false }
            didAttemptLookup = true
            return true
        }
        guard shouldStart else { return }

        for term in terms {
            let keys = DictionaryKeyPolicy.keys(forDisplayKey: term)
            guard keys.lookupKey.isEmpty == false else { continue }

            let rows: [DictionaryEntry]
            do {
                rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 10, mode: .japanese)
            } catch {
                continue
            }

            guard let gloss = bestGloss(from: rows) else { continue }
            let trimmed = gloss.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                await MainActor.run {
                    englishGloss = trimmed
                    ViewedDictionaryHistoryStore.shared.updateMeaning(id: item.id, meaning: trimmed)
                }
                return
            }
        }
    }

    private func bestGloss(from rows: [DictionaryEntry]) -> String? {
        guard rows.isEmpty == false else { return nil }
        if let kana = item.kana, kana.isEmpty == false {
            if let match = rows.first(where: { ($0.kana ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == kana }) {
                return match.gloss
            }
        }
        if let exact = rows.first(where: { $0.kanji == item.surface }) {
            return exact.gloss
        }
        return rows.first?.gloss
    }
}
