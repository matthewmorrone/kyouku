import Foundation
import Mecab_Swift
import IPADic

/// MorphologicalIntegrityGate
///
/// Prevents invalid internal splits inside a single conjugated verb phrase.
///
/// Why this exists:
/// - Splitting inside a conjugated verb phrase (e.g. 抱き｜しめ｜て, 辞め｜ない｜で, 愛し｜てい｜る)
///   creates spans that are not valid lexical lookup units.
/// - These splits reliably produce nonsensical dictionary lookups, even when the user can
///   manually merge them into a single lemma-bearing unit.
///
/// This is a hard structural constraint:
/// - Runs BEFORE any candidate generation and embedding-based scoring.
/// - Does NOT rely on embeddings.
/// - Does NOT rewrite surface text (merged surfaces are sliced from the original text).
/// - Uses MeCab/IPADic POS + non-independence markers to detect verb + bound morpheme chains.
struct MorphologicalIntegrityGate {
    private struct MorphToken {
        let range: NSRange
        let surface: String
        let dictionaryForm: String
        let partOfSpeech: String

        var coarsePOS: String {
            partOfSpeech.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? partOfSpeech
        }

        var isVerb: Bool { coarsePOS == "動詞" }
        var isParticle: Bool { coarsePOS == "助詞" }
        var isAuxiliary: Bool { coarsePOS == "助動詞" }

        /// True when MeCab classifies this token as grammatically bound / non-independent.
        ///
        /// This avoids word-specific lists: we rely on IPADic feature tags.
        var isNonIndependent: Bool {
            partOfSpeech.contains("非自立") || partOfSpeech.contains("接尾")
        }

        /// Bound follower tokens in a conjugated verb phrase.
        ///
        /// Structural rule (not a word list):
        /// - particles/auxiliaries are bound
        /// - non-independent verbs/adjectives act as bound auxiliaries (e.g., いる in ～ている)
        var isBoundFollower: Bool {
            if isParticle || isAuxiliary { return true }
            if isVerb && isNonIndependent { return true }
            if coarsePOS == "形容詞" && isNonIndependent { return true }
            return false
        }

        var isHardStopSurface: Bool {
            surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) ||
            surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) })
        }
    }

    private static var sharedTokenizer: Tokenizer? = {
        try? Tokenizer(dictionary: IPADic())
    }()

    struct Result {
        let spans: [TextSpan]
        /// Count of merges performed by the gate.
        let merges: Int
    }

    /// Applies the gate by pre-merging Stage-1 spans within detected verb phrases.
    ///
    /// - Parameters:
    ///   - text: original input text as NSString (UTF-16 indexed)
    ///   - spans: Stage-1 tokenization spans
    ///   - hardCuts: user-locked hard boundaries (UTF-16 indices) that must not be crossed
    ///   - trie: optional in-memory JMdict surface trie; used only to set `isLexiconMatch` on merged spans
    /// - Returns: spans with verb-internal splits suppressed
    static func apply(text: NSString, spans: [TextSpan], hardCuts: [Int], trie: LexiconTrie?) -> Result {
        guard spans.count >= 2 else { return Result(spans: spans, merges: 0) }
        guard let tokenizer = sharedTokenizer else { return Result(spans: spans, merges: 0) }

        let traceEnabled: Bool = {
            let env = ProcessInfo.processInfo.environment
            return env["MORPH_INTEGRITY_TRACE"] == "1" || env["EMBED_BOUNDARY_TRACE"] == "1"
        }()

        // Tokenize full text once.
        let tokens: [MorphToken] = tokenizer.tokenize(text: text as String).compactMap { ann in
            let nsRange = NSRange(ann.range, in: text as String)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
            let surface = text.substring(with: nsRange)
            let pos = String(describing: ann.partOfSpeech)
            return MorphToken(
                range: nsRange,
                surface: surface,
                dictionaryForm: ann.dictionaryForm,
                partOfSpeech: pos
            )
        }

        guard tokens.isEmpty == false else { return Result(spans: spans, merges: 0) }

        let cutSet = Set(hardCuts)
        func crossesHardCut(_ r: NSRange) -> Bool {
            guard r.length > 0 else { return false }
            for c in cutSet {
                if c > r.location && c < NSMaxRange(r) {
                    return true
                }
            }
            return false
        }

        func isContiguous(_ a: NSRange, _ b: NSRange) -> Bool {
            NSMaxRange(a) == b.location
        }

        // Identify gated phrase ranges.
        var gatedRanges: [NSRange] = []
        gatedRanges.reserveCapacity(16)

        var i = 0
        while i < tokens.count {
            let head = tokens[i]
            if head.isHardStopSurface || head.isVerb == false {
                i += 1
                continue
            }

            // Extend through bound followers, requiring contiguity.
            var j = i
            while (j + 1) < tokens.count {
                let next = tokens[j + 1]
                guard isContiguous(tokens[j].range, next.range) else { break }
                guard next.isHardStopSurface == false else { break }
                guard next.isBoundFollower else { break }
                j += 1
            }

            if j == i {
                i += 1
                continue
            }

            let phraseRange = NSUnionRange(head.range, tokens[j].range)

            // Respect user-locked boundaries.
            if crossesHardCut(phraseRange) {
                i += 1
                continue
            }

            gatedRanges.append(phraseRange)
            if traceEnabled {
                let surface = text.substring(with: phraseRange)
                CustomLogger.shared.info("MorphologicalIntegrityGate: boundary-frozen verb phrase \(phraseRange.location)-\(NSMaxRange(phraseRange)) «\(surface)» lemma=«\(head.dictionaryForm)»")
            }

            i = j + 1
        }

        guard gatedRanges.isEmpty == false else {
            return Result(spans: spans, merges: 0)
        }

        // Merge Stage-1 spans that fall inside any gated range.
        // We do not cross non-contiguity and we do not cross hardCuts.
        var out: [TextSpan] = []
        out.reserveCapacity(spans.count)

        var merges = 0
        var s = 0
        while s < spans.count {
            let span = spans[s]

            // Find a gated range that fully contains this span.
            guard let gate = gatedRanges.first(where: { $0.location <= span.range.location && NSMaxRange(span.range) <= NSMaxRange($0) }) else {
                out.append(span)
                s += 1
                continue
            }

            // Merge forward while inside gate.
            var endIndex = s
            var mergedRange = spans[s].range
            while (endIndex + 1) < spans.count {
                let next = spans[endIndex + 1]
                // Must remain within the gated range.
                guard NSMaxRange(next.range) <= NSMaxRange(gate) else { break }
                // Must be contiguous.
                guard NSMaxRange(mergedRange) == next.range.location else { break }
                // Must not cross a user hard cut.
                if cutSet.contains(NSMaxRange(mergedRange)) { break }
                mergedRange = NSUnionRange(mergedRange, next.range)
                endIndex += 1
            }

            if endIndex > s {
                merges += 1
                let surface = text.substring(with: mergedRange)
                let isLex = trie?.containsWord(surface, requireKanji: false) ?? false
                out.append(TextSpan(range: mergedRange, surface: surface, isLexiconMatch: isLex))
                s = endIndex + 1
            } else {
                out.append(span)
                s += 1
            }
        }

        return Result(spans: out, merges: merges)
    }
}
