//
//  DictionaryLookupViewModel.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


import SwiftUI
import Combine
import Darwin

@MainActor
final class DictionaryLookupViewModel: ObservableObject {
    /// A stable snapshot of what the UI should *present*.
    ///
    /// IMPORTANT:
    /// - `phase` tracks the in-flight lookup lifecycle.
    /// - `presented` is the last fully-resolved lookup that should remain on screen.
    ///
    /// When a new lookup starts we flip `phase` to `.resolving`, but we intentionally
    /// keep `presented` unchanged so the inline panel stays mounted (no flicker).
    struct PresentedLookup: Equatable {
        let requestID: String
        let selection: TokenSelectionContext?
        let displayQuery: String
        let resolvedEmbeddingTerm: String?
        let results: [DictionaryEntry]
        let errorMessage: String?
    }

    /// High-level lookup lifecycle used to gate presentation.
    ///
    /// IMPORTANT: The goal is to avoid layout-janky intermediate states (e.g. empty -> loading -> empty -> loading)
    /// by treating selection lookup + deinflection + lemma fallbacks as a single transaction.
    enum LookupPhase: Equatable {
        case idle
        /// Resolving a specific request. `requestID` is used to suppress redundant lookups.
        case resolving(requestID: String)
        /// Lookup completed (successfully or with no hits). Use `results`/`errorMessage` for details.
        case ready(requestID: String)
    }

    @Published var query: String = ""
    @Published var results: [DictionaryEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    /// What the UI should render (stable, last-completed snapshot).
    /// Do NOT clear this when starting a new lookup; only update it when a lookup completes.
    @Published var presented: PresentedLookup? = nil

    /// Presentation gate for the inline panel. Keep this as the *primary* layout-driving signal.
    @Published private(set) var phase: LookupPhase = .idle

    /// The term (surface or lemma) that actually produced the current `results`, if any.
    ///
    /// This is intended for purely additive, read-only features (e.g. semantic neighbors)
    /// and must not affect lookup/boundary behavior.
    @Published var resolvedEmbeddingTerm: String? = nil

    private let deinflectionCache = DeinflectionCache()

    // Used to suppress redundant lookups (e.g., repeat tap on same token selection).
    private var lastCompletedRequestID: String? = nil

    private static let lookupTraceEnabled: Bool = {
        ProcessInfo.processInfo.environment["DICT_LOOKUP_TRACE"] == "1"
    }()

    private struct LookupHit {
        let displayKey: String
        let lookupKey: String
        let rows: [DictionaryEntry]
        let priority: [Int64: Int]
        let deinflectionTrace: String?
    }

    private func lookupSurfaceThenDeinflect(displayKey: String, lookupKey: String, mode: DictionarySearchMode) async throws -> LookupHit? {
        // 1) Exact surface lookup
        let surfacePayload: (rows: [DictionaryEntry], priority: [Int64: Int]) = try await Task.detached(priority: .userInitiated) {
            let rows = try await DictionarySQLiteStore.shared.lookup(term: lookupKey, limit: 50, mode: mode)
            let ids = Array(Set(rows.map { $0.entryID }))
            let priority = (try? await DictionarySQLiteStore.shared.fetchEntryPriorityScores(for: ids)) ?? [:]
            return (rows, priority)
        }.value

        if surfacePayload.rows.isEmpty == false {
            return LookupHit(displayKey: displayKey, lookupKey: lookupKey, rows: surfacePayload.rows, priority: surfacePayload.priority, deinflectionTrace: nil)
        }

        // 2) Deinflection lookup
        guard mode == .japanese else { return nil }
        let deinflected = await deinflectionCache.candidates(for: displayKey)
        for d in deinflected {
            if d.trace.isEmpty { continue }
            let keys = DictionaryKeyPolicy.keys(forDisplayKey: d.baseForm)
            guard keys.lookupKey.isEmpty == false else { continue }

            let lemmaPayload: (rows: [DictionaryEntry], priority: [Int64: Int]) = try await Task.detached(priority: .userInitiated) {
                let rows = try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 50, mode: mode)
                let ids = Array(Set(rows.map { $0.entryID }))
                let priority = (try? await DictionarySQLiteStore.shared.fetchEntryPriorityScores(for: ids)) ?? [:]
                return (rows, priority)
            }.value

            if lemmaPayload.rows.isEmpty == false {
                let trace = d.trace.map { "\($0.reason):\($0.rule.kanaIn)->\($0.rule.kanaOut)" }.joined(separator: ",")
                return LookupHit(displayKey: keys.displayKey, lookupKey: keys.lookupKey, rows: lemmaPayload.rows, priority: lemmaPayload.priority, deinflectionTrace: trace)
            }
        }

        return nil
    }

