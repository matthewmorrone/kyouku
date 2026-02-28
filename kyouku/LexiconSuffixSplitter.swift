import Foundation

/// LexiconSuffixSplitter
///
/// Split-only structural pass that peels off certain trailing one-character hiragana
/// suffixes when doing so reveals a lexicon word.
///
/// Why this exists:
/// - MeCab sometimes tokenizes sentence-final particles as part of an unknown surface
///   (e.g. "ぼっちよ" as a single token).
/// - Stage 1.25 may then preserve or even coalesce those ranges.
/// - If we can split into (known lexicon word) + (known suffix), Stage 1.75 can
///   subsequently merge dictionary-valid multi-token spans.
///
/// Constraints:
/// - Pure in-memory: consults only the already-loaded `LexiconTrie`.
/// - Split-only: never merges, never reorders, preserves exact UTF-16 coverage.
/// - Conservative: acts only when the full surface is NOT a lexicon word and both
///   the base and suffix are lexicon words.
enum LexiconSuffixSplitter {
    private static let candidateSuffixes: Set<String> = [
        // Common sentence-final particles / interjections.
        // Keep this intentionally small; expand only when tests demonstrate need.
        "よ", "ね", "な", "ぞ", "ぜ", "さ", "わ", "か",
        // Case / topic / connective particles that are frequently glued to the previous span.
        "が", "を", "に", "へ", "と", "は", "も", "の"
    ]

    private static let leadingParticlePrefixes: Set<String> = [
        "が", "を", "に", "へ", "と", "は", "も", "の"
    ]

    private static let carryToPreviousBases: Set<String> = ["た", "だ", "さ"]

