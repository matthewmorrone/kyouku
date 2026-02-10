import SwiftUI
import NaturalLanguage

extension WordDefinitionsView {
    // MARK: Verb conjugations
    var shouldShowVerbConjugations: Bool {
        guard entryDetails.isEmpty == false else { return false }
        guard verbConjugationVerbClass != nil else { return false }
        guard verbConjugationBaseForm.isEmpty == false else { return false }
        return true
    }

    var verbConjugationHeaderLine: String? {
        guard let verbClass = verbConjugationVerbClass else { return nil }
        let cls: String
        switch verbClass {
        case .ichidan: cls = "ichidan"
        case .godan: cls = "godan"
        case .suru: cls = "suru"
        case .kuru: cls = "kuru"
        }
        return "Based on lemma: \(verbConjugationBaseForm) (\(cls) verb)"
    }

    var verbConjugationBaseForm: String {
        let lemma = (resolvedLemmaText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lemma.isEmpty == false { return lemma }
        return titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var verbConjugationVerbClass: VerbConjugator.VerbClass? {
        let tags = verbPosTags
        return VerbConjugator.detectVerbClass(fromJMDictPosTags: tags)
    }

    var verbPosTags: [String] {
        var out: [String] = []
        var seen = Set<String>()
        for detail in entryDetails {
            for sense in detail.senses {
                for tag in sense.partsOfSpeech {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    let key = trimmed.lowercased()
                    if seen.insert(key).inserted {
                        out.append(trimmed)
                    }
                }
            }
        }
        return out
    }

    func verbConjugations(set: VerbConjugator.ConjugationSet) -> [VerbConjugation] {
        guard let verbClass = verbConjugationVerbClass else { return [] }
        return VerbConjugator.conjugations(for: verbConjugationBaseForm, verbClass: verbClass, set: set)
    }

    func japaneseHighlightTermsForSentences() -> [String] {
        // Keep aligned with `highlightedJapaneseSentence` behavior.
        let lookupAligned = sentenceLookupTerms(primaryTerms: [surface, kana].compactMap { $0 }, entryDetails: entryDetails)
        return lookupAligned
    }

    func englishHighlightRanges(in sentence: String) -> [NSRange] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else { return [] }

        let candidates = englishGlossPhraseCandidates()
        guard candidates.isEmpty == false else { return [] }

        // Choose the "best" phrase that actually appears in the sentence.
        // Preference order:
        // - more words (multi-word phrases are more aligned)
        // - longer phrase
        // - earlier occurrence
        var best: (phrase: String, regex: NSRegularExpression, score: Int, firstLocation: Int)? = nil

        for phrase in candidates {
            guard let regex = englishPhraseRegex(for: phrase) else { continue }
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            guard matches.isEmpty == false else { continue }

            let words = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            let score = (words * 10_000) + min(phrase.count, 1000)
            let firstLoc = matches.first?.range.location ?? Int.max
            if let b = best {
                if score > b.score || (score == b.score && firstLoc < b.firstLocation) {
                    best = (phrase, regex, score, firstLoc)
                }
            } else {
                best = (phrase, regex, score, firstLoc)
            }
        }

        if let best {
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            return best.regex.matches(in: s, range: range).map { $0.range }.filter { $0.length > 0 }
        }

        // Fallback: if no gloss phrase appears verbatim in the translation (e.g. “police” vs “cops”),
        // use Apple’s English word embedding to highlight semantically-near tokens.
        return englishEmbeddingHighlightRanges(in: s)
    }

    func englishEmbeddingHighlightRanges(in sentence: String) -> [NSRange] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else { return [] }

        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return [] }

        let keywords = englishGlossKeywordCandidates(maxCount: 36)
        guard keywords.isEmpty == false else { return [] }
        let keywordSet = Set(keywords)

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        tokenizer.setLanguage(.english)

        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct TokenInfo {
            let range: NSRange
            let text: String
            let normalized: String
        }

        struct ScoredRange {
            let range: NSRange
            let distance: Double
            let token: String
            let tokenIndex: Int
        }

        // Use embedding distance rather than neighbors() membership.
        // This is more stable for cases like “miss” vs “missed” and “old” (from gloss parentheses).
        let distanceThreshold: Double = 0.52
        // Pick a single best match (plus optional adjacent negation) to represent the
        // most likely English equivalent in the translation.
        let maxHighlights = 1