    private struct LookupOutcome {
        let displayQuery: String
        let resolvedEmbeddingTerm: String?
        let results: [DictionaryEntry]
        let errorMessage: String?
    }

    private func commitOutcome(_ outcome: LookupOutcome, requestID: String, selection: TokenSelectionContext?) {
        // Commit as a single end-of-transaction update:
        // - swap the stable `presented` snapshot
        // - mark the phase as ready
        // This keeps the inline panel mounted during `.resolving` and updates content atomically.
        let snapshot = PresentedLookup(
            requestID: requestID,
            selection: selection,
            displayQuery: outcome.displayQuery,
            resolvedEmbeddingTerm: outcome.resolvedEmbeddingTerm,
            results: outcome.results,
            errorMessage: outcome.errorMessage
        )

        presented = snapshot

        // Keep legacy published fields in sync for non-inline consumers.
        query = outcome.displayQuery
        results = outcome.results
        resolvedEmbeddingTerm = outcome.resolvedEmbeddingTerm
        errorMessage = outcome.errorMessage

        isLoading = false
        phase = .ready(requestID: requestID)
        lastCompletedRequestID = requestID
    }

    func reset() {
        // Used by PasteView when clearing selection.
        query = ""
        results = []
        resolvedEmbeddingTerm = nil
        errorMessage = nil
        isLoading = false
        phase = .idle
        lastCompletedRequestID = nil
        presented = nil
    }

    private func shouldSuppressLookup(for requestID: String) -> Bool {
        if lastCompletedRequestID == requestID {
            // Already completed and showing stable results for this selection.
            return true
        }
        if case .resolving(let active) = phase, active == requestID {
            // Currently resolving this exact request.
            return true
        }
        return false
    }

