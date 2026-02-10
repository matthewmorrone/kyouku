import SwiftUI
import UIKit
import Foundation

extension PasteView {
    var incrementalPopupGroups: [IncrementalLookupGroup] {
        guard incrementalPopupHits.isEmpty == false else { return [] }

        // Preserve first-seen order per surface.
        struct Bucket {
            var firstIndex: Int
            var surface: String
            var hits: [IncrementalLookupHit]
        }

        var buckets: [String: Bucket] = [:]
        buckets.reserveCapacity(min(32, incrementalPopupHits.count))

        for (idx, hit) in incrementalPopupHits.enumerated() {
            let foldedKey = kanaFoldToHiragana(hit.matchedSurface.trimmingCharacters(in: .whitespacesAndNewlines))
            if var existing = buckets[foldedKey] {
                existing.hits.append(hit)
                buckets[foldedKey] = existing
            } else {
                buckets[foldedKey] = Bucket(firstIndex: idx, surface: hit.matchedSurface, hits: [hit])
            }
        }

        let ordered = buckets.values.sorted { $0.firstIndex < $1.firstIndex }

        func normalizeKanji(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func normalizeGloss(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ordered.map { bucket in
            // Collapse entries that share (kanji, gloss) by combining their kana variants.
            var collapsedByKey: [String: (kanji: String, gloss: String, kana: [String], entries: [DictionaryEntry], firstIndex: Int)] = [:]
            collapsedByKey.reserveCapacity(min(16, bucket.hits.count))

            for (localIndex, hit) in bucket.hits.enumerated() {
                let kanji = normalizeKanji(hit.entry.kanji)
                let gloss = normalizeGloss(hit.entry.gloss)
                let key = "\(kanji)#\(gloss)"
                let kana = normalizedReading(hit.entry.kana)

                if var existing = collapsedByKey[key] {
                    if let kana, existing.kana.contains(kana) == false {
                        existing.kana.append(kana)
                    }
                    existing.entries.append(hit.entry)
                    collapsedByKey[key] = existing
                } else {
                    collapsedByKey[key] = (
                        kanji: kanji,
                        gloss: gloss,
                        kana: kana.map { [$0] } ?? [],
                        entries: [hit.entry],
                        firstIndex: localIndex
                    )
                }
            }

            let pages: [IncrementalLookupCollapsed] = collapsedByKey.values
                .sorted { $0.firstIndex < $1.firstIndex }
                .map { item in
                    let kanaList: String?
                    if item.kana.isEmpty {
                        kanaList = nil
                    } else {
                        kanaList = item.kana.joined(separator: "; ")
                    }
                    return IncrementalLookupCollapsed(
                        matchedSurface: bucket.surface,
                        kanji: item.kanji,
                        gloss: item.gloss,
                        kanaList: kanaList,
                        entries: item.entries
                    )
                }

            return IncrementalLookupGroup(matchedSurface: bucket.surface, pages: pages)
        }
    }

    @ViewBuilder
    var incrementalLookupSheet: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(incrementalPopupGroups) { group in
                    if group.pages.count <= 1, let page = group.pages.first {
                        incrementalPopupPage(page)
                    } else {
                        TabView {
                            ForEach(group.pages) { page in
                                incrementalPopupPage(page)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 110)
                    }

                    Divider()
                }
            }
            .padding(14)
        }
        .background(Color.appBackground)
        .onAppear {
            incrementalSheetDetent = incrementalPreferredSheetDetent
        }
        .onChange(of: incrementalPopupHits) { _, _ in
            incrementalSheetDetent = incrementalPreferredSheetDetent
        }
    }

    private func incrementalPopupPage(_ page: IncrementalLookupCollapsed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.matchedSurface)
                    .font(.headline)
                    .lineLimit(1)

                Text(page.gloss)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(2)