        let negationTokens: Set<String> = [
            "not", "no", "never", "dont", "don't", "cant", "can't", "cannot",
            "wont", "won't", "wouldnt", "wouldn't", "shouldnt", "shouldn't",
            "couldnt", "couldn't", "didnt", "didn't", "doesnt", "doesn't",
            "isnt", "isn't", "arent", "aren't", "wasnt", "wasn't", "werent", "weren't",
            "without"
        ]

        func englishLemma(for word: String) -> String? {
            let w = word.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard w.isEmpty == false else { return nil }
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = w
            // Use the stable overload available across iOS 15/16 SDKs.
            let result = tagger.tag(at: w.startIndex, unit: .word, scheme: .lemma)
            let lemma = result.0?.rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            return lemma.isEmpty ? nil : lemma
        }

        func bestDistance(for token: String) -> Double? {
            let normalized = normalizeEnglishWord(token)
            guard normalized.isEmpty == false else { return nil }
            if englishStopwords.contains(normalized) { return nil }
            if normalized.count < 3 { return nil }

            // Fast exact match path.
            if keywordSet.contains(normalized) { return 0 }

            let lemma = englishLemma(for: normalized).map { normalizeEnglishWord($0) }
            if let lemma, lemma.isEmpty == false, keywordSet.contains(lemma) { return 0 }

            var forms: [String] = [normalized]
            if let lemma, lemma.isEmpty == false, lemma != normalized { forms.append(lemma) }

            // Simple morphology helpers: plural/ed/ing.
            if normalized.hasSuffix("s"), normalized.count > 3 {
                forms.append(String(normalized.dropLast()))
            }
            if normalized.hasSuffix("ed"), normalized.count > 4 {
                forms.append(String(normalized.dropLast(2)))
            }
            if normalized.hasSuffix("ing"), normalized.count > 5 {
                forms.append(String(normalized.dropLast(3)))
            }

            var best: Double? = nil
            for f in forms {
                for kw in keywords {
                    if f == kw { return 0 }
                    let d = embedding.distance(between: f, and: kw)
                    guard d.isFinite else { continue }
                    if let b = best {
                        if d < b { best = d }
                    } else {
                        best = d
                    }
                }
            }
            return best
        }

        var tokens: [TokenInfo] = []
        tokens.reserveCapacity(24)

        var scored: [ScoredRange] = []
        scored.reserveCapacity(12)

        func isNegationToken(_ raw: String) -> Bool {
            let n = normalizeEnglishWord(raw)
            if n.isEmpty { return false }
            if negationTokens.contains(n) { return true }
            // Handle unicode apostrophe variants by removing apostrophes.
            let stripped = n.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            return negationTokens.contains(stripped)
        }

        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let r = NSRange(range, in: s)
            if r.location == NSNotFound || r.length <= 0 || NSMaxRange(r) > ns.length {
                return true
            }

            let tokenText = ns.substring(with: r)
            let normalized = normalizeEnglishWord(tokenText)
            let idx = tokens.count
            tokens.append(TokenInfo(range: r, text: tokenText, normalized: normalized))