    /// Selection lookup + deinflection + lemma fallback in ONE transaction.
    ///
    /// This is the path used by PasteView to avoid UI jitter.
    func lookupTransaction(
        requestID: String,
        selection: TokenSelectionContext? = nil,
        selectedRange: NSRange,
        inText text: String,
        tokenSpans: [TextSpan],
        lemmaFallbacks: [String],
        mode: DictionarySearchMode = .japanese
    ) async {
        guard shouldSuppressLookup(for: requestID) == false else { return }

        // Single presentation gate flip.
        isLoading = true
        errorMessage = nil
        phase = .resolving(requestID: requestID)

        let nsText = text as NSString
        let displaySelection = (selectedRange.location != NSNotFound && selectedRange.length > 0 && selectedRange.location + selectedRange.length <= nsText.length)
            ? nsText.substring(with: selectedRange)
            : ""

        // Compute everything off to the side; publish exactly once at the end.
        let outcome: LookupOutcome
        do {
            // 1) Token-aligned selection lookup (surface -> deinflection).
            let candidates = SelectionSpanResolver.candidates(selectedRange: selectedRange, tokenSpans: tokenSpans, text: nsText)
            var triedLookupKeys: Set<String> = []
            triedLookupKeys.reserveCapacity(candidates.count * 2)

            func isReduplicationCandidate(_ candidate: SelectionSpanCandidate) -> (single: DictionaryKeyPolicy.Keys, leftSurface: String, rightSurface: String)? {
                // Candidate must cover exactly two consecutive token spans.
                guard let startIdx = tokenSpans.firstIndex(where: { $0.range.location == candidate.range.location }) else { return nil }
                guard (startIdx + 1) < tokenSpans.count else { return nil }
                let a = tokenSpans[startIdx]
                let b = tokenSpans[startIdx + 1]
                guard NSMaxRange(a.range) == b.range.location else { return nil }
                guard NSMaxRange(b.range) == NSMaxRange(candidate.range) else { return nil }

                let aKey = DictionaryKeyPolicy.lookupKey(for: a.surface)
                let bKey = DictionaryKeyPolicy.lookupKey(for: b.surface)
                guard aKey.isEmpty == false, aKey == bKey else { return nil }

                return (DictionaryKeyPolicy.keys(forDisplayKey: a.surface), a.surface, b.surface)
            }

            var hitOutcome: LookupOutcome? = nil
            if candidates.isEmpty == false {
                for cand in candidates {
                    // Reduplication structural preference (same logic as legacy selection lookup).
                    if mode == .japanese, let redup = isReduplicationCandidate(cand) {
                        let singleLookupKey = redup.single.lookupKey
                        let singleRows: [DictionaryEntry] = (try? await Task.detached(priority: .userInitiated) {
                            try await DictionarySQLiteStore.shared.lookup(term: singleLookupKey, limit: 1, mode: mode)
                        }.value) ?? []

                        if singleRows.isEmpty == false {
                            let combinedRows: [DictionaryEntry] = (try? await Task.detached(priority: .userInitiated) {
                                try await DictionarySQLiteStore.shared.lookup(term: cand.lookupKey, limit: 1, mode: mode)
                            }.value) ?? []

                            if combinedRows.isEmpty {
                                let payload: (rows: [DictionaryEntry], priority: [Int64: Int]) = try await Task.detached(priority: .userInitiated) {
                                    let rows = try await DictionarySQLiteStore.shared.lookup(term: singleLookupKey, limit: 50, mode: mode)
                                    let ids = Array(Set(rows.map { $0.entryID }))
                                    let priority = (try? await DictionarySQLiteStore.shared.fetchEntryPriorityScores(for: ids)) ?? [:]
                                    return (rows, priority)
                                }.value

                                if payload.rows.isEmpty == false {
                                    let ranked = rankResults(payload.rows, for: redup.single.displayKey, mode: mode, entryPriority: payload.priority)
                                    hitOutcome = LookupOutcome(displayQuery: displaySelection, resolvedEmbeddingTerm: redup.single.displayKey, results: ranked, errorMessage: nil)
                                    break
                                }
                            }
                        }
                    }

                    if triedLookupKeys.contains(cand.lookupKey) { continue }
                    triedLookupKeys.insert(cand.lookupKey)

                    if let hit = try await lookupSurfaceThenDeinflect(displayKey: cand.displayKey, lookupKey: cand.lookupKey, mode: mode) {
                        let ranked = rankResults(hit.rows, for: hit.displayKey, mode: mode, entryPriority: hit.priority)
                        hitOutcome = LookupOutcome(displayQuery: displaySelection, resolvedEmbeddingTerm: hit.displayKey, results: ranked, errorMessage: nil)
                        break
                    }
                }
            }

            // 2) If no hits, try MeCab lemma fallbacks (treated as part of the same transaction).
            if hitOutcome == nil {
                let trimmedFallbacks = lemmaFallbacks
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }

                for lemma in trimmedFallbacks {
                    // NOTE: We do NOT publish intermediate state between lemmas.
                    let keys = DictionaryKeyPolicy.keys(forDisplayKey: lemma)
                    guard keys.lookupKey.isEmpty == false else { continue }
                    if let hit = try await lookupSurfaceThenDeinflect(displayKey: keys.displayKey, lookupKey: keys.lookupKey, mode: mode) {
                        let ranked = rankResults(hit.rows, for: hit.displayKey, mode: mode, entryPriority: hit.priority)
                        hitOutcome = LookupOutcome(displayQuery: displaySelection, resolvedEmbeddingTerm: hit.displayKey, results: ranked, errorMessage: nil)
                        break
                    }
                }
            }

            outcome = hitOutcome ?? LookupOutcome(displayQuery: displaySelection, resolvedEmbeddingTerm: nil, results: [], errorMessage: nil)
        } catch {
            outcome = LookupOutcome(displayQuery: displaySelection, resolvedEmbeddingTerm: nil, results: [], errorMessage: String(describing: error))
        }

