import Foundation

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

    /// Returns the lexicon-backed spans covering the provided text.
    func spans(in text: NSString) -> [NSRange] {
        let length = text.length
        guard length > 0 else { return [] }
        var ranges: [NSRange] = []
        var index = 0

        while index < length {
            var node = root
            var cursor = index
            var steps = 0
            var lastMatchEnd: Int? = nil

            while cursor < length && steps < maxWordLength {
                let unit = text.character(at: cursor)
                guard let next = node.children[unit] else { break }
                node = next
                cursor += 1
                steps += 1
                if node.isWord {
                    lastMatchEnd = cursor
                }
            }

            if let end = lastMatchEnd {
                ranges.append(NSRange(location: index, length: end - index))
                index = end
            } else {
                index += 1
            }
        }

        return ranges
    }
}