            if let d = bestDistance(for: tokenText), d <= distanceThreshold {
                scored.append(ScoredRange(range: r, distance: d, token: tokenText, tokenIndex: idx))
            }
            return true
        }

        guard scored.isEmpty == false else { return [] }
        scored.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            // Prefer longer tokens when distance ties.
            if lhs.token.count != rhs.token.count { return lhs.token.count > rhs.token.count }
            return lhs.range.location < rhs.range.location
        }

        var picked: [NSRange] = []
        picked.reserveCapacity(maxHighlights * 2)

        for item in scored {
            // Expand to include a directly-adjacent negation token (e.g. "don't" + "mind")
            // without hardcoding any specific phrase patterns.
            if item.tokenIndex - 1 >= 0 {
                let prev = tokens[item.tokenIndex - 1]
                if isNegationToken(prev.text) {
                    picked.append(prev.range)
                }
            }
            picked.append(item.range)
            if picked.count >= maxHighlights * 2 { break }
        }

        // De-dupe while preserving order.
        var seenRanges: Set<String> = []
        picked = picked.filter { r in
            let key = "\(r.location):\(r.length)"
            if seenRanges.insert(key).inserted {
                return true
            }
            return false
        }

        // Ensure ranges are within bounds.
        return picked.filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= full.length }
    }

    var englishStopwords: Set<String> {
        [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "he",
            "her", "his", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on",
            "or", "our", "out", "she", "so", "that", "the", "their", "them", "then", "there", "they", "this",
            "to", "up", "us", "was", "we", "were", "what", "when", "where", "who", "will", "with", "you", "your"
        ]
    }

    func normalizeEnglishWord(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.isEmpty == false else { return "" }

        // Trim leading/trailing punctuation.
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        guard s.isEmpty == false else { return "" }

        // Strip possessive.
        if s.hasSuffix("'s") {
            s = String(s.dropLast(2))
        }
        return s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    func englishGlossKeywordCandidates(maxCount: Int) -> [String] {
        // Derive single-word keyword candidates from raw gloss text.
        // Includes parenthetical hints like "(old)" and basic morphology stems like "miss" from "missed".
        var out: [String] = []
        var seen: Set<String> = []

        func addWord(_ raw: String) {
            let w = normalizeEnglishWord(raw)
            guard w.isEmpty == false else { return }
            guard w.count >= 3 else { return }
            guard englishStopwords.contains(w) == false else { return }
            if seen.insert(w).inserted {
                out.append(w)
            }

            // Add a tiny set of stems (best-effort; no heavy lemmatizer here).
            if w.hasSuffix("ed"), w.count > 4 {
                let stem = String(w.dropLast(2))
                if stem.count >= 3, englishStopwords.contains(stem) == false, seen.insert(stem).inserted {
                    out.append(stem)
                }
            }
            if w.hasSuffix("s"), w.count > 3 {
                let stem = String(w.dropLast())
                if stem.count >= 3, englishStopwords.contains(stem) == false, seen.insert(stem).inserted {
                    out.append(stem)
                }
            }
        }

        func harvest(from text: String) {
            // Keep parenthetical content as additional candidates.
            // Example: "dear (old)" => add "dear" and "old".
            let separators = CharacterSet(charactersIn: ";,/\n")
            let parts = text
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }

            for part in parts {
                // Add outside parentheses.
                let outside: String = {
                    if let idx = part.firstIndex(of: "(") {
                        return String(part[..<idx])
                    }
                    return part
                }()
                outside
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
                    .forEach(addWord)

                // Add inside parentheses.
                if let open = part.firstIndex(of: "("), let close = part.firstIndex(of: ")"), open < close {
                    let inside = String(part[part.index(after: open)..<close])
                    inside
                        .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
                        .forEach(addWord)
                }

                if out.count >= max(1, maxCount) { return }
            }
        }

        for detail in entryDetails {
            let senses = orderedSensesForDisplay(detail)
            for sense in senses {
                let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
                let source = english.isEmpty ? sense.glosses : english
                for g in source {
                    harvest(from: g.text)
                    if out.count >= max(1, maxCount) { return out }
                }
            }
        }

        return out
    }

    func englishGlossPhraseCandidates() -> [String] {
        // Collect plausible English phrases from all senses.
        // We then try to match these phrases verbatim (case-insensitive) inside the translation.
        var out: [String] = []
        var seen: Set<String> = []

        for detail in entryDetails {
            let senses = orderedSensesForDisplay(detail)
            for sense in senses {
                let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
                let source = english.isEmpty ? sense.glosses : english
                for g in source {
                    let raw = g.text
                    for phrase in splitEnglishGlossPhrases(raw) {
                        let normalized = normalizeEnglishPhraseCandidate(phrase)
                        guard normalized.isEmpty == false else { continue }
                        let key = normalized.lowercased()
                        if seen.insert(key).inserted {
                            out.append(normalized)
                        }
                        if out.count >= 80 { break }
                    }
                    if out.count >= 80 { break }
                }
                if out.count >= 80 { break }
            }
            if out.count >= 80 { break }
        }

        // Prefer longer (more specific) phrases first.
        out.sort { a, b in
            let aw = a.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            let bw = b.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            if aw != bw { return aw > bw }
            if a.count != b.count { return a.count > b.count }
            return a < b
        }
        return out
    }

    func splitEnglishGlossPhrases(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        // Split on common gloss separators.
        let separators = CharacterSet(charactersIn: ";,/\n")
        let parts = trimmed
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        // Also strip parenthetical notes but keep the main phrase.
        return parts.map { part in
            if let idx = part.firstIndex(of: "(") {
                return String(part[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return part
        }.filter { $0.isEmpty == false }
    }

    func normalizeEnglishPhraseCandidate(_ phrase: String) -> String {
        var p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false else { return "" }

        // Remove leading "to " to better match actual translation phrases.
        if p.lowercased().hasPrefix("to ") {
            p = String(p.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop surrounding quotes.
        if (p.hasPrefix("\"") && p.hasSuffix("\"")) || (p.hasPrefix("'") && p.hasSuffix("'")) {
            p = String(p.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Keep only phrases that contain at least one letter.
        if p.rangeOfCharacter(from: .letters) == nil {
            return ""
        }

        // Avoid extremely generic phrases.
        let lower = p.lowercased()
        let banned: Set<String> = ["thing", "person", "something", "someone", "to do", "do"]
        if banned.contains(lower) {
            return ""
        }

        return p
    }

    func englishPhraseRegex(for phrase: String) -> NSRegularExpression? {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return nil }

        // Convert phrase into a word-boundary-aware regex, allowing flexible whitespace/hyphen.
        let words = cleaned
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map(String.init)
            .filter { $0.isEmpty == false }
        guard words.isEmpty == false else { return nil }

        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        let body = escaped.map { "\\b\($0)\\b" }.joined(separator: "[\\s\\-]+");

        do {
            return try NSRegularExpression(pattern: body, options: [.caseInsensitive])
        } catch {
            return nil
        }
    }

    func highlightedJapaneseSentence(_ sentence: String) -> AttributedString {
        let s = sentence
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return AttributedString(sentence) }

        var terms: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            if terms.contains(trimmed) == false {
                terms.append(trimmed)
            }
        }

        // Keep highlighting aligned with sentence lookup terms (and avoid component-term highlighting).
        let lookupAligned = sentenceLookupTerms(primaryTerms: [surface, kana].compactMap { $0 }, entryDetails: entryDetails)
        for term in lookupAligned { add(term) }
        // Lemma candidates can include component lemmas for compounds; filter those out.
        let partTerms: Set<String> = {
            var s: Set<String> = []
            for part in tokenParts {
                let surface = part.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if surface.isEmpty == false { s.insert(surface) }
                if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false { s.insert(kana) }
            }
            return s
        }()
        for lemma in lemmaCandidates {
            let trimmed = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            guard partTerms.contains(trimmed) == false else { continue }
            add(trimmed)
        }

        guard terms.isEmpty == false else { return AttributedString(sentence) }

        let ns = s as NSString
        let mutable = NSMutableAttributedString(string: s)
        let baseColor = UIColor.secondaryLabel
        let highlightColor = UIColor.systemOrange

        // Dim the whole sentence so the highlight stands out.
        mutable.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: ns.length))

        for term in terms {
            let needle = term as NSString
            guard needle.length > 0, needle.length <= ns.length else { continue }

            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: term, options: [], range: search)
                if found.location == NSNotFound || found.length == 0 { break }
                mutable.addAttribute(.foregroundColor, value: highlightColor, range: found)

                let nextLoc = NSMaxRange(found)
                if nextLoc >= ns.length { break }
                search = NSRange(location: nextLoc, length: ns.length - nextLoc)
            }
        }

        return AttributedString(mutable)
    }

    func loadEntryDetails(for entries: [DictionaryEntry]) async -> [DictionaryEntryDetail] {
        let entryIDs = orderedEntryIDs(from: entries)
        guard entryIDs.isEmpty == false else { return [] }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await DictionarySQLiteStore.shared.fetchEntryDetails(for: entryIDs)
            }.value
        } catch {
            return []
        }
    }

    func orderedEntryIDs(from entries: [DictionaryEntry]) -> [Int64] {
        var seen: Set<Int64> = []
        var ordered: [Int64] = []
        ordered.reserveCapacity(entries.count)
        for entry in entries {
            let entryID = entry.entryID
            if seen.insert(entryID).inserted {
                ordered.append(entryID)
            }
        }
        return ordered
    }
}
