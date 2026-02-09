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
        "よ", "ね", "な", "ぞ", "ぜ", "さ", "わ", "か"
    ]

    static func apply(text: NSString, spans: [TextSpan], trie: LexiconTrie) -> [TextSpan] {
        guard spans.isEmpty == false else { return spans }

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

            // If this is already a lexicon word, do not split.
            if trie.containsWord(surface, requireKanji: false) {
                out.append(span)
                continue
            }

            let endIndex = NSMaxRange(r) - 1
            guard endIndex >= r.location else {
                out.append(span)
                continue
            }

            let lastCharRange = text.rangeOfComposedCharacterSequence(at: endIndex)
            // Be conservative: only split when the trailing composed char is a single UTF-16 unit.
            guard lastCharRange.length == 1 else {
                out.append(span)
                continue
            }

            let suffixRange = lastCharRange
            let baseEnd = suffixRange.location
            guard baseEnd > r.location else {
                out.append(span)
                continue
            }

            let baseRange = NSRange(location: r.location, length: baseEnd - r.location)
            guard baseRange.length >= 1 else {
                out.append(span)
                continue
            }

            let suffix = text.substring(with: suffixRange)
            guard candidateSuffixes.contains(suffix) else {
                out.append(span)
                continue
            }

            let baseSurface = text.substring(with: baseRange)
            guard baseSurface.isEmpty == false else {
                out.append(span)
                continue
            }

            // Require both base and suffix to be lexicon words.
            guard trie.containsWord(baseSurface, requireKanji: false) else {
                out.append(span)
                continue
            }
            guard trie.containsWord(suffix, requireKanji: false) else {
                out.append(span)
                continue
            }

            out.append(TextSpan(range: baseRange, surface: baseSurface, isLexiconMatch: true))
            out.append(TextSpan(range: suffixRange, surface: suffix, isLexiconMatch: true))
        }

        return out
    }
}