        // Only commit if this request is still the active one.
        // This avoids stale writes when rapid taps trigger overlapping Tasks.
        switch phase {
        case .resolving(let active) where active == requestID:
            commitOutcome(outcome, requestID: requestID, selection: selection)
        case .ready, .idle, .resolving:
            break
        }
    }

    func lookup(term: String, mode: DictionarySearchMode = .japanese) async {
        // Keep legacy API behavior, but batch-publish state to avoid UI jitter.
        let requestID = "term:\(mode):\(term.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard shouldSuppressLookup(for: requestID) == false else { return }

        isLoading = true
        errorMessage = nil
        phase = .resolving(requestID: requestID)

        let primaryKeys = DictionaryKeyPolicy.keys(forDisplayKey: term)
        let outcome: LookupOutcome
        do {
            guard primaryKeys.lookupKey.isEmpty == false else {
                outcome = LookupOutcome(displayQuery: primaryKeys.displayKey, resolvedEmbeddingTerm: nil, results: [], errorMessage: nil)
                commitOutcome(outcome, requestID: requestID, selection: nil)
                return
            }

            if let hit = try await lookupSurfaceThenDeinflect(displayKey: primaryKeys.displayKey, lookupKey: primaryKeys.lookupKey, mode: mode) {
                let ranked = rankResults(hit.rows, for: hit.displayKey, mode: mode, entryPriority: hit.priority)
                outcome = LookupOutcome(displayQuery: primaryKeys.displayKey, resolvedEmbeddingTerm: hit.displayKey, results: ranked, errorMessage: nil)

                if Self.lookupTraceEnabled {
                    if let trace = hit.deinflectionTrace {
                        CustomLogger.shared.info("DictionaryLookup resolved via deinflection display='\(primaryKeys.displayKey)' -> lemma='\(hit.displayKey)' trace=[\(trace)] rows=\(hit.rows.count)")
                    } else {
                        CustomLogger.shared.info("DictionaryLookup resolved display='\(hit.displayKey)' lookup='\(hit.lookupKey)' rows=\(hit.rows.count)")
                    }
                }
            } else {
                outcome = LookupOutcome(displayQuery: primaryKeys.displayKey, resolvedEmbeddingTerm: nil, results: [], errorMessage: nil)
            }
        } catch {
            outcome = LookupOutcome(displayQuery: primaryKeys.displayKey, resolvedEmbeddingTerm: nil, results: [], errorMessage: String(describing: error))
        }

        // Commit only if still relevant.
        if case .resolving(let active) = phase, active == requestID {
            commitOutcome(outcome, requestID: requestID, selection: nil)
        }
    }

    // Backwards-compatible wrapper.
    func load(term: String, fallbackTerms: [String] = [], mode: DictionarySearchMode = .japanese) async {
        // NOTE: legacy `fallbackTerms` are intentionally ignored for UI determinism.
        await lookup(term: term, mode: mode)
    }

    /// Selection-driven lookup: enumerate token-aligned spans containing the selection and stop on first hit.
    func lookup(
        selectedRange: NSRange,
        inText text: String,
        tokenSpans: [TextSpan],
        mode: DictionarySearchMode = .japanese
    ) async {
        // Legacy selection API remains, but is implemented via the transaction engine.
        // Use a deterministic requestID that prevents redundant lookups.
        let requestID = "sel:\(mode):\(selectedRange.location):\(selectedRange.length):\(text.hashValue)"
        await lookupTransaction(
            requestID: requestID,
            selection: nil,
            selectedRange: selectedRange,
            inText: text,
            tokenSpans: tokenSpans,
            lemmaFallbacks: [],
            mode: mode
        )
    }

    // Backwards-compatible wrapper.
    func load(
        selectedRange: NSRange,
        inText text: String,
        tokenSpans: [TextSpan],
        fallbackTerms: [String] = [],
        mode: DictionarySearchMode = .japanese
    ) async {
        // NOTE: legacy `fallbackTerms` are intentionally ignored for UI determinism.
        await lookup(selectedRange: selectedRange, inText: text, tokenSpans: tokenSpans, mode: mode)
    }
}

