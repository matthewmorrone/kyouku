import Foundation
import NaturalLanguage
import Combine

@MainActor
final class ClozeStudyViewModel: ObservableObject {
    struct Blank: Identifiable, Equatable {
        let id: UUID
        let correct: String
        let options: [String]
    }

    struct Segment: Identifiable, Equatable {
        enum Kind: Equatable {
            case text(String)
            case blank(Blank)
        }

        let id: UUID
        let kind: Kind
    }

    struct Question: Identifiable, Equatable {
        let id: UUID
        let sentenceIndex: Int
        let sentenceText: String
        let wordCount: Int
        let segments: [Segment]
        let blanks: [Blank]
    }

    enum Mode: String, CaseIterable, Identifiable {
        case sequential
        case random

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sequential: return "In order"
            case .random: return "Random"
            }
        }
    }

    let note: Note

    @Published var mode: Mode
    @Published private(set) var sentenceCount: Int = 0

    /// How many blanks (dropdowns) to include per sentence.
    @Published var blanksPerSentence: Int = 1

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentQuestion: Question? = nil

    @Published private(set) var selectedOptionByBlankID: [UUID: String] = [:]
    @Published private(set) var checkedBlankIDs: Set<UUID> = []

    @Published private(set) var correctCount: Int = 0
    @Published private(set) var totalCount: Int = 0

    private let sentences: [String]

    private var sequentialIndex: Int = 0
    private var remainingRandomIndices: [Int] = []

    private let numberOfChoices: Int

    private var pendingAutoAdvanceTask: Task<Void, Never>? = nil
    private let autoAdvanceDelayNanoseconds: UInt64 = 3_000_000_000

    init(
        note: Note,
        numberOfChoices: Int = 5,
        initialMode: Mode = .random,
        initialBlanksPerSentence: Int = 1,
        excludeDuplicateLines: Bool = true
    ) {
        self.note = note
        self.numberOfChoices = max(2, min(8, numberOfChoices))
        self.mode = initialMode
        self.blanksPerSentence = max(1, initialBlanksPerSentence)
        self.sentences = Self.sentences(from: note.text, excludeDuplicateLines: excludeDuplicateLines)
        self.sentenceCount = sentences.count
        resetRandomBag()
    }

    func start() {
        Task { await nextQuestion() }
    }

    func nextQuestion() async {
        cancelAutoAdvance()
        guard sentences.isEmpty == false else {
            currentQuestion = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        let sentenceIndex: Int
        switch mode {
        case .sequential:
            if sequentialIndex >= sentences.count { sequentialIndex = 0 }
            sentenceIndex = sequentialIndex
            sequentialIndex += 1
        case .random:
            if remainingRandomIndices.isEmpty { resetRandomBag() }
            sentenceIndex = remainingRandomIndices.removeLast()
        }

        let sentenceText = sentences[sentenceIndex]
        guard let question = await buildQuestion(sentenceIndex: sentenceIndex, sentenceText: sentenceText) else {
            // If we fail to build (e.g. sentence has no usable tokens), try another.
            // Bound retries so we don't loop forever on hostile input.
            for _ in 0..<4 {
                let fallbackIndex = Int.random(in: 0..<sentences.count)
                if let q = await buildQuestion(sentenceIndex: fallbackIndex, sentenceText: sentences[fallbackIndex]) {
                    setNewQuestion(q)
                    return
                }
            }
            currentQuestion = nil
            return
        }

        setNewQuestion(question)
    }

    func submitSelection(blankID: UUID, option: String) {
        guard let q = currentQuestion else { return }
        guard q.blanks.contains(where: { $0.id == blankID }) else { return }

        selectedOptionByBlankID[blankID] = option
        if checkedBlankIDs.contains(blankID) == false {
            checkedBlankIDs.insert(blankID)
            totalCount += 1
            if let blank = q.blanks.first(where: { $0.id == blankID }), option == blank.correct {
                correctCount += 1
            }
        }

        scheduleAutoAdvanceIfComplete(question: q)
    }

    func revealAnswer() {
        guard let q = currentQuestion else { return }
        for blank in q.blanks {
            if checkedBlankIDs.contains(blank.id) { continue }
            selectedOptionByBlankID[blank.id] = blank.correct
            checkedBlankIDs.insert(blank.id)
            totalCount += 1
            // Reveal counts as incorrect if they didn't answer.
        }

        scheduleAutoAdvanceIfComplete(question: q)
    }

    func rebuildCurrentQuestion() {
        guard let q = currentQuestion else { return }
        cancelAutoAdvance()
        Task {
            if let rebuilt = await buildQuestion(sentenceIndex: q.sentenceIndex, sentenceText: q.sentenceText) {
                setNewQuestion(rebuilt)
            }
        }
    }

    private func setNewQuestion(_ question: Question) {
        cancelAutoAdvance()
        currentQuestion = question
        selectedOptionByBlankID = [:]
        checkedBlankIDs = []
    }

    private func cancelAutoAdvance() {
        pendingAutoAdvanceTask?.cancel()
        pendingAutoAdvanceTask = nil
    }

    private func scheduleAutoAdvanceIfComplete(question: Question) {
        guard checkedBlankIDs.count >= question.blanks.count else { return }

        let questionID = question.id
        pendingAutoAdvanceTask?.cancel()
        pendingAutoAdvanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: autoAdvanceDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard self.currentQuestion?.id == questionID else { return }
            await self.nextQuestion()
        }
    }

    private func resetRandomBag() {
        remainingRandomIndices = Array(0..<sentences.count)
        remainingRandomIndices.shuffle()
    }

    private func buildQuestion(sentenceIndex: Int, sentenceText: String) async -> Question? {
        let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        // Candidate blanks (skip punctuation/whitespace).
        let candidates = pickTargetTokensViaTokenizer(sentenceText: trimmed)
        let wordCount = candidates.count
        guard wordCount >= 2 else { return nil }

        let maxBlanks = max(1, wordCount - 1)
        let desiredBlanks = min(max(1, blanksPerSentence), maxBlanks)

        // Choose blank token indices.
        var indices = Array(0..<candidates.count)
        indices.shuffle()
        let chosen = Array(indices.prefix(desiredBlanks)).sorted()
        guard chosen.isEmpty == false else { return nil }

        // Build blanks with options.
        var blanksByLocation: [Int: Blank] = [:]
        blanksByLocation.reserveCapacity(chosen.count)

        for idx in chosen {
            let correct = candidates[idx].surface
            let options = await buildOptions(correct: correct, contextSentence: trimmed)
            if options.count < 2 { return nil }
            blanksByLocation[candidates[idx].range.location] = Blank(id: UUID(), correct: correct, options: options)
        }

        // Build display segments: preserve non-token gaps and replace chosen tokens with blanks.
        let ns = trimmed as NSString
        let tokenRanges = allTokenRanges(sentenceText: trimmed)
        if tokenRanges.isEmpty { return nil }

        var segments: [Segment] = []
        segments.reserveCapacity(tokenRanges.count * 2)

        var cursor = 0
        for token in tokenRanges {
            if token.range.location > cursor {
                let gap = ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                if gap.isEmpty == false {
                    segments.append(Segment(id: UUID(), kind: .text(gap)))
                }
            }

            if let blank = blanksByLocation[token.range.location] {
                segments.append(Segment(id: UUID(), kind: .blank(blank)))
            } else {
                segments.append(Segment(id: UUID(), kind: .text(token.surface)))
            }

            cursor = NSMaxRange(token.range)
        }

        let len = ns.length
        if cursor < len {
            let tail = ns.substring(with: NSRange(location: cursor, length: len - cursor))
            if tail.isEmpty == false {
                segments.append(Segment(id: UUID(), kind: .text(tail)))
            }
        }

        let blanks = segments.compactMap { seg -> Blank? in
            if case let .blank(b) = seg.kind { return b }
            return nil
        }

        guard blanks.isEmpty == false else { return nil }

        return Question(
            id: UUID(),
            sentenceIndex: sentenceIndex,
            sentenceText: trimmed,
            wordCount: wordCount,
            segments: segments,
            blanks: blanks
        )
    }

    private func buildOptions(correct: String, contextSentence: String) async -> [String] {
        var choices: [String] = [correct]
        choices.reserveCapacity(numberOfChoices)

        if let neighbors = await EmbeddingNeighborsService.shared.neighbors(for: correct, topN: 30) {
            let filtered = neighbors
                .map { $0.word }
                .filter { $0 != correct }
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                .filter { isReasonableDistractor(candidate: $0, comparedTo: correct) }

            for w in filtered {
                if choices.count >= numberOfChoices { break }
                if choices.contains(w) == false {
                    choices.append(w)
                }
            }
        }

        if choices.count < numberOfChoices {
            let fallback = fallbackDistractors(from: contextSentence, excluding: Set(choices))
            for w in fallback {
                if choices.count >= numberOfChoices { break }
                choices.append(w)
            }
        }

        // If we still can't fill, pad with simple alternatives so UI remains functional.
        while choices.count < min(numberOfChoices, 3) {
            let token = "…"
            if choices.contains(token) == false { choices.append(token) }
            break
        }

        choices = Array(choices.prefix(numberOfChoices))
        choices.shuffle()
        // Guarantee correct exists.
        if choices.contains(correct) == false {
            if choices.isEmpty {
                choices = [correct]
            } else {
                choices[0] = correct
                choices.shuffle()
            }
        }

        return choices
    }

    private func isReasonableDistractor(candidate: String, comparedTo correct: String) -> Bool {
        // Quick heuristics: keep short-ish and roughly similar length in UTF-16.
        let a = (candidate as NSString).length
        let b = (correct as NSString).length
        guard a >= 1, b >= 1 else { return false }
        if a > 12 { return false }
        let ratio = Double(max(a, b)) / Double(min(a, b))
        return ratio <= 2.0
    }

    private func fallbackDistractors(from sentenceText: String, excluding: Set<String>) -> [String] {
        let tokens = pickTargetTokensViaTokenizer(sentenceText: sentenceText)
            .map { $0.surface }
            .filter { excluding.contains($0) == false }

        var unique: [String] = []
        unique.reserveCapacity(12)
        var seen: Set<String> = []
        for t in tokens.shuffled() {
            if seen.contains(t) { continue }
            seen.insert(t)
            unique.append(t)
            if unique.count >= 12 { break }
        }
        return unique
    }

    private struct TokenPick {
        let range: NSRange
        let surface: String
    }

    private func pickTargetTokensViaTokenizer(sentenceText: String) -> [TokenPick] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentenceText
        tokenizer.setLanguage(.japanese)

        var picks: [TokenPick] = []
        tokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            let nsRange = NSRange(range, in: sentenceText)
            if nsRange.length == 0 { return true }
            let surface = (sentenceText as NSString).substring(with: nsRange)

            // Heuristic: skip pure punctuation/whitespace, and prefer non-trivial tokens.
            let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return true }
            guard trimmed.count >= 1 else { return true }
            guard isMostlyPunctuation(trimmed) == false else { return true }

            picks.append(TokenPick(range: nsRange, surface: surface))
            return true
        }

        // Prefer Japanese-ish tokens if available.
        let japanese = picks.filter { containsJapaneseCharacters($0.surface) }
        if japanese.isEmpty == false {
            return japanese
        }
        return picks
    }

    private func allTokenRanges(sentenceText: String) -> [TokenPick] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentenceText
        tokenizer.setLanguage(.japanese)

        var tokens: [TokenPick] = []
        tokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            let nsRange = NSRange(range, in: sentenceText)
            if nsRange.length == 0 { return true }
            let surface = (sentenceText as NSString).substring(with: nsRange)
            tokens.append(TokenPick(range: nsRange, surface: surface))
            return true
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private func isMostlyPunctuation(_ s: String) -> Bool {
        let punct = CharacterSet.punctuationCharacters
        let scalars = s.unicodeScalars
        guard scalars.isEmpty == false else { return true }
        let punctCount = scalars.filter { punct.contains($0) }.count
        return punctCount == scalars.count
    }

    private func containsJapaneseCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF: // CJK Unified Ideographs
                return true
            default:
                return false
            }
        }
    }

    private static func sentences(from text: String, excludeDuplicateLines: Bool) -> [String] {
        let ns = text as NSString
        let ranges = SentenceRangeResolver.sentenceRanges(in: ns)
        if ranges.isEmpty { return [] }

        var out: [String] = []
        out.reserveCapacity(ranges.count)

        var seen: Set<String> = []
        if excludeDuplicateLines {
            seen.reserveCapacity(min(ranges.count, 64))
        }

        for r in ranges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            let s = ns.substring(with: r)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.isEmpty == false else { continue }

            if excludeDuplicateLines {
                if seen.contains(s) { continue }
                seen.insert(s)
            }

            out.append(s)
        }

        return out
    }
}
