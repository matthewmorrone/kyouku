import Foundation

struct Segment: Hashable {
    let range: Range<String.Index>
    let surface: String
    let isDictionaryMatch: Bool
}

enum DictionarySegmenter {
    private static let shortHiraganaStopwords: Set<String> = [
        "は","が","を","に","へ","と","で","や","の","も","ね","よ","な","ぞ","ぜ","さ","か","わ",
        "まで","から","より","だけ","しか","でも","とも","です","ます","する","して",
        "こと","もの","ところ","ため","つもり","はず","わけ","ふり","ぶり","まま","たち",
        "これ","それ","あれ","どれ","ここ","そこ","どこ","こそ","さえ","ずつ","って","っと","など"
    ]

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
            // Skip over whitespace entirely; do not emit segments for it
            let ch = s[i]
            if ch.isWhitespace {
                i = s.index(after: i)
                continue
            }
            if let matchEnd = trie.longestMatchEnd(in: s, from: i) {
                let extendedEnd = extendOkuriganaTailIfNeeded(in: s, start: i, currentEnd: matchEnd)
                let r = i..<extendedEnd
                out.append(Segment(range: r, surface: String(s[r]), isDictionaryMatch: true))
                i = extendedEnd
                continue
            }
            // No dictionary match at i: advance by one character to avoid legacy fallbacks
            let next = s.index(after: i)
            let r = i..<next
            out.append(Segment(range: r, surface: String(s[r]), isDictionaryMatch: false))
            i = next
        }
        return postProcessJapaneseSegments(s, out, trie: trie)
    }

    // MARK: - Post-processing rules for Japanese morphology
    private static func postProcessJapaneseSegments(_ s: String, _ segments: [Segment], trie: Trie) -> [Segment] {
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

                // Only merge segments that are directly adjacent in the original string
                let areContiguous = (a.range.upperBound == b.range.lowerBound)

                func mergeAB(_ markDict: Bool = false) -> Segment {
                    let r = a.range.lowerBound ..< b.range.upperBound
                    let surf = a.surface + b.surface
                    let isDict = markDict ? true : (a.isDictionaryMatch || b.isDictionaryMatch)
                    return Segment(range: r, surface: surf, isDictionaryMatch: isDict)
                }

                // Rule 0: Merge contiguous non-dictionary Japanese runs (only if adjacent)
                if areContiguous && !a.isDictionaryMatch && !b.isDictionaryMatch && isJapaneseString(a.surface) && isJapaneseString(b.surface) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 0b: Merge kanji runs with short hiragana suffixes (e.g., 泳 + いだ) even if the suffix pretends to be its own dictionary hit
                if areContiguous && containsKanji(a.surface) && isShortHiraganaSuffix(b.surface) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 1: Fix slang split: "ってか" + "ら" -> "ってから" (only if adjacent)
                if areContiguous && b.surface.hasPrefix("ら"), a.surface.hasPrefix("ってか") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 2: small tsu + (て|で) -> merge (only if adjacent)
                if areContiguous && (a.surface.hasSuffix("っ") || a.surface.hasSuffix("ッ")) {
                    if b.surface.hasPrefix("て") || b.surface.hasPrefix("で") || b.surface.hasPrefix("テ") || b.surface.hasPrefix("デ") {
                        newSegs.append(mergeAB())
                        i += 2
                        changed = true
                        continue
                    }
                }

                // Rule 2b: (たく) + (て) -> たくて (only if adjacent)
                if areContiguous && a.surface.hasSuffix("たく") && (b.surface.hasPrefix("て") || b.surface == "て") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 3: (て|で|って) + から -> merge (only if adjacent)
                if areContiguous && (a.surface.hasSuffix("て") || a.surface.hasSuffix("で") || a.surface.hasSuffix("って")) && b.surface.hasPrefix("から") {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 4: Verb stem + (たい|たく|たくて) -> merge (only if adjacent)
                if areContiguous && startsWithAny(b.surface, ["たい", "たく", "たくて"]) && isJapaneseString(a.surface) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 5: Kanji/kana run + "って" or "ってから" -> merge to keep verb + connective together (only if adjacent)
                if areContiguous && isJapaneseString(a.surface) && (b.surface.hasPrefix("ってから") || b.surface.hasPrefix("って")) {
                    newSegs.append(mergeAB())
                    i += 2
                    changed = true
                    continue
                }

                // Rule 6: "で" + "あって" -> merge (e.g., であってから) (only if adjacent)
                if areContiguous && a.surface == "で" && b.surface.hasPrefix("あって") {
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
        return splitTrailingCopulaSegments(s, segs, trie: trie)
    }

    private static func splitTrailingCopulaSegments(_ text: String, _ segments: [Segment], trie: Trie) -> [Segment] {
        var output: [Segment] = []
        output.reserveCapacity(segments.count)
        for seg in segments {
            if let split = splitCopula(from: seg, in: text, trie: trie) {
                output.append(contentsOf: split)
            } else {
                output.append(seg)
            }
        }
        return output
    }

    private static func splitCopula(from segment: Segment, in text: String, trie: Trie) -> [Segment]? {
        let surface = segment.surface
        guard surface.count >= 2 else { return nil }
        guard surface.hasSuffix("だ") else { return nil }
        let prefixSurface = String(surface.dropLast())
        guard prefixSurface.count >= 2 else { return nil }
        guard trie.contains(word: prefixSurface) else { return nil }

        // Only split if the prefix is a dictionary entry; this avoids breaking verb past-tense forms.
        let suffixStart = text.index(before: segment.range.upperBound)
        let prefixRange = segment.range.lowerBound..<suffixStart
        let suffixRange = suffixStart..<segment.range.upperBound
        guard !prefixRange.isEmpty else { return nil }

        let prefix = Segment(range: prefixRange, surface: String(text[prefixRange]), isDictionaryMatch: segment.isDictionaryMatch)
        let suffix = Segment(range: suffixRange, surface: String(text[suffixRange]), isDictionaryMatch: false)
        return [prefix, suffix]
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

    private static func containsKanji(_ s: String) -> Bool {
        for ch in s {
            for scalar in ch.unicodeScalars {
                if (0x4E00...0x9FFF).contains(scalar.value) { return true }
            }
        }
        return false
    }

    private static func isHiraganaOnly(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s {
            for scalar in ch.unicodeScalars {
                if !(0x3040...0x309F).contains(scalar.value) {
                    return false
                }
            }
        }
        return true
    }

    private static func isShortHiraganaSuffix(_ s: String) -> Bool {
        if s.count == 0 || s.count > 2 { return false }
        if shortHiraganaStopwords.contains(s) { return false }
        return isHiraganaOnly(s)
    }

    private static func extendOkuriganaTailIfNeeded(in text: String, start: String.Index, currentEnd: String.Index) -> String.Index {
        guard start < currentEnd else { return currentEnd }
        let baseSurface = String(text[start..<currentEnd])
        guard containsKanji(baseSurface) else { return currentEnd }

        var end = currentEnd
        var steps = 0
        let maxTail = 4
        while end < text.endIndex, steps < maxTail {
            let ch = text[end]
            if isOkuriganaCharacter(ch) {
                end = text.index(after: end)
                steps += 1
                continue
            }
            break
        }
        return end
    }

    private static func isOkuriganaCharacter(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) { return true }
            if v == 0x30FC { return true }
        }
        return false
    }
}
