import Foundation
import OSLog

/// Minimal trie built from all JMdict surface forms. It supports fast,
/// bounded longest-prefix lookups across UTF-16 code units so segmentation can
/// scan text once without enumerating arbitrary substrings.
final class LexiconTrie {
    private final class Node {
        var children: [UInt16: Node] = [:]
        var isWord: Bool = false
    }

    private let root: Node
    private let maxWordLength: Int
    private let instrumentation = TrieInstrumentation()

    init(words: [String]) {
        let root = Node()
        var maxLen = 1
        for word in words {
            let normalized = word.precomposedStringWithCanonicalMapping
            guard normalized.isEmpty == false else { continue }
            let units = Array(normalized.utf16)
            maxLen = max(maxLen, units.count)
            Self.insert(units, into: root)
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
    func longestMatchEnd(in text: NSString, from index: Int) -> Int? {
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
            if node.isWord, hasKanji {
                lastMatchEnd = cursor
            }
        }

        instrumentation.recordSteps(steps)
        instrumentation.recordTrieTime(CFAbsoluteTimeGetCurrent() - loopStart)

        return lastMatchEnd
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
    private var isActive = false
    private var cursorCount = 0
    private var traversalCount = 0
    private var stepCount = 0
    private var lookupCount = 0
    private var charAccessCount = 0
    private var trieTime: CFTimeInterval = 0

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "LexiconTrie")

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
        logger.info("Trie spans: cursors=\(self.cursorCount) traversals=\(self.traversalCount) steps=\(self.stepCount) childrenLookups=\(self.lookupCount) charAtCalls=\(self.charAccessCount) trieTime=\(self.trieTime * 1000)ms totalTime=\(totalDuration * 1000)ms")
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
