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
    @Published var query: String = ""
    @Published var results: [DictionaryEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(term: String, fallbackTerms: [String] = [], mode: DictionarySearchMode = .japanese) async {
        let primary = term.trimmingCharacters(in: .whitespacesAndNewlines)
        query = primary

        let normalizedFallbacks = fallbackTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var candidates: [String] = []
        for candidate in [primary] + normalizedFallbacks {
            guard candidate.isEmpty == false else { continue }
            if candidates.contains(candidate) == false {
                candidates.append(candidate)
            }
        }

        guard candidates.isEmpty == false else {
            results = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        for candidate in candidates {
            do {
                // Keep SQLite work off the MainActor so highlight/ruby overlays can render immediately.
                let payload: (rows: [DictionaryEntry], priority: [Int64: Int]) = try await Task.detached(priority: .userInitiated) {
                    let rows = try await DictionarySQLiteStore.shared.lookup(term: candidate, limit: 50, mode: mode)
                    let ids = Array(Set(rows.map { $0.entryID }))
                    let priority = (try? await DictionarySQLiteStore.shared.fetchEntryPriorityScores(for: ids)) ?? [:]
                    return (rows, priority)
                }.value

                if payload.rows.isEmpty == false {
                    let rankedRows = rankResults(payload.rows, for: candidate, mode: mode, entryPriority: payload.priority)
                    results = rankedRows
                    isLoading = false
                    errorMessage = nil
                    return
                }
            } catch {
                results = []
                errorMessage = String(describing: error)
                isLoading = false
                return
            }
        }

        results = []
        isLoading = false
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


