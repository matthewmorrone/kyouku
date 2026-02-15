import SwiftUI
import NaturalLanguage

extension WordDefinitionsView {
    // MARK: Example sentence sorting
    func exampleSentenceComplexityScore(_ sentence: ExampleSentence) -> Int {
        // Heuristic: simpler sentences tend to be shorter with fewer kanji and less punctuation.
        var kanjiCount = 0
        var punctuationCount = 0
        var digitCount = 0

        for scalar in sentence.jpText.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: // CJK
                kanjiCount += 1
            case 0x0030...0x0039: // digits
                digitCount += 1
            case 0x3001, 0x3002, 0xFF01, 0xFF1F, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B:
                punctuationCount += 1
            default:
                if CharacterSet.punctuationCharacters.contains(scalar) {
                    punctuationCount += 1
                }
            }
        }

        let length = sentence.jpText.count

        // Weighting: kanji and punctuation add more "complexity" than raw length.
        return (length * 2) + (kanjiCount * 6) + (punctuationCount * 4) + (digitCount * 2)
    }

    func exampleSentenceRow(_ sentence: ExampleSentence) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if showExampleSentenceFurigana,
                   let guide = exampleSentenceReadingGuides[sentence.id],
                   guide.isEmpty == false {
                    Text(guide)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                interactiveSentenceLine(
                    sentence.jpText,
                    mode: .japanese,
                    highlightTerms: japaneseHighlightTermsForSentences(),
                    contextSentenceForOpen: sentence.jpText,
                    sentenceIDForPopoverAnchoring: sentence.id
                )
                interactiveSentenceLine(
                    sentence.enText,
                    mode: .english,
                    highlightTerms: [],
                    contextSentenceForOpen: sentence.jpText,
                    sentenceIDForPopoverAnchoring: sentence.id
                )
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                SpeechManager.shared.speak(text: sentence.jpText, language: "ja-JP")
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Speak sentence")
            .disabled(sentence.jpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 4)
        .task(id: "sentence-guide:\(sentence.id):\(showExampleSentenceFurigana)") {
            guard showExampleSentenceFurigana else { return }
            await ensureExampleSentenceReadingGuide(sentence)
        }
    }

    @MainActor
    func ensureExampleSentenceReadingGuide(_ sentence: ExampleSentence) async {
        guard showExampleSentenceFurigana else { return }
        if exampleSentenceReadingGuides[sentence.id] != nil { return }

        let guide = await buildExampleSentenceReadingGuide(from: sentence.jpText)
        guard showExampleSentenceFurigana else { return }
        exampleSentenceReadingGuides[sentence.id] = guide
    }

    func buildExampleSentenceReadingGuide(from sentence: String) async -> String {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return sentence }

        do {
            let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                text: sentence,
                context: "dictionary-example"
            )
            let semantic = stage2.semanticSpans.sorted { lhs, rhs in
                lhs.range.location < rhs.range.location
            }
            guard semantic.isEmpty == false else { return sentence }

            let ns = sentence as NSString
            var parts: [String] = []
            parts.reserveCapacity(semantic.count + 2)

            var cursor = 0
            for span in semantic {
                let range = span.range
                guard range.location != NSNotFound, range.length > 0 else { return sentence }
                guard range.location >= cursor else { return sentence }
                guard NSMaxRange(range) <= ns.length else { return sentence }

                if range.location > cursor {
                    let gap = NSRange(location: cursor, length: range.location - cursor)
                    parts.append(ns.substring(with: gap))
                }

                let surfaceText = ns.substring(with: range)
                let reading = (span.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if containsKanji(surfaceText), reading.isEmpty == false {
                    parts.append(reading)
                } else {
                    parts.append(surfaceText)
                }
                cursor = NSMaxRange(range)
            }

            if cursor < ns.length {
                parts.append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
            }

            let guide = parts.joined()
            return guide.isEmpty ? sentence : guide
        } catch {
            return sentence
        }
    }

    @ViewBuilder
    func interactiveSentenceLine(
        _ text: String,
        mode: DictionarySearchMode,
        highlightTerms: [String],
        contextSentenceForOpen: String?,
        sentenceIDForPopoverAnchoring: String?
    ) -> some View {
        if #available(iOS 16.0, *) {
            let segments = sentenceSegments(for: text, mode: mode)
            let englishRanges: [NSRange] = (mode == .english) ? englishHighlightRanges(in: text) : []
            InlineWrapLayout(spacing: 0, lineSpacing: 6) {
                ForEach(segments) { seg in
                    if seg.isToken {
                        let popoverTokenID: String = {
                            let modeKey: String = (mode == .english) ? "en" : "jp"
                            let sentenceKey = sentenceIDForPopoverAnchoring ?? "unknown"
                            return "tok|\(sentenceKey)|\(modeKey)|\(seg.range.location)|\(seg.range.length)"
                        }()

                        Button {
                            presentTokenPopover(id: popoverTokenID, text: seg.text, mode: mode, contextSentence: contextSentenceForOpen)
                        } label: {
                            Text(seg.text)
                                .foregroundStyle(tokenForeground(for: seg, mode: mode, highlightTerms: highlightTerms, englishHighlightRanges: englishRanges))
                        }
                        .buttonStyle(.plain)
                        .popover(
                            item: Binding<ActiveToken?>(
                                get: {
                                    guard let t = activeToken, t.id == popoverTokenID else { return nil }
                                    return t
                                },
                                set: { newValue in
                                    // Only clear if this token is the active one.
                                    if newValue == nil, activeToken?.id == popoverTokenID {
                                        activeToken = nil
                                    } else {
                                        activeToken = newValue
                                    }
                                }
                            )
                        ) { token in
                            tokenPopoverView(token)
                                .presentationCompactAdaptation(.popover)
                        }
                    } else {
                        Text(seg.text)
                            .foregroundStyle(tokenForeground(for: seg, mode: mode, highlightTerms: highlightTerms, englishHighlightRanges: englishRanges))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if mode == .japanese {
                Text(highlightedJapaneseSentence(text))
            } else {
                Text(highlightedEnglishSentence(text))
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct SentenceSegment: Identifiable, Hashable {
        let id: String
        let text: String
        let isToken: Bool
        let range: NSRange
    }

    func sentenceSegments(for sentence: String, mode: DictionarySearchMode) -> [SentenceSegment] {
        let s = sentence
        let ns = s as NSString
        guard ns.length > 0 else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        switch mode {
        case .japanese:
            tokenizer.setLanguage(.japanese)
        case .english:
            tokenizer.setLanguage(.english)
        }

        var tokenRanges: [NSRange] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let r = NSRange(range, in: s)
            if r.location != NSNotFound, r.length > 0 {
                tokenRanges.append(r)
            }
            return true
        }
        tokenRanges.sort { $0.location < $1.location }

        if tokenRanges.isEmpty {
            return [SentenceSegment(id: "seg:0:\(ns.length)", text: s, isToken: false, range: NSRange(location: 0, length: ns.length))]
        }

        var out: [SentenceSegment] = []
        out.reserveCapacity(tokenRanges.count * 2)

        var cursor = 0
        for r in tokenRanges {
            if r.location > cursor {
                let gap = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                if gap.isEmpty == false {
                    out.append(SentenceSegment(id: "seg:\(cursor):\(r.location - cursor)", text: gap, isToken: false, range: NSRange(location: cursor, length: r.location - cursor)))
                }
            }

            let tokenText = ns.substring(with: r)
            if isEligibleTapToken(tokenText) {
                out.append(SentenceSegment(id: "seg:\(r.location):\(r.length)", text: tokenText, isToken: true, range: r))
            } else {
                out.append(SentenceSegment(id: "seg:\(r.location):\(r.length)", text: tokenText, isToken: false, range: r))
            }

            cursor = NSMaxRange(r)
        }

        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if tail.isEmpty == false {
                out.append(SentenceSegment(id: "seg:\(cursor):\(ns.length - cursor)", text: tail, isToken: false, range: NSRange(location: cursor, length: ns.length - cursor)))
            }
        }

        return out
    }

    func isEligibleTapToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        // Filter out pure punctuation.
        let scalars = trimmed.unicodeScalars
        guard scalars.isEmpty == false else { return false }
        let punct = CharacterSet.punctuationCharacters
        let punctCount = scalars.filter { punct.contains($0) }.count
        if punctCount == scalars.count { return false }
        return true
    }

    func tokenForeground(
        for segment: SentenceSegment,
        mode: DictionarySearchMode,
        highlightTerms: [String],
        englishHighlightRanges: [NSRange]
    ) -> Color {
        let base: Color = (mode == .english) ? .secondary : Color(uiColor: .secondaryLabel)

        if mode == .english {
            guard englishHighlightRanges.isEmpty == false else { return base }
            if englishHighlightRanges.contains(where: { NSIntersectionRange($0, segment.range).length > 0 }) {
                return Color(uiColor: .systemOrange)
            }
            return base
        }

        guard highlightTerms.isEmpty == false else { return base }
        if highlightTerms.contains(where: { segment.text.contains($0) }) {
            return Color(uiColor: .systemOrange)
        }
        return base
    }

    func presentTokenPopover(id: String, text: String, mode: DictionarySearchMode, contextSentence: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        activeTokenLookupResult = nil
        isLoadingActiveTokenLookup = true
        let token = ActiveToken(id: id, text: trimmed, mode: mode, contextSentence: contextSentence)
        activeToken = token

        Task {
            let id = token.id
            defer {
                if activeToken?.id == id {
                    isLoadingActiveTokenLookup = false
                }
            }

            let keys = DictionaryKeyPolicy.keys(forDisplayKey: trimmed)
            guard keys.lookupKey.isEmpty == false else {
                if activeToken?.id == id {
                    activeTokenLookupResult = nil
                }
                return
            }

            let rows: [DictionaryEntry] = (try? await Task.detached(priority: .userInitiated) {
                try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 10, mode: mode)
            }.value) ?? []

            if activeToken?.id == id {
                activeTokenLookupResult = rows.first
            }
        }
    }

    func tokenPopoverView(_ token: ActiveToken) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(token.text)
                .font(.headline)
                .lineLimit(2)

            if isLoadingActiveTokenLookup {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking up…")
                        .foregroundStyle(.secondary)
                }
            } else if let entry = activeTokenLookupResult {
                let head = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (entry.kana ?? token.text) : entry.kanji
                VStack(alignment: .leading, spacing: 6) {
                    Text(head)
                        .font(.subheadline.weight(.semibold))

                    if let kana = entry.kana,
                       kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                       kana != head {
                        Text(kana)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView(.vertical) {
                        Text(firstGloss(for: entry.gloss))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 140)

                    Button {
                        activeToken = nil
                        DispatchQueue.main.async {
                            navigationTarget = NavigationTarget(surface: head, kana: entry.kana, contextSentence: token.contextSentence)
                        }
                    } label: {
                        Label("Open entry", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No dictionary results.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    func highlightedEnglishSentence(_ sentence: String) -> AttributedString {
        let s = sentence
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return AttributedString(sentence) }

        let ranges = englishHighlightRanges(in: s)
        guard ranges.isEmpty == false else { return AttributedString(sentence) }

        let ns = s as NSString
        let mutable = NSMutableAttributedString(string: s)
        let baseColor = UIColor.secondaryLabel
        let highlightColor = UIColor.systemOrange
        mutable.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: ns.length))

        for r in ranges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            mutable.addAttribute(.foregroundColor, value: highlightColor, range: r)
        }

        return AttributedString(mutable)
    }

    func inferTokenPartsIfNeeded() async {
        guard tokenParts.count <= 1 else {
            inferredTokenParts = []
            return
        }
        guard inferredTokenParts.isEmpty else { return }

        // Prefer the user-selected surface for component splitting.
        // Using the dictionary's primary headword can swap kana selections into kanji,
        // which makes the Components display feel wrong (e.g. いつだって → 何時だって).
        let headword: String = {
            let selected = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            if selected.isEmpty == false, containsJapaneseScript(selected) {
                return selected
            }
            if let first = entryDetails.first {
                let fromDict = primaryHeadword(for: first).trimmingCharacters(in: .whitespacesAndNewlines)
                if fromDict.isEmpty == false { return fromDict }
            }
            return titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard headword.isEmpty == false else { return }
        guard containsKanji(headword) || containsJapaneseScript(headword) else { return }

        func composedCharacterRanges(for text: String) -> [NSRange] {
            let ns = text as NSString
            guard ns.length > 0 else { return [] }
            var ranges: [NSRange] = []
            ranges.reserveCapacity(min(ns.length, 16))
            var i = 0
            while i < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: i)
                if r.length <= 0 { break }
                ranges.append(r)
                i = NSMaxRange(r)
            }
            return ranges
        }

        func lookupReading(surface: String) async -> String? {
            let keys = DictionaryKeyPolicy.keys(forDisplayKey: surface)
            guard keys.lookupKey.isEmpty == false else { return nil }
            let rows: [DictionaryEntry] = (try? await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 1, mode: .japanese)) ?? []
            return rows.first?.kana
        }

        func setFromSpans(_ spans: [TextSpan], headword: String) async {
            // Ensure spans fully cover the string contiguously.
            let ns = headword as NSString
            let sorted = spans.sorted { $0.range.location < $1.range.location }
            guard sorted.first?.range.location == 0 else { return }

            var cursor = 0
            for sp in sorted {
                if sp.range.location != cursor { return }
                cursor = NSMaxRange(sp.range)
            }
            guard cursor == ns.length else { return }

            var out: [TokenPart] = []
            out.reserveCapacity(min(sorted.count, 8))

            for (idx, sp) in sorted.enumerated() {
                if idx >= 8 { break }
                let surface = sp.surface.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }
                let reading = await lookupReading(surface: surface)
                out.append(TokenPart(id: "infer:\(sp.range.location):\(sp.range.length)", surface: surface, kana: reading))
            }

            if out.count > 1 {
                inferredTokenParts = out
            }
        }

        do {
            let spans = try await SegmentationService.shared.segment(text: headword)
            if spans.count > 1 {
                await setFromSpans(spans, headword: headword)
                return
            }

            // Fallback: try a 2-part split that yields dictionary hits on both sides.
            // This helps when the lexicon contains the full compound as one token.
            let charRanges = composedCharacterRanges(for: headword)
            guard charRanges.count >= 2, charRanges.count <= 10 else { return }
            let ns = headword as NSString

            var bestSplit: (idx: Int, score: Int, left: String, right: String, leftReading: String?, rightReading: String?)? = nil
            for splitIdx in 1..<(charRanges.count) {
                let leftRange = NSRange(location: 0, length: charRanges[splitIdx].location)
                let rightRange = NSRange(location: charRanges[splitIdx].location, length: ns.length - charRanges[splitIdx].location)
                guard leftRange.length > 0, rightRange.length > 0 else { continue }

                let left = ns.substring(with: leftRange).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let right = ns.substring(with: rightRange).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard left.isEmpty == false, right.isEmpty == false else { continue }

                let leftReading = await lookupReading(surface: left)
                let rightReading = await lookupReading(surface: right)
                guard leftReading != nil || rightReading != nil else { continue }

                // Score: prefer both sides having hits, then more balanced splits.
                let both = (leftReading != nil && rightReading != nil) ? 10_000 : 0
                let balance = min(left.count, right.count) * 100
                let score = both + balance
                if let best = bestSplit {
                    if score > best.score {
                        bestSplit = (splitIdx, score, left, right, leftReading, rightReading)
                    }
                } else {
                    bestSplit = (splitIdx, score, left, right, leftReading, rightReading)
                }
            }

            if let bestSplit {
                inferredTokenParts = [
                    TokenPart(id: "infer:split:left", surface: bestSplit.left, kana: bestSplit.leftReading),
                    TokenPart(id: "infer:split:right", surface: bestSplit.right, kana: bestSplit.rightReading)
                ]
            }
        } catch {
            // best-effort only
        }
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

    func partOfSpeechSummaryLine() -> String? {
        // Prefer JMdict POS tags; fall back to MeCab POS if we have nothing else.
        let posTags: [String] = {
            var seen: Set<String> = []
            var out: [String] = []
            for detail in entryDetails {
                for sense in detail.senses {
                    for tag in sense.partsOfSpeech {
                        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { continue }
                        let expanded = expandPartOfSpeechTag(trimmed)
                        let key = expanded.lowercased()
                        if seen.insert(key).inserted {
                            out.append(expanded)
                        }
                        if out.count >= 8 { break }
                    }
                    if out.count >= 8 { break }
                }
                if out.count >= 8 { break }
            }
            return out
        }()

        if posTags.isEmpty == false {
            return "\(posTags.joined(separator: " · "))"
        }

        let mecab = (tokenPartOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if mecab.isEmpty == false {
            return "\(mecab)"
        }
        return nil
    }

    func expandPartOfSpeechTag(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "n": return "noun"
        case "pn": return "pronoun"
        case "adj-i": return "i-adjective"
        case "adj-na": return "na-adjective"
        case "adj-no": return "no-adjective"
        case "adj-pn": return "pre-noun adjectival"
        case "adv": return "adverb"
        case "prt": return "particle"
        case "conj": return "conjunction"
        case "int": return "interjection"
        case "num": return "numeric"
        case "aux": return "auxiliary"
        case "exp": return "expression"
        case "pref": return "prefix"
        case "suf": return "suffix"
        case "vs": return "suru verb"
        case "vk": return "kuru verb"
        case "vz": return "zuru verb"
        case "v1": return "ichidan verb"
        default:
            if t.hasPrefix("v5") {
                return "godan verb"
            }
            return tag
        }
    }
}