private extension DictionaryLookupViewModel {
    struct EnglishScore: Comparable {
        let bucket: Int
        let index: Int
        let commonPenalty: Int
        let priorityScore: Int
        let lengthDelta: Int
        let containsPenalty: Int
        let entryID: Int64

        static func < (lhs: EnglishScore, rhs: EnglishScore) -> Bool {
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            if lhs.commonPenalty != rhs.commonPenalty { return lhs.commonPenalty < rhs.commonPenalty }
            if lhs.priorityScore != rhs.priorityScore { return lhs.priorityScore < rhs.priorityScore }
            if lhs.lengthDelta != rhs.lengthDelta { return lhs.lengthDelta < rhs.lengthDelta }
            if lhs.containsPenalty != rhs.containsPenalty { return lhs.containsPenalty < rhs.containsPenalty }
            return lhs.entryID < rhs.entryID
        }
    }

    struct JapaneseScore: Comparable {
        let primaryMatch: Int
        let secondaryMatch: Int
        let commonPenalty: Int
        let priorityScore: Int
        let missingKanaPenalty: Int
        let lengthDelta: Int
        let kanjiLength: Int
        let entryID: Int64

        static func < (lhs: JapaneseScore, rhs: JapaneseScore) -> Bool {
            if lhs.primaryMatch != rhs.primaryMatch { return lhs.primaryMatch < rhs.primaryMatch }
            if lhs.secondaryMatch != rhs.secondaryMatch { return lhs.secondaryMatch < rhs.secondaryMatch }
            if lhs.commonPenalty != rhs.commonPenalty { return lhs.commonPenalty < rhs.commonPenalty }
            if lhs.priorityScore != rhs.priorityScore { return lhs.priorityScore < rhs.priorityScore }
            if lhs.missingKanaPenalty != rhs.missingKanaPenalty { return lhs.missingKanaPenalty < rhs.missingKanaPenalty }
            if lhs.lengthDelta != rhs.lengthDelta { return lhs.lengthDelta < rhs.lengthDelta }
            if lhs.kanjiLength != rhs.kanjiLength { return lhs.kanjiLength < rhs.kanjiLength }
            return lhs.entryID < rhs.entryID
        }
    }

