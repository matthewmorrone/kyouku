import Foundation

/// Stage 1.65: CounterCompoundBoundaryFixer
///
/// Split/rewire pass that fixes boundaries around Japanese person counters like 二人/三人
/// when upstream segmentation chooses a competing lexicon word ending in a digit.
///
/// Example:
/// - 中二 + 人 + ...  ->  中 + 二人 + ...
///
/// Constraints:
/// - Pure in-memory: consults only the already-loaded `LexiconTrie`.
/// - Never reorders, preserves exact UTF-16 coverage.
/// - Conservative: only moves a single-kanji digit across a boundary when doing so
///   makes both (base) and (digit+人) lexicon words.
enum CounterCompoundBoundaryFixer {
    private static let counterDigits: Set<String> = [
        // Kanji numerals
        "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
        // ASCII digits
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        // Full-width digits
        "０", "１", "２", "３", "４", "５", "６", "７", "８", "９"
    ]

    static func apply(text: NSString, spans: [TextSpan], trie: LexiconTrie) -> [TextSpan] {
        guard spans.isEmpty == false else { return spans }

        // Never split across explicit hard-stop surfaces.
        func isHardStopSurface(_ surface: String) -> Bool {
            surface.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
                || surface.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) })
        }

        func lastComposedCharRange(in range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            guard end > range.location else { return nil }
            let lastIndex = end - 1
            let r = text.rangeOfComposedCharacterSequence(at: lastIndex)
            guard r.length > 0 else { return nil }
            return r
        }

        func firstComposedCharRange(in range: NSRange) -> NSRange? {
            guard range.length > 0 else { return nil }
            let r = text.rangeOfComposedCharacterSequence(at: range.location)
            guard r.length > 0 else { return nil }
            return r
        }

        func composedCharRanges(in range: NSRange, maxChars: Int) -> [NSRange] {
            guard range.location != NSNotFound, range.length > 0, maxChars > 0 else { return [] }
            var out: [NSRange] = []
            out.reserveCapacity(maxChars)
            var cursor = range.location
            let end = NSMaxRange(range)
            while cursor < end, out.count < maxChars {
                let r = text.rangeOfComposedCharacterSequence(at: cursor)
                if r.length <= 0 { break }
                out.append(r)
                cursor = NSMaxRange(r)
            }
            return out
        }

        var out: [TextSpan] = []
        out.reserveCapacity(spans.count + 8)

        var i = 0
        while i < spans.count {
            if i == spans.count - 1 {
                // Also attempt in-span counter split on the last span.
                let span = spans[i]
                if span.range.location != NSNotFound, span.range.length >= 3, NSMaxRange(span.range) <= text.length {
                    let surface = text.substring(with: span.range)
                    if surface.isEmpty == false, isHardStopSurface(surface) == false {
                        // If the span begins with 中 and then has <digit>人, split it.
                        let chars = composedCharRanges(in: span.range, maxChars: 3)
                        if chars.count == 3 {
                            let c0 = text.substring(with: chars[0])
                            let c1 = text.substring(with: chars[1])
                            let c2 = text.substring(with: chars[2])
                            if c0 == "中", counterDigits.contains(c1), c2 == "人" {
                                let baseRange = chars[0]
                                let counterRange = NSRange(location: chars[1].location, length: chars[1].length + chars[2].length)
                                let remainderStart = NSMaxRange(counterRange)
                                let remainderLen = NSMaxRange(span.range) - remainderStart
                                let baseSurface = "中"
                                let counterSurface = c1 + c2
                                if trie.containsWord(baseSurface, requireKanji: false), trie.containsWord(counterSurface, requireKanji: false) {
                                    out.append(TextSpan(range: baseRange, surface: baseSurface, isLexiconMatch: true))
                                    out.append(TextSpan(range: counterRange, surface: counterSurface, isLexiconMatch: true))
                                    if remainderLen > 0 {
                                        let remainderRange = NSRange(location: remainderStart, length: remainderLen)
                                        let remainderSurface = text.substring(with: remainderRange)
                                        out.append(TextSpan(range: remainderRange, surface: remainderSurface, isLexiconMatch: false))
                                    }
                                    break
                                }
                            }
                        }
                    }
                }

                out.append(span)
                break
            }

            let left = spans[i]
            let right = spans[i + 1]

            // Must be contiguous and non-degenerate.
            if left.range.location == NSNotFound || right.range.location == NSNotFound || left.range.length <= 0 || right.range.length <= 0 {
                out.append(left)
                i += 1
                continue
            }
            if NSMaxRange(left.range) != right.range.location {
                out.append(left)
                i += 1
                continue
            }

            let leftSurface = text.substring(with: left.range)
            let rightSurface = text.substring(with: right.range)
            if leftSurface.isEmpty || rightSurface.isEmpty || isHardStopSurface(leftSurface) || isHardStopSurface(rightSurface) {
                out.append(left)
                i += 1
                continue
            }

            // In-span split: handle a single span like 中二人 or 中二人でいた.
            // Only apply when the span starts with 中 and the next two composed chars are <digit>人.
            if left.range.length >= 3 {
                let chars = composedCharRanges(in: left.range, maxChars: 3)
                if chars.count == 3 {
                    let c0 = text.substring(with: chars[0])
                    let c1 = text.substring(with: chars[1])
                    let c2 = text.substring(with: chars[2])
                    if c0 == "中", counterDigits.contains(c1), c2 == "人" {
                        let baseRange = chars[0]
                        let counterRange = NSRange(location: chars[1].location, length: chars[1].length + chars[2].length)
                        let remainderStart = NSMaxRange(counterRange)
                        let remainderLen = NSMaxRange(left.range) - remainderStart
                        let baseSurface = "中"
                        let counterSurface = c1 + c2

                        if trie.containsWord(baseSurface, requireKanji: false), trie.containsWord(counterSurface, requireKanji: false) {
                            out.append(TextSpan(range: baseRange, surface: baseSurface, isLexiconMatch: true))
                            out.append(TextSpan(range: counterRange, surface: counterSurface, isLexiconMatch: true))
                            if remainderLen > 0 {
                                let remainderRange = NSRange(location: remainderStart, length: remainderLen)
                                let remainderSurface = text.substring(with: remainderRange)
                                out.append(TextSpan(range: remainderRange, surface: remainderSurface, isLexiconMatch: false))
                            }
                            i += 1
                            continue
                        }
                    }
                }
            }

            // We only move a single UTF-16 unit digit.
            guard let leftLast = lastComposedCharRange(in: left.range), leftLast.length == 1 else {
                out.append(left)
                i += 1
                continue
            }

            let digit = text.substring(with: leftLast)
            guard counterDigits.contains(digit) else {
                out.append(left)
                i += 1
                continue
            }

            guard let rightFirst = firstComposedCharRange(in: right.range), rightFirst.length == 1 else {
                out.append(left)
                i += 1
                continue
            }

            let first = text.substring(with: rightFirst)
            guard first == "人" else {
                out.append(left)
                i += 1
                continue
            }

            // Candidate rewrite: [base][digit][人...]
            let baseRange = NSRange(location: left.range.location, length: leftLast.location - left.range.location)
            guard baseRange.length >= 1 else {
                out.append(left)
                i += 1
                continue
            }

            let baseSurface = text.substring(with: baseRange)
            let counterSurface = digit + "人"

            // Keep this fix extremely targeted: only rewrite 中二 + 人... -> 中 + 二人...
            guard baseSurface == "中" else {
                out.append(left)
                i += 1
                continue
            }

            guard trie.containsWord(baseSurface, requireKanji: false), trie.containsWord(counterSurface, requireKanji: false) else {
                out.append(left)
                i += 1
                continue
            }

            // Shift the boundary left by 1 UTF-16 unit (the digit).
            let newCounterRange = NSRange(location: leftLast.location, length: 2)
            let newRightRemainderStart = rightFirst.location + rightFirst.length
            let newRightRemainderLen = NSMaxRange(right.range) - newRightRemainderStart

            out.append(TextSpan(range: baseRange, surface: baseSurface, isLexiconMatch: true))
            out.append(TextSpan(range: newCounterRange, surface: counterSurface, isLexiconMatch: true))

            if newRightRemainderLen > 0 {
                let remainderRange = NSRange(location: newRightRemainderStart, length: newRightRemainderLen)
                let remainderSurface = text.substring(with: remainderRange)
                out.append(TextSpan(range: remainderRange, surface: remainderSurface, isLexiconMatch: false))
            }

            i += 2
        }

        return out
    }
}
