import Foundation

/// Deterministic ranking for dictionary candidates when multiple entries share the same reading.
///
/// Goals:
/// - Prefer entries whose surface is a canonical/common written form.
/// - Treat orthographic variants as fallbacks (they should not outrank a canonical spelling).
/// - Provide explainable, debuggable ordering.
struct DictionaryEntryResolver {
    struct CandidateScore: Comparable, CustomStringConvertible {
        // Lower is better for all fields.
        let surfaceMatchTier: Int
        let matchedFormCommonTier: Int
        let canonicalMismatchTier: Int
        let orthographicMarkednessPenalty: Int
        let entryPriorityScore: Int
        let missingReadingPenalty: Int
        let entryID: Int64

        static func < (lhs: CandidateScore, rhs: CandidateScore) -> Bool {
            if lhs.surfaceMatchTier != rhs.surfaceMatchTier { return lhs.surfaceMatchTier < rhs.surfaceMatchTier }
            if lhs.matchedFormCommonTier != rhs.matchedFormCommonTier { return lhs.matchedFormCommonTier < rhs.matchedFormCommonTier }
            if lhs.canonicalMismatchTier != rhs.canonicalMismatchTier { return lhs.canonicalMismatchTier < rhs.canonicalMismatchTier }
            if lhs.orthographicMarkednessPenalty != rhs.orthographicMarkednessPenalty { return lhs.orthographicMarkednessPenalty < rhs.orthographicMarkednessPenalty }
            if lhs.entryPriorityScore != rhs.entryPriorityScore { return lhs.entryPriorityScore < rhs.entryPriorityScore }
            if lhs.missingReadingPenalty != rhs.missingReadingPenalty { return lhs.missingReadingPenalty < rhs.missingReadingPenalty }
            return lhs.entryID < rhs.entryID
        }

        var description: String {
            "surfaceMatchTier=\(surfaceMatchTier) matchedFormCommonTier=\(matchedFormCommonTier) canonicalMismatchTier=\(canonicalMismatchTier) orthographyPenalty=\(orthographicMarkednessPenalty) priority=\(entryPriorityScore) missingReading=\(missingReadingPenalty) entryID=\(entryID)"
        }
    }

    /// Picks the best candidate for a given surface/reading.
    ///
    /// - Parameters:
    ///   - surface: Surface form as it appears in text (e.g. 合える).
    ///   - reading: Optional reading (kana) if known (e.g. あえる).
    ///   - candidates: Dictionary entries to rank.
    ///   - detailsByEntryID: Entry details (forms + POS tags).
    ///   - entryPriority: Lower is better.
    /// - Returns: Best entry (deterministic) or nil.
    static func chooseBest(
        surface: String,
        reading: String?,
        candidates: [DictionaryEntry],
        detailsByEntryID: [Int64: DictionaryEntryDetail],
        entryPriority: [Int64: Int]
    ) -> DictionaryEntry? {
        let keySurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keySurface.isEmpty == false else { return candidates.first }

        let scored: [(entry: DictionaryEntry, score: CandidateScore)] = candidates.map { entry in
            let detail = detailsByEntryID[entry.entryID]
            let score = scoreCandidate(surface: keySurface, reading: reading, entry: entry, detail: detail, entryPriority: entryPriority)
            return (entry, score)
        }

        return scored.min(by: { $0.score < $1.score })?.entry
    }

    static func scoreCandidate(
        surface: String,
        reading: String?,
        entry: DictionaryEntry,
        detail: DictionaryEntryDetail?,
        entryPriority: [Int64: Int]
    ) -> CandidateScore {
        let keySurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryKana = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1) Surface match tier
        // 0: exact surface appears as a kanji form
        // 1: exact surface appears as a kana form
        // 2: otherwise
        let surfaceMatchTier: Int = {
            guard let detail else {
                // With no details, fall back to the `DictionaryEntry.kanji`/`kana` strings.
                if entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines) == keySurface { return 0 }
                if entryKana == keySurface { return 1 }
                return 2
            }

