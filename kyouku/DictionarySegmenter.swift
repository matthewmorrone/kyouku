import Foundation

struct Segment: Hashable {
    let range: Range<String.Index>
    let surface: String
    let isDictionaryMatch: Bool
}

enum DictionarySegmenter {
    static func segment(text: String, trie: Trie?) -> [Segment] {
        let s = text.precomposedStringWithCanonicalMapping
        guard let t = trie else { return [] }
        return segment(text: s, trie: t)
    }

    static func segment(text: String, trie: Trie) -> [Segment] {
        let s = text.precomposedStringWithCanonicalMapping
        var out: [Segment] = []
        var i = s.startIndex
        while i < s.endIndex {
            if let end = trie.longestMatchEnd(in: s, from: i) {
                let r = i..<end
                out.append(Segment(range: r, surface: String(s[r]), isDictionaryMatch: true))
                i = end
                continue
            }
            // No dictionary match at i: advance by one character to avoid legacy fallbacks
            let next = s.index(after: i)
            let r = i..<next
            out.append(Segment(range: r, surface: String(s[r]), isDictionaryMatch: false))
            i = next
        }
        return postProcessJapaneseSegments(s, out)
    }

    // MARK: - Post-processing rules for Japanese morphology
    private static func postProcessJapaneseSegments(_ s: String, _ segments: [Segment]) -> [Segment] {
        // Iteratively apply merge rules until stable
        var segs = segments
        var changed = true
        var passes = 0
        while changed && passes < 8 {
            changed = false
            passes += 1
            var i = 0
            var newSegs: [Segment] = []
            while i < segs.count {
                if i + 1 >= segs.count {
                    newSegs.append(segs[i]); break
                }
                let a = segs[i]
                let b = segs[i + 1]

                func mergeAB(_ markDict: Bool = false) -> Segment {
                    let r = a.range.lowerBound ..< b.range.upperBound
                    let surf = a.surface + b.surface
                    let isDict = markDict ? true : (a.isDictionaryMatch || b.isDictionaryMatch)
                    return Segment(range: r, surface: surf, isDictionaryMatch: isDict)
                }

                // Rule 0: Merge contiguous non-dictionary Japanese runs
                if !a.isDictionaryMatch && !b.isDictionaryMatch && isJapaneseString(a.surface) && isJapaneseString(b.surface) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 1: Fix slang split: "ってか" + "ら" -> "ってから"
                if b.surface.hasPrefix("ら"), a.surface.hasPrefix("ってか") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 2: small tsu + (て|で) -> merge
                if a.surface.hasSuffix("っ") || a.surface.hasSuffix("ッ") {
                    if b.surface.hasPrefix("て") || b.surface.hasPrefix("で") || b.surface.hasPrefix("テ") || b.surface.hasPrefix("デ") {
                        newSegs.append(mergeAB())
                        i += 2
                        changed = true
                        continue
                    }
                }

                // Rule 2b: (たく) + (て) -> たくて
                if a.surface.hasSuffix("たく") && (b.surface.hasPrefix("て") || b.surface == "て") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 3: (て|で|って) + から -> merge
                if (a.surface.hasSuffix("て") || a.surface.hasSuffix("で") || a.surface.hasSuffix("って")) && b.surface.hasPrefix("から") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 4: Verb stem + (たい|たく|たくて) -> merge
                if startsWithAny(b.surface, ["たい", "たく", "たくて"]) && isJapaneseString(a.surface) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 5: Kanji/kana run + "って" or "ってから" -> merge to keep verb + connective together
                if isJapaneseString(a.surface) && (b.surface.hasPrefix("ってから") || b.surface.hasPrefix("って")) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 6: "で" + "あって" -> merge (e.g., であってから)
                if a.surface == "で" && b.surface.hasPrefix("あって") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Default: keep a
                newSegs.append(a)
                i += 1
            }
            segs = newSegs
        }
        return segs
    }

    // MARK: - Character helpers
    private static func isJapaneseLetter(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            // Hiragana
            if (0x3040...0x309F).contains(v) { return true }
            // Katakana
            if (0x30A0...0x30FF).contains(v) { return true }
            // Katakana Phonetic Extensions
            if (0x31F0...0x31FF).contains(v) { return true }
            // CJK Unified Ideographs (Kanji)
            if (0x4E00...0x9FFF).contains(v) { return true }
            // Prolonged sound mark
            if v == 0x30FC { return true }
        }
        return false
    }

    private static func isAsciiLetterOrDigit(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x30...0x39).contains(v) { return true } // 0-9
            if (0x41...0x5A).contains(v) { return true } // A-Z
            if (0x61...0x7A).contains(v) { return true } // a-z
        }
        return false
    }

    private static func isJapaneseString(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { isJapaneseLetter($0) }
    }

    private static func startsWithAny(_ s: String, _ prefixes: [String]) -> Bool {
        for p in prefixes { if s.hasPrefix(p) { return true } }
        return false
    }
}