    func rankResults(_ rows: [DictionaryEntry], for term: String, mode: DictionarySearchMode, entryPriority: [Int64: Int]) -> [DictionaryEntry] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return rows }

        switch mode {
        case .english:
            let key = trimmed.lowercased()
            return rows.sorted { lhs, rhs in
                if lhs.isCommon != rhs.isCommon {
                    return lhs.isCommon && rhs.isCommon == false
                }
                return englishScore(for: lhs, query: key, entryPriority: entryPriority) < englishScore(for: rhs, query: key, entryPriority: entryPriority)
            }
        case .japanese:
            // If the user typed Latin while in JP mode, the store will have already converted
            // to kana for matching. We still rank with a romaji-aware heuristic so results feel
            // "Jisho-like".
            if looksLikeLatinQuery(trimmed) {
                return rankRomajiResults(rows, query: trimmed, entryPriority: entryPriority)
            }
            return rankJapaneseResults(rows, query: trimmed, entryPriority: entryPriority)
        }
    }

    func rankJapaneseResults(_ rows: [DictionaryEntry], query: String, entryPriority: [Int64: Int]) -> [DictionaryEntry] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return rows }
        let queryHasKanji = containsKanji(key)
        let queryHasKana = containsKana(key)

        return rows.sorted { lhs, rhs in
            if lhs.isCommon != rhs.isCommon {
                return lhs.isCommon && rhs.isCommon == false
            }
            return japaneseScore(for: lhs, query: key, queryHasKanji: queryHasKanji, queryHasKana: queryHasKana, entryPriority: entryPriority)
                < japaneseScore(for: rhs, query: key, queryHasKanji: queryHasKanji, queryHasKana: queryHasKana, entryPriority: entryPriority)
        }
    }

    func rankRomajiResults(_ rows: [DictionaryEntry], query: String, entryPriority: [Int64: Int]) -> [DictionaryEntry] {
        let key = normalizeLatinQuery(query)
        guard key.isEmpty == false else { return rows }
        let kanaCandidates = romajiToKanaCandidates(key)

        return rows.sorted { lhs, rhs in
            if lhs.isCommon != rhs.isCommon {
                return lhs.isCommon && rhs.isCommon == false
            }
            return romajiScore(for: lhs, query: key, kanaCandidates: kanaCandidates, entryPriority: entryPriority)
                < romajiScore(for: rhs, query: key, kanaCandidates: kanaCandidates, entryPriority: entryPriority)
        }
    }

    func englishScore(for entry: DictionaryEntry, query: String, entryPriority: [Int64: Int]) -> EnglishScore {
        let components = glossComponents(from: entry.gloss)
        var bestBucket = 4
        var bestIndex = components.count
        var bestLengthDelta = Int.max
        var bestContainsPenalty = 1

        for (idx, component) in components.enumerated() {
            let bucket: Int
            if component == query {
                bucket = 0
            } else if component.hasPrefix(query) {
                bucket = 1
            } else if component.contains(query) {
                bucket = 2
            } else {
                bucket = 3
            }

            let lengthDelta = abs(component.count - query.count)
            let containsPenalty = component.contains(" ") ? 1 : 0
            let candidate = (bucket, idx, lengthDelta, containsPenalty)
            let best = (bestBucket, bestIndex, bestLengthDelta, bestContainsPenalty)
            if candidate.0 < best.0
                || (candidate.0 == best.0 && candidate.1 < best.1)
                || (candidate.0 == best.0 && candidate.1 == best.1 && candidate.2 < best.2)
                || (candidate.0 == best.0 && candidate.1 == best.1 && candidate.2 == best.2 && candidate.3 < best.3) {
                bestBucket = candidate.0
                bestIndex = candidate.1
                bestLengthDelta = candidate.2
                bestContainsPenalty = candidate.3
            }
        }

        let commonPenalty = entry.isCommon ? 0 : 1
        let priorityScore = entryPriority[entry.entryID] ?? 999
        return EnglishScore(
            bucket: bestBucket,
            index: bestIndex,
            commonPenalty: commonPenalty,
            priorityScore: priorityScore,
            lengthDelta: bestLengthDelta,
            containsPenalty: bestContainsPenalty,
            entryID: Int64(entry.entryID)
        )
    }

    func japaneseScore(for entry: DictionaryEntry, query: String, queryHasKanji: Bool, queryHasKana: Bool, entryPriority: [Int64: Int]) -> JapaneseScore {
        let kanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer matching the script the user typed.
        // Lower tuple sorts first.
        let kanjiMatch = matchBucket(candidate: kanji, query: query)
        let kanaMatch = matchBucket(candidate: kana, query: query)

        // Script-priority: if the query includes kanji, weight kanji matches more.
        // If the query is kana-only, weight kana matches more.
        let primaryMatch: Int
        let secondaryMatch: Int
        if queryHasKanji {
            primaryMatch = kanjiMatch
            secondaryMatch = kanaMatch
        } else if queryHasKana {
            primaryMatch = kanaMatch
            secondaryMatch = kanjiMatch
        } else {
            // Fallback: treat both equally.
            primaryMatch = min(kanjiMatch, kanaMatch)
            secondaryMatch = max(kanjiMatch, kanaMatch)
        }

        let commonPenalty = entry.isCommon ? 0 : 1
        let priorityScore = entryPriority[entry.entryID] ?? 999

        // Prefer shorter headwords when match quality is equal.
        let lengthDelta: Int = {
            let q = query.count
            let bestLen = minNonZero(kanji.count, kana.count) ?? kanji.count
            return abs(bestLen - q)
        }()

        // Favor entries that actually have a reading when the query is kana.
        let missingKanaPenalty = (queryHasKana && kana.isEmpty) ? 1 : 0

        return JapaneseScore(
            primaryMatch: primaryMatch,
            secondaryMatch: secondaryMatch,
            commonPenalty: commonPenalty,
            priorityScore: priorityScore,
            missingKanaPenalty: missingKanaPenalty,
            lengthDelta: lengthDelta,
            kanjiLength: kanji.count,
            entryID: Int64(entry.entryID)
        )
    }

    func romajiScore(for entry: DictionaryEntry, query: String, kanaCandidates: [String], entryPriority: [Int64: Int]) -> (Int, Int, Int, Int, Int, Int64) {
        let kana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let commonPenalty = entry.isCommon ? 0 : 1
        let priorityScore = entryPriority[entry.entryID] ?? 999

        // Best match over kana candidates.
        var bestBucket = 3
        var bestLengthDelta = Int.max
        for cand in kanaCandidates {
            let bucket = matchBucket(candidate: kana, query: cand)
            if bucket < bestBucket {
                bestBucket = bucket
                bestLengthDelta = abs(kana.count - cand.count)
            } else if bucket == bestBucket {
                let delta = abs(kana.count - cand.count)
                if delta < bestLengthDelta {
                    bestLengthDelta = delta
                }
            }
        }

        // If we couldn't produce kana candidates, fall back to commonness + stable order.
        if kanaCandidates.isEmpty {
            bestBucket = 2
            bestLengthDelta = kana.count
        }

        return (bestBucket, commonPenalty, priorityScore, bestLengthDelta, kana.count, Int64(entry.entryID))
    }

    // Match buckets:
    // 0 exact, 1 prefix, 2 substring, 3 none/empty.
    func matchBucket(candidate: String, query: String) -> Int {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.isEmpty == false, q.isEmpty == false else { return 3 }
        if c == q { return 0 }
        if c.hasPrefix(q) { return 1 }
        if c.contains(q) { return 2 }
        return 3
    }

    func containsJapaneseScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x3400...0x4DBF, // CJK Ext A
                 0x4E00...0x9FFF: // CJK Unified
                return true
            default:
                continue
            }
        }
        return false
    }

    func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9F:
                return true
            default:
                continue
            }
        }
        return false
    }

    func looksLikeLatinQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard containsJapaneseScript(trimmed) == false else { return false }

        var hasLatinLetter = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "'" || scalar == "-" { continue }
            // Common macron vowels used in romaji.
            if scalar == "ā" || scalar == "ī" || scalar == "ū" || scalar == "ē" || scalar == "ō" { hasLatinLetter = true; continue }
            if scalar == "Ā" || scalar == "Ī" || scalar == "Ū" || scalar == "Ē" || scalar == "Ō" { hasLatinLetter = true; continue }
            if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) { hasLatinLetter = true; continue }
            if (0x0030...0x0039).contains(scalar.value) { continue }
        }
        return hasLatinLetter
    }

    func normalizeLatinQuery(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let lowered = trimmed.lowercased()
        // Keep basic romaji punctuation commonly used for syllable boundaries.
        let filtered = lowered.filter { ch in
            if ch.isLetter || ch.isNumber { return true }
            if ch == "-" || ch == "'" { return true }
            return false
        }
        return filtered
    }

    func romajiToKanaCandidates(_ latin: String) -> [String] {
        // Best-effort: Foundation transliteration. This is not perfect, but it gives
        // good behavior for common romaji and keeps the app dependency-free.
        let rawKatakana = latin.applyingTransform(.latinToKatakana, reverse: false) ?? ""
        let hiragana = rawKatakana.applyingTransform(.hiraganaToKatakana, reverse: true) ?? rawKatakana
        let cleaned = hiragana.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }
        // Also offer katakana form as a fallback candidate.
        let katakana = cleaned.applyingTransform(.hiraganaToKatakana, reverse: false) ?? cleaned
        var out: [String] = []
        for cand in [cleaned, katakana] {
            let t = cand.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty == false, out.contains(t) == false {
                out.append(t)
            }
        }
        return out
    }

    func minNonZero(_ a: Int, _ b: Int) -> Int? {
        let aa = a > 0 ? a : nil
        let bb = b > 0 ? b : nil
        switch (aa, bb) {
        case (nil, nil):
            return nil
        case let (x?, nil):
            return x
        case let (nil, y?):
            return y
        case let (x?, y?):
            return min(x, y)
        }
    }

    func glossComponents(from gloss: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";,/")
        return gloss
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}