    static func apply(text: NSString, spans: [TextSpan], trie: LexiconTrie, deinflector: Deinflector? = nil) -> [TextSpan] {
        guard spans.isEmpty == false else { return spans }

        func hasLexiconOrLemmaHit(_ surface: String) -> Bool {
            if trie.containsWord(surface, requireKanji: false) {
                return true
            }
            guard let deinflector else { return false }
            let candidates = deinflector.deinflect(surface, maxDepth: 6, maxResults: 24)
            return candidates.contains { trie.containsWord($0.surface, requireKanji: false) }
        }

        // Never split across explicit hard-stop surfaces.
        func isHardStopSurface(_ surface: String) -> Bool {
            surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
                || surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) })
        }

        var out: [TextSpan] = []
        out.reserveCapacity(spans.count + 2)

        for span in spans {
            let r = span.range
            guard r.location != NSNotFound, r.length >= 2, NSMaxRange(r) <= text.length else {
                out.append(span)
                continue
            }

            // Always derive the surface from the authoritative UTF-16 range.
            // This keeps range/surface consistent even if upstream spans were normalized.
            let surface = text.substring(with: r)
            if surface.isEmpty || isHardStopSurface(surface) {
                out.append(span)
                continue
            }

            let endIndex = NSMaxRange(r) - 1
            guard endIndex >= r.location else {
                out.append(span)
                continue
            }

            let firstCharRange = text.rangeOfComposedCharacterSequence(at: r.location)
            let lastCharRange = text.rangeOfComposedCharacterSequence(at: endIndex)

            let firstIsSingleUnit = firstCharRange.length == 1
            let lastIsSingleUnit = lastCharRange.length == 1
            let firstSurface = firstIsSingleUnit ? text.substring(with: firstCharRange) : ""
            let suffix = lastIsSingleUnit ? text.substring(with: lastCharRange) : ""

            let canTryPrefixParticleSplit: Bool = {
                guard firstIsSingleUnit else { return false }
                guard leadingParticlePrefixes.contains(firstSurface) else { return false }
                return NSMaxRange(firstCharRange) < NSMaxRange(r)
            }()

            let canTrySuffixSplit = lastIsSingleUnit && candidateSuffixes.contains(suffix)

            if canTryPrefixParticleSplit == false,
               canTrySuffixSplit == false,
               trie.containsWord(surface, requireKanji: false) {
                out.append(span)
                continue
            }

            // Prefix carry-to-previous for glued auxiliary starts (e.g. ひい + たみたい -> ひいた + みたい).
            if firstIsSingleUnit,
               carryToPreviousBases.contains(firstSurface),
               NSMaxRange(firstCharRange) < NSMaxRange(r),
               let previous = out.last,
               NSMaxRange(previous.range) == r.location {
                let remainderRange = NSRange(location: NSMaxRange(firstCharRange), length: NSMaxRange(r) - NSMaxRange(firstCharRange))
                if remainderRange.length > 0, NSMaxRange(remainderRange) <= text.length {
                    let remainderSurface = text.substring(with: remainderRange)
                    let combinedRange = NSRange(location: previous.range.location, length: previous.range.length + firstCharRange.length)
                    let combinedSurface = text.substring(with: combinedRange)
                    if hasLexiconOrLemmaHit(combinedSurface), hasLexiconOrLemmaHit(remainderSurface) {
                        _ = out.removeLast()
                        out.append(TextSpan(range: combinedRange, surface: combinedSurface, isLexiconMatch: true))
                        out.append(TextSpan(range: remainderRange, surface: remainderSurface, isLexiconMatch: true))
                        continue
                    }
                }
            }

            // Prefix particle peel (e.g. はく -> は + く, のす -> の + す)
            if canTryPrefixParticleSplit {
                let remainderRange = NSRange(location: NSMaxRange(firstCharRange), length: NSMaxRange(r) - NSMaxRange(firstCharRange))
                if remainderRange.length > 0, NSMaxRange(remainderRange) <= text.length {
                    let remainderSurface = text.substring(with: remainderRange)
                    if trie.containsWord(firstSurface, requireKanji: false), hasLexiconOrLemmaHit(remainderSurface) {
                        out.append(TextSpan(range: firstCharRange, surface: firstSurface, isLexiconMatch: true))
                        out.append(TextSpan(range: remainderRange, surface: remainderSurface, isLexiconMatch: true))
                        continue
                    }
                }
            }

            // Suffix particle peel (e.g. さが -> さ + が), with optional carry of a one-char base
            // into the previous span (e.g. 愛し + さが -> 愛しさ + が).
            if canTrySuffixSplit {
                let suffixRange = lastCharRange
                let baseEnd = suffixRange.location
                if baseEnd > r.location {
                    let baseRange = NSRange(location: r.location, length: baseEnd - r.location)
                    if baseRange.length >= 1 {
                        let baseSurface = text.substring(with: baseRange)
                        if baseSurface.isEmpty == false,
                           trie.containsWord(suffix, requireKanji: false),
                           hasLexiconOrLemmaHit(baseSurface) {
                            if baseRange.length == 1,
                               carryToPreviousBases.contains(baseSurface),
                               let previous = out.last,
                               NSMaxRange(previous.range) == r.location {
                                let combinedRange = NSRange(location: previous.range.location, length: previous.range.length + baseRange.length)
                                if combinedRange.length > 0, NSMaxRange(combinedRange) <= text.length {
                                    let combinedSurface = text.substring(with: combinedRange)
                                    if hasLexiconOrLemmaHit(combinedSurface) {
                                        _ = out.removeLast()
                                        out.append(TextSpan(range: combinedRange, surface: combinedSurface, isLexiconMatch: true))
                                        out.append(TextSpan(range: suffixRange, surface: suffix, isLexiconMatch: true))
                                        continue
                                    }
                                }
                            }

                            out.append(TextSpan(range: baseRange, surface: baseSurface, isLexiconMatch: true))
                            out.append(TextSpan(range: suffixRange, surface: suffix, isLexiconMatch: true))
                            continue
                        }
                    }
                }
            }

            out.append(span)
        }

        return out
    }
}
