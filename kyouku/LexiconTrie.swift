import Foundation

/// Minimal trie built from all JMdict surface forms. It supports fast,
/// bounded longest-prefix lookups across UTF-16 code units so segmentation can
/// scan text once without enumerating arbitrary substrings.
final class LexiconTrie: @unchecked Sendable {
    private final class Node {
        var children: [UInt16: Node] = [:]
        var isWord: Bool = false
    }

    private let root: Node
    private let maxWordLength: Int
    private let instrumentation = TrieInstrumentation()

    var maxLexiconWordLength: Int { maxWordLength }

//#if DEBUG
    var debugMaxWordLength: Int { maxWordLength }
//#endif

    /// Returns true if `word` exists as an exact lexicon surface form.
    ///
    /// This is a pure in-memory check (no SQLite).
    func containsWord(_ word: String, requireKanji: Bool = false) -> Bool {
        let ns = word as NSString
        guard ns.length > 0 else { return false }
        return containsWord(in: ns, from: 0, through: ns.length, requireKanji: requireKanji)
    }

    init(words: [String]) {
        let root = Node()
        var maxLen = 1
        for word in words {
            // Insert multiple normalization variants so lookups succeed across common paste forms.
            // - NFC/NFD: canonical composition differences (e.g. カ + ゙ instead of ガ)
            // - Halfwidth: compatibility variants (e.g. ｶﾞ instead of ガ)
            let nfc = word.precomposedStringWithCanonicalMapping
            let nfd = word.decomposedStringWithCanonicalMapping

            func insertVariant(_ s: String) {
                guard s.isEmpty == false else { return }
                let units = Array(s.utf16)
                maxLen = max(maxLen, units.count)
                Self.insert(units, into: root)
            }

            insertVariant(nfc)
            if nfd != nfc { insertVariant(nfd) }

            if let halfwidthNfc = nfc.applyingTransform(.fullwidthToHalfwidth, reverse: false), halfwidthNfc != nfc {
                insertVariant(halfwidthNfc)
            }
            if let halfwidthNfd = nfd.applyingTransform(.fullwidthToHalfwidth, reverse: false), halfwidthNfd != nfd {
                insertVariant(halfwidthNfd)
            }
        }
        self.root = root
        self.maxWordLength = maxLen
    }

    private static func insert(_ units: [UInt16], into root: Node) {
        guard units.isEmpty == false else { return }
        var node = root
        for unit in units {
            if let child = node.children[unit] {
                node = child
            } else {
                let next = Node()
                node.children[unit] = next
                node = next
            }
        }
        node.isWord = true
    }

    /// Returns the end index of the longest lexicon match that begins at `index`.
    func longestMatchEnd(in text: NSString, from index: Int, requireKanji: Bool = true) -> Int? {
        instrumentation.recordCursor()
        let length = text.length
        guard index < length else { return nil }
        instrumentation.recordTraversal()

        var node = root
        var cursor = index
        var steps = 0
        var lastMatchEnd: Int? = nil
        var hasKanji = false

        let loopStart = CFAbsoluteTimeGetCurrent()

        while cursor < length && steps < maxWordLength {
            let unit = text.character(at: cursor)
            instrumentation.recordCharAccess()
            instrumentation.recordLookup()
            guard let next = node.children[unit] else { break }
            if Self.isKanji(unit) {
                hasKanji = true
            }
            node = next
            cursor += 1
            steps += 1
            if node.isWord, (requireKanji == false || hasKanji) {
                lastMatchEnd = cursor
            }
        }

        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)

