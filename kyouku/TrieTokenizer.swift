import Foundation

public struct TrieToken: Hashable {
    public let text: String
    public let range: Range<String.Index>
    public let isWord: Bool
}

public final class Trie {
    public final class Node {
        var children: [Character: Node] = [:]
        var isWord: Bool = false
    }

    private let root = Node()
    private let maxWordLength: Int

    public init(words: [String]) {
        // First pass: compute maximum normalized word length
        var maxLen = 0
        for w in words {
            let normalized = Trie.normalize(w)
            maxLen = max(maxLen, normalized.count)
        }
        self.maxWordLength = maxLen

        // Second pass: insert words into the trie
        for w in words {
            let normalized = Trie.normalize(w)
            insert(normalized)
        }
    }

    private func insert(_ word: String) {
        var node = root
        for ch in word {
            if let next = node.children[ch] {
                node = next
            } else {
                let next = Node()
                node.children[ch] = next
                node = next
            }
        }
        node.isWord = true
    }

    public func tokenize(_ input: String,
                         emitSeparators: Bool = true,
                         treatWhitespaceAsSeparator: Bool = true,
                         emitWhitespaceSeparators: Bool = false) -> [TrieToken] {
        let s = Trie.normalize(input)
        var tokens: [TrieToken] = []
        var i = s.startIndex

        while i < s.endIndex {
            let ch = s[i]

            if treatWhitespaceAsSeparator, ch.isWhitespace {
                let j = s.index(after: i)
                if emitWhitespaceSeparators {
                    tokens.append(TrieToken(text: String(s[i..<j]), range: i..<j, isWord: false))
                }
                i = j
                continue
            }

            if emitSeparators, Trie.isSeparator(ch) {
                let j = s.index(after: i)
                tokens.append(TrieToken(text: String(s[i..<j]), range: i..<j, isWord: false))
                i = j
                continue
            }

            var node = root
            var j = i
            var lastMatchEnd: String.Index? = nil

            var steps = 0
            while j < s.endIndex && steps < maxWordLength {
                let c = s[j]
                guard let next = node.children[c] else { break }
                node = next
                let nextIndex = s.index(after: j)
                if node.isWord {
                    lastMatchEnd = nextIndex
                }
                j = nextIndex
                steps += 1
            }

            if let end = lastMatchEnd {
                tokens.append(TrieToken(text: String(s[i..<end]), range: i..<end, isWord: true))
                i = end
            } else {
                let end = s.index(after: i)
                tokens.append(TrieToken(text: String(s[i..<end]), range: i..<end, isWord: false))
                i = end
            }
        }

        return tokens
    }

    public func contains(word: String) -> Bool {
        let normalized = Trie.normalize(word)
        guard !normalized.isEmpty else { return false }
        var node = root
        for ch in normalized {
            guard let next = node.children[ch] else { return false }
            node = next
        }
        return node.isWord
    }

    /// Returns the end index of the longest dictionary match starting at `start` in `input`.
    /// IMPORTANT: `input` must already be normalized with `precomposedStringWithCanonicalMapping`.
    /// If no match, returns nil. The search is limited by the trie's maxWordLength.
    public func longestMatchEnd(in input: String, from start: String.Index) -> String.Index? {
        var node = root
        var j = start
        var lastMatchEnd: String.Index? = nil
        var steps = 0
        while j < input.endIndex && steps < maxWordLength {
            let c = input[j]
            guard let next = node.children[c] else { break }
            node = next
            let nextIndex = input.index(after: j)
            if node.isWord {
                lastMatchEnd = nextIndex
            }
            j = nextIndex
            steps += 1
        }
        return lastMatchEnd
    }

    private static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        let scalars = ch.unicodeScalars
        if scalars.count != 1 { return false }
        let v = scalars.first!.value

        switch v {
        case 0x3000:
            return true
        case 0x3001, 0x3002, 0x300C, 0x300D, 0x300E, 0x300F, 0x3010, 0x3011, 0xFF08, 0xFF09:
            return true
        case 0xFF0C, 0xFF0E, 0xFF1F, 0xFF01, 0xFF1A, 0xFF1B:
            return true
        case 0x002E, 0x002C, 0x003F, 0x0021, 0x003A, 0x003B, 0x0028, 0x0029, 0x005B, 0x005D, 0x007B, 0x007D:
            return true
        default:
            return false
        }
    }
}