            if detail.kanjiForms.contains(where: { $0.text == keySurface }) { return 0 }
            if detail.kanaForms.contains(where: { $0.text == keySurface }) { return 1 }
            return 2
        }()

        // 2) Matched-form commonality tier (exact surface is a common written form vs a rare variant)
        // 0: surface matches a common kanji/kana form
        // 1: surface matches only non-common forms, but entry has a different common form
        // 2: surface matches only non-common forms, and entry has no common forms
        let matchedFormCommonTier: Int = {
            guard let detail else { return 2 }

            let matchesKanji = detail.kanjiForms.filter { $0.text == keySurface }
            let matchesKana = detail.kanaForms.filter { $0.text == keySurface }
            let anyMatch = (matchesKanji + matchesKana)
            guard anyMatch.isEmpty == false else { return 2 }

            if anyMatch.contains(where: { $0.isCommon }) {
                return 0
            }

            let hasOtherCommonForm = detail.kanjiForms.contains(where: { $0.isCommon && $0.text != keySurface })
                || detail.kanaForms.contains(where: { $0.isCommon && $0.text != keySurface })

            return hasOtherCommonForm ? 1 : 2
        }()

        // 3) Canonical mismatch tier (is the surface the entry's canonical/common headword?)
        // 0: surface equals the best/common kanji headword
        // 1: surface is present, but canonical headword differs (variant spelling)
        // 2: surface not present in forms (fallback)
        let canonicalMismatchTier: Int = {
            guard let detail else {
                return (entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines) == keySurface) ? 0 : 2
            }

            let canonicalKanji = detail.kanjiForms
                .sorted(by: { lhs, rhs in
                    if lhs.isCommon != rhs.isCommon { return lhs.isCommon && rhs.isCommon == false }
                    return lhs.id < rhs.id
                })
                .first?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if canonicalKanji.isEmpty == false {
                if canonicalKanji == keySurface { return 0 }
                // Surface exists as a form, but isn't canonical.
                if detail.kanjiForms.contains(where: { $0.text == keySurface }) { return 1 }
                return 2
            }

            // If no kanji forms exist, treat kana as canonical.
            let canonicalKana = detail.kanaForms
                .sorted(by: { lhs, rhs in
                    if lhs.isCommon != rhs.isCommon { return lhs.isCommon && rhs.isCommon == false }
                    return lhs.id < rhs.id
                })
                .first?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if canonicalKana.isEmpty == false {
                if canonicalKana == keySurface { return 0 }
                if detail.kanaForms.contains(where: { $0.text == keySurface }) { return 1 }
            }
            return 2
        }()

        // 4) Orthographic markedness penalty from tags on the matched surface form.
        // This is intentionally coarse: any explicit rare/outdated/irregular tag should push it down.
        let orthographicMarkednessPenalty: Int = {
            guard let detail else { return 0 }

            func markednessPenalty(for tags: [String]) -> Int {
                let lowered = tags.map { $0.lowercased() }
                // These tag names are JMdict-ish; treat any presence as a strong hint that the form is marked.
                let heavy = ["rk", "ok", "ik", "ateji", "gikun"]
                if lowered.contains(where: { heavy.contains($0) }) { return 40 }
                return 0
            }

            var best = 0
            for form in detail.kanjiForms where form.text == keySurface {
                best = max(best, markednessPenalty(for: form.tags))
            }
            for form in detail.kanaForms where form.text == keySurface {
                best = max(best, markednessPenalty(for: form.tags))
            }
            return best
        }()

        let entryPriorityScore = entryPriority[entry.entryID] ?? 999

        // Prefer entries that actually have a reading when the caller expects one.
        let missingReadingPenalty: Int = {
            guard let keyReading, keyReading.isEmpty == false else { return 0 }
            return entryKana.isEmpty ? 1 : 0
        }()

        return CandidateScore(
            surfaceMatchTier: surfaceMatchTier,
            matchedFormCommonTier: matchedFormCommonTier,
            canonicalMismatchTier: canonicalMismatchTier,
            orthographicMarkednessPenalty: orthographicMarkednessPenalty,
            entryPriorityScore: entryPriorityScore,
            missingReadingPenalty: missingReadingPenalty,
            entryID: entry.entryID
        )
    }
}
