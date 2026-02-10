import SwiftUI

extension WordDefinitionsView {
    // MARK: Definitions
    func isCommonEntry(_ entry: DictionaryEntry) -> Bool {
        if let detail = entryDetails.first(where: { $0.entryID == entry.entryID }) {
            return detail.isCommon
        }
        return entry.isCommon
    }

    func commonFirstStable(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter { isCommonEntry($0) } + entries.filter { isCommonEntry($0) == false }
    }

    var definitionRows: [DefinitionRow] {
        let headword = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headword.isEmpty == false else { return [] }

        let isKanji = containsKanji(headword)
        let normalizedHeadword = kanaFoldToHiragana(headword)
        let contextKanaKey: String? = kana
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : kanaFoldToHiragana($0) }

        // Filter to entries relevant to the headword.
        let relevant: [DictionaryEntry] = entries.filter { entry in
            let k = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

            if isKanji {
                return k == headword
            }

            // Kana headword: include meanings for this kana, but do not display kanji spellings.
            if let r, r.isEmpty == false, kanaFoldToHiragana(r) == normalizedHeadword {
                return true
            }
            if k.isEmpty == false, kanaFoldToHiragana(k) == normalizedHeadword {
                return true
            }
            return false
        }

        let relevantOrdered = commonFirstStable(relevant)

        guard relevantOrdered.isEmpty == false else { return [] }

        if isKanji {
            // Rows per distinct kana reading, folding hiragana/katakana variants
            // of the same reading into a single bucket.
            struct Bucket {
                var firstIndex: Int
                var key: String
                var readings: [String]
                var entries: [DictionaryEntry]
            }
            var byReadingKey: [String: Bucket] = [:]
            for (idx, entry) in relevantOrdered.enumerated() {
                let raw = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard raw.isEmpty == false else { continue }
                let key = kanaFoldToHiragana(raw)
                if var existing = byReadingKey[key] {
                    existing.entries.append(entry)
                    if existing.readings.contains(raw) == false {
                        existing.readings.append(raw)
                    }
                    byReadingKey[key] = existing
                } else {
                    byReadingKey[key] = Bucket(firstIndex: idx, key: key, readings: [raw], entries: [entry])
                }
            }

            var orderedBuckets = Array(byReadingKey.values)
            orderedBuckets.sort { lhs, rhs in
                if let key = contextKanaKey {
                    let lhsMatch = lhs.key == key
                    let rhsMatch = rhs.key == key
                    if lhsMatch != rhsMatch { return lhsMatch }
                }
                return lhs.firstIndex < rhs.firstIndex
            }
            return orderedBuckets.compactMap { bucket in
                let pages = pagesForEntries(bucket.entries)
                guard pages.isEmpty == false else { return nil }
                let displayReading = preferredReading(from: bucket.readings) ?? bucket.readings.first ?? bucket.key
                return DefinitionRow(headword: headword, reading: displayReading, pages: pages)
            }
        } else {
            // Single kana row with all meanings.
            let pages = pagesForEntries(relevantOrdered)
            guard pages.isEmpty == false else { return [] }
            return [DefinitionRow(headword: headword, reading: headword, pages: pages)]
        }
    }

    func pagesForEntries(_ entries: [DictionaryEntry]) -> [DefinitionPage] {
        let entries = commonFirstStable(entries)
        // Preserve first-seen ordering across all gloss parts.
        var order: [String] = []
        var buckets: [String: DictionaryEntry] = [:]

        for entry in entries {
            let detail = entryDetails.first(where: { $0.entryID == entry.entryID })
            let glossCandidates: [String] = {
                guard let detail else {
                    return glossParts(entry.gloss)
                }

                let orderedSenses = orderedSensesForDisplay(detail)
                var out: [String] = []
                out.reserveCapacity(min(12, orderedSenses.count))
                for sense in orderedSenses {
                    if let line = joinedGlossLine(for: sense)?.trimmingCharacters(in: .whitespacesAndNewlines), line.isEmpty == false {
                        out.append(line)
                    }
                }
                return out.isEmpty ? glossParts(entry.gloss) : out
            }()

            for gloss in glossCandidates {
                if buckets[gloss] == nil {
                    order.append(gloss)
                    buckets[gloss] = entry
                }
            }
        }

        return order.compactMap { gloss in
            guard let entry = buckets[gloss] else { return nil }
            return DefinitionPage(gloss: gloss, entry: entry)
        }
    }

    func definitionRowView(_ row: DefinitionRow) -> some View {
        let reading = row.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = (reading?.isEmpty == false) ? reading : nil
        let isSaved = isSaved(surface: row.headword, kana: normalizedReading)
        let createdAt = isSaved ? savedWordCreatedAt(surface: row.headword, kana: normalizedReading) : nil

        let primaryGloss = row.pages.first?.gloss ?? ""
        let extraCount = max(0, row.pages.count - 1)
        let isExpanded = expandedDefinitionRowIDs.contains(row.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.headword)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    if containsKanji(row.headword), let normalizedReading {
                        Text(normalizedReading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let createdAt {
                        Text(createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        // Store meaning as the first page (best available summary).
                        toggleSaved(surface: row.headword, kana: normalizedReading, meaning: primaryGloss)
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .symbolRenderingMode(.hierarchical)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.thinMaterial, in: Circle())
                            .foregroundStyle(isSaved ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSaved ? "Saved" : "Save")

                    Button {
                        listAssignmentTarget = ListAssignmentTarget(surface: row.headword, kana: normalizedReading, meaning: primaryGloss)
                    } label: {
                        Image(systemName: "folder")
                            .symbolRenderingMode(.hierarchical)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.thinMaterial, in: Circle())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lists")
                }
            }

            if primaryGloss.isEmpty == false {
                Text(primaryGloss)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if isExpanded, row.pages.count > 1 {
                ForEach(Array(row.pages.dropFirst().prefix(12))) { page in
                    Text(page.gloss)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if extraCount > 0 {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if isExpanded {
                            expandedDefinitionRowIDs.remove(row.id)
                        } else {
                            expandedDefinitionRowIDs.insert(row.id)
                        }
                    }
                } label: {
                    Text(isExpanded ? "Hide" : "+\(extraCount) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}