        return lastMatchEnd
    }

    /// Returns all end indices of lexicon matches that begin at `index`, ordered by increasing end.
    ///
    /// This is useful for tokenization that prefers decomposing concatenations into multiple words
    /// (e.g. Katakana runs like "ロンリーロンリーハート" → "ロンリー","ロンリー","ハート").
    func allMatchEnds(in text: NSString, from index: Int, requireKanji: Bool = true) -> [Int] {
        instrumentation.recordCursor()
        let length = text.length
        guard index < length else { return [] }
        instrumentation.recordTraversal()

        var node = root
        var cursor = index
        var steps = 0
        var hasKanji = false
        var ends: [Int] = []
        ends.reserveCapacity(2)

        let loopStart = CFAbsoluteTimeGetCurrent()

        while cursor < length && steps < maxWordLength {
            let unit = text.character(at: cursor)
            instrumentation.recordCharAccess()
            instrumentation.recordLookup()
            guard let next = node.children[unit] else { break }
            if Self.isKanji(unit) {
                hasKanji = true
            }
            node = next
            cursor += 1
            steps += 1
            if node.isWord, (requireKanji == false || hasKanji) {
                ends.append(cursor)
            }
        }

        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)
        return ends
    }

    struct MatchInfo {
        let lastWordEnd: Int?
        let furthestPrefixEnd: Int
        let hasKanji: Bool
    }

    /// Returns both the longest full-word match end (if any) and the furthest prefix end
    /// reached in the trie before traversal fails.
    func matchInfo(in text: NSString, from index: Int, requireKanji: Bool = true) -> MatchInfo? {
        instrumentation.recordCursor()
        let length = text.length
        guard index < length else { return nil }
        instrumentation.recordTraversal()

        var node = root
        var cursor = index
        var steps = 0
        var lastMatchEnd: Int? = nil
        var hasKanji = false

        let loopStart = CFAbsoluteTimeGetCurrent()

        while cursor < length && steps < maxWordLength {
            let unit = text.character(at: cursor)
            instrumentation.recordCharAccess()
            instrumentation.recordLookup()
            guard let next = node.children[unit] else { break }
            if Self.isKanji(unit) {
                hasKanji = true
            }
            node = next
            cursor += 1
            steps += 1
            if node.isWord, (requireKanji == false || hasKanji) {
                lastMatchEnd = cursor
            }
        }

        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)

        return MatchInfo(lastWordEnd: lastMatchEnd, furthestPrefixEnd: cursor, hasKanji: hasKanji)
    }

    /// Returns true when the substring `[index, endExclusive)` exists as a prefix inside the lexicon.
    func hasPrefix(in text: NSString, from index: Int, through endExclusive: Int) -> Bool {
        instrumentation.recordCursor()
        let length = text.length
        guard index < length else { return false }
        guard endExclusive <= length else { return false }
        instrumentation.recordTraversal()
        var node = root
        var cursor = index
        var steps = 0
        let loopStart = CFAbsoluteTimeGetCurrent()
        while cursor < endExclusive && steps < maxWordLength {
            let unit = text.character(at: cursor)
            instrumentation.recordCharAccess()
            instrumentation.recordLookup()
            guard let next = node.children[unit] else {
                instrumentation.recordSteps(steps)
                instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)
                return false
            }
            node = next
            cursor += 1
            steps += 1
        }
        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)
        return cursor == endExclusive
    }

    /// Returns true when the substring `[index, endExclusive)` exists as an exact word inside the lexicon.
    ///
    /// This is stricter than `hasPrefix` and does not depend on longest-match behavior.
    func containsWord(in text: NSString, from index: Int, through endExclusive: Int, requireKanji: Bool = true) -> Bool {
        instrumentation.recordCursor()
        let length = text.length
        guard index < length else { return false }
        guard endExclusive <= length else { return false }
        instrumentation.recordTraversal()

        var node = root
        var cursor = index
        var steps = 0
        var hasKanji = false

        let loopStart = CFAbsoluteTimeGetCurrent()

        while cursor < endExclusive && steps < maxWordLength {
            let unit = text.character(at: cursor)
            instrumentation.recordCharAccess()
            instrumentation.recordLookup()
            guard let next = node.children[unit] else {
                instrumentation.recordSteps(steps)
                instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)
                return false
            }
            if Self.isKanji(unit) {
                hasKanji = true
            }
            node = next
            cursor += 1
            steps += 1
        }

        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)

        guard cursor == endExclusive else { return false }
        guard node.isWord else { return false }
        return requireKanji == false || hasKanji
    }

    func beginProfiling() {
        instrumentation.begin()
    }

    func endProfiling(totalDuration: CFTimeInterval) {
        instrumentation.end(totalDuration: totalDuration)
    }

    private static func isKanji(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(unit))
    }
}
private final class TrieInstrumentation {
    private static let loggingEnabled = ProcessInfo.processInfo.environment["TRIE_TRACE"] == "1"
    private var isActive = false
    private var cursorCount = 0
    private var traversalCount = 0
    private var stepCount = 0
    private var lookupCount = 0
    private var charAccessCount = 0
    private var trieTime: CFTimeInterval = 0

    func begin() {
        isActive = true
        cursorCount = 0
        traversalCount = 0
        stepCount = 0
        lookupCount = 0
        charAccessCount = 0
        trieTime = 0
    }

    func end(totalDuration: CFTimeInterval) {
        guard isActive else { return }
        isActive = false
        if Self.loggingEnabled {
            CustomLogger.shared.info("Trie spans: cursors=\(self.cursorCount) traversals=\(self.traversalCount) steps=\(self.stepCount) childrenLookups=\(self.lookupCount) charAtCalls=\(self.charAccessCount) trieTime=\(self.trieTime * 1000)ms totalTime=\(totalDuration * 1000)ms")
        }
    }

    func recordCursor() {
        guard isActive else { return }
        cursorCount += 1
    }

    func recordTraversal() {
        guard isActive else { return }
        traversalCount += 1
    }

    func recordSteps(_ steps: Int) {
        guard isActive else { return }
        stepCount += steps
    }

    func recordLookup() {
        guard isActive else { return }
        lookupCount += 1
    }

    func recordCharAccess() {
        guard isActive else { return }
        charAccessCount += 1
    }

    func recordTrieTime(_ duration: CFTimeInterval) {
        guard isActive else { return }
        trieTime += duration
    }
}