                if let kanaList = page.kanaList, kanaList.isEmpty == false {
                    Text(kanaList)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let isAnySaved = page.entries.contains { isSavedWord(for: page.matchedSurface, preferredReading: nil, entry: $0) }
            Button {
                if isAnySaved {
                    for entry in page.entries where isSavedWord(for: page.matchedSurface, preferredReading: nil, entry: entry) {
                        toggleSavedWord(surface: page.matchedSurface, preferredReading: nil, entry: entry)
                    }
                } else if let first = page.entries.first {
                    toggleSavedWord(surface: page.matchedSurface, preferredReading: nil, entry: first)
                }
                recomputeSavedWordOverlays()
            } label: {
                Image(systemName: isAnySaved ? "bookmark.fill" : "bookmark")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAnySaved ? "Remove Bookmark" : "Bookmark")
        }
        .padding(.vertical, 10)
    }

    func startIncrementalLookup(atUTF16Index index: Int) {
        guard incrementalLookupEnabled else { return }
        let nsText = inputText as NSString
        guard nsText.length > 0 else { return }
        guard index >= 0, index < nsText.length else { return }

        // If the tap lands on a newline, ignore.
        let tappedRange = nsText.rangeOfComposedCharacterSequence(at: index)
        let tappedChar = nsText.substring(with: tappedRange)
        if tappedChar == "\n" || tappedChar == "\r" {
            incrementalLookupTask?.cancel()
            incrementalSelectedCharacterRange = nil
            isIncrementalPopupVisible = false
            incrementalPopupHits = []
            return
        }

        incrementalLookupTask?.cancel()
        incrementalPopupHits = []
        isIncrementalPopupVisible = false

        let start = tappedRange.location
        incrementalLookupTask = Task {
            // Token-aligned candidate expansion (no character-by-character growth).
            let tokens: [TextSpan] = await MainActor.run {
                furiganaSpans?.map(\.span) ?? []
            }
            let candidates = SelectionSpanResolver.candidates(selectedRange: tappedRange, tokenSpans: tokens, text: nsText)
            var hits: [IncrementalLookupHit] = []
            hits.reserveCapacity(16)
            var seen: Set<String> = []

            // If Stage-2 semantic spans are ready, we can reuse their MeCab-derived lemma candidates.
            // This lets inflected surfaces still count as "a word" (lookup via lemma) without running
            // MeCab again per incremental candidate.
            let lemmaCandidatesBySurface: [String: [String]] = await MainActor.run {
                var out: [String: [String]] = [:]
                for semantic in furiganaSemanticSpans {
                    // Only consider spans that begin at the tapped offset.
                    guard semantic.range.location == start else { continue }
                    let surface = semantic.surface
                    guard surface.isEmpty == false else { continue }
                    let lemmas = aggregatedAnnotatedSpan(for: semantic)
                        .lemmaCandidates
                        .filter { $0.isEmpty == false }
                    if lemmas.isEmpty == false {
                        out[surface] = lemmas
                    }
                }
                return out
            }

            func appendRows(_ rows: [DictionaryEntry], matchedSurface: String) async {
                // This Task is not main-actor isolated; only touch MainActor-isolated properties via MainActor.run.
                for row in rows {
                    let rowID = await MainActor.run { row.id }
                    let key = "\(matchedSurface)#\(rowID)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    hits.append(IncrementalLookupHit(matchedSurface: matchedSurface, entry: row))
                }
            }

            for cand in candidates {
                guard Task.isCancelled == false else { return }

                // Reduplication is structural, not semantic:
                // If the candidate covers exactly two adjacent identical tokens (after normalization),
                // prefer looking up the single token and do not treat the combined surface as a unit.
                if let startIdx = tokens.firstIndex(where: { $0.range.location == cand.range.location }), (startIdx + 1) < tokens.count {
                    let a = tokens[startIdx]
                    let b = tokens[startIdx + 1]
                    if NSMaxRange(b.range) == NSMaxRange(cand.range), NSMaxRange(a.range) == b.range.location {
                        let k0 = DictionaryKeyPolicy.lookupKey(for: a.surface)
                        let k1 = DictionaryKeyPolicy.lookupKey(for: b.surface)
                        if k0.isEmpty == false, k0 == k1 {
                            // Only apply if X exists and XX does not.
                            if let singleRows = try? await DictionarySQLiteStore.shared.lookup(term: k0, limit: 50), singleRows.isEmpty == false {
                                if let combinedRows = try? await DictionarySQLiteStore.shared.lookup(term: cand.lookupKey, limit: 1), combinedRows.isEmpty {
                                    if ProcessInfo.processInfo.environment["REDUP_TRACE"] == "1" {
                                        CustomLogger.shared.info("Incremental lookup reduplication: using single token lookup for «\(a.surface)» «\(b.surface)»")
                                    }
                                    await appendRows(singleRows, matchedSurface: a.surface)
                                    await appendRows(singleRows, matchedSurface: b.surface)
                                    continue
                                }
                            }
                        }
                    }
                }

                if let rows = try? await DictionarySQLiteStore.shared.lookup(term: cand.lookupKey, limit: 50), rows.isEmpty == false {
                    await appendRows(rows, matchedSurface: cand.displayKey)
                    continue
                }

                // Deinflection hard stop: on surface miss, try deinflected lemma candidates.
                if let deinflector = try? await MainActor.run(resultType: Deinflector.self, body: {
                    try Deinflector.loadBundled(named: "deinflect")
                }) {
                    let deinflected = await MainActor.run { deinflector.deinflect(cand.displayKey, maxDepth: 8, maxResults: 32) }
                    for d in deinflected {
                        guard Task.isCancelled == false else { return }
                        if d.trace.isEmpty { continue }
                        let keys = DictionaryKeyPolicy.keys(forDisplayKey: d.baseForm)
                        guard keys.lookupKey.isEmpty == false else { continue }
                        if let rows = try? await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 50), rows.isEmpty == false {
                            if ProcessInfo.processInfo.environment["DEINFLECT_HARDSTOP_TRACE"] == "1" {
                                let trace = d.trace.map { "\($0.reason):\($0.rule.kanaIn)->\($0.rule.kanaOut)" }.joined(separator: ",")
                                CustomLogger.shared.info("Incremental lookup deinflection hard-stop: «\(cand.displayKey)» -> «\(keys.displayKey)» trace=[\(trace)]")
                            }
                            await appendRows(rows, matchedSurface: cand.displayKey)
                            break
                        }
                    }
                }

                // Lemmatization fallback: if this candidate corresponds to a Stage-2 token surface,
                // try its lemma candidates (base forms) against the dictionary.
                if let lemmas = lemmaCandidatesBySurface[cand.displayKey], lemmas.isEmpty == false {
                    for lemma in lemmas {
                        guard Task.isCancelled == false else { return }
                        let keys = DictionaryKeyPolicy.keys(forDisplayKey: lemma)
                        guard keys.lookupKey.isEmpty == false else { continue }
                        if let rows = try? await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 50), rows.isEmpty == false {
                            await appendRows(rows, matchedSurface: cand.displayKey)
                        }
                    }
                }
            }

            guard Task.isCancelled == false else { return }
            await MainActor.run {
                incrementalPopupHits = hits
                isIncrementalPopupVisible = hits.isEmpty == false
                if hits.isEmpty == false {
                    incrementalSheetDetent = incrementalPreferredSheetDetent
                }
            }
        }
    }

    func recomputeSavedWordOverlays() {
        guard incrementalLookupEnabled else {
            savedWordOverlays = []
            return
        }
        guard let noteID = currentNote?.id else {
            savedWordOverlays = []
            return
        }
        let savedWords = words.words
            .filter { $0.sourceNoteIDs.contains(noteID) }
        let candidateSurfaces = savedWords
            .map { $0.surface.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard candidateSurfaces.isEmpty == false else {
            savedWordOverlays = []
            return
        }
        let nsText = inputText as NSString
        guard nsText.length > 0 else {
            savedWordOverlays = []
            return
        }

        let savedColor = UIColor(hexString: alternateTokenColorAHex) ?? UIColor.systemBlue

        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(min(256, candidateSurfaces.count * 2))

        var seenRanges: Set<String> = []

        // Primary path: use Stage-2 spans (surface + lemma candidates) so bookmarked base forms
        // will still color inflected occurrences in running text.
        let savedSurfaceKeys = Set(candidateSurfaces.map { kanaFoldToHiragana($0) })
        if furiganaSemanticSpans.isEmpty == false {
            for semantic in furiganaSemanticSpans {
                guard semantic.range.location != NSNotFound, semantic.range.length > 0 else { continue }
                guard NSMaxRange(semantic.range) <= nsText.length else { continue }

                let surface = semantic.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }

                let aggregated = aggregatedAnnotatedSpan(for: semantic)
                var candidates: [String] = []
                candidates.reserveCapacity(1 + aggregated.lemmaCandidates.count)
                candidates.append(surface)
                candidates.append(contentsOf: aggregated.lemmaCandidates)

                var isSaved = false
                for cand in candidates {
                    let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    if savedSurfaceKeys.contains(kanaFoldToHiragana(trimmed)) {
                        isSaved = true
                        break
                    }
                }
                guard isSaved else { continue }

                let rangeKey = "\(semantic.range.location)#\(semantic.range.length)"
                if seenRanges.contains(rangeKey) == false {
                    seenRanges.insert(rangeKey)
                    overlays.append(RubyText.TokenOverlay(range: semantic.range, color: savedColor))
                }
            }
        }

        // Fallback path: literal substring scan for cases where spans aren't available yet.
        for surface in candidateSurfaces {
            for variant in kanaVariants(surface) {
                var search = NSRange(location: 0, length: nsText.length)
                while search.length > 0 {
                    let found = nsText.range(of: variant, options: [], range: search)
                    if found.location == NSNotFound || found.length == 0 { break }
                    let rangeKey = "\(found.location)#\(found.length)"
                    if seenRanges.contains(rangeKey) == false {
                        seenRanges.insert(rangeKey)
                        overlays.append(RubyText.TokenOverlay(range: found, color: savedColor))
                    }
                    let nextLoc = NSMaxRange(found)
                    if nextLoc >= nsText.length { break }
                    search = NSRange(location: nextLoc, length: nsText.length - nextLoc)
                }
            }
        }

        savedWordOverlays = overlays
    }
}
