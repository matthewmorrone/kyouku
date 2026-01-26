import Foundation

/// Utility for splitting text into sentence ranges using UTF-16 `NSRange`.
///
/// Heuristic rules (fast, deterministic):
/// - Split on Japanese sentence terminators: 。！？
/// - Split on newlines.
/// - Trim leading/trailing whitespace/newlines from each sentence range.
/// - Never returns empty ranges.
enum SentenceRangeResolver {
    static func sentenceRanges(in text: NSString) -> [NSRange] {
        let n = text.length
        guard n > 0 else { return [] }

        func isTerminator(_ ch: unichar) -> Bool {
            switch ch {
            case 0x3002, // 。
                 0xFF01, // ！
                 0xFF1F, // ？
                 0x0021, // !
                 0x003F: // ?
                return true
            default:
                return false
            }
        }

        func isNewline(_ ch: unichar) -> Bool {
            ch == 0x000A || ch == 0x000D
        }

        func isWhitespace(_ ch: unichar) -> Bool {
            // Space, tabs, and full-width space.
            ch == 0x0020 || ch == 0x0009 || ch == 0x3000
        }

        var out: [NSRange] = []
        out.reserveCapacity(16)

        var start = 0
        var i = 0
        while i < n {
            let ch = text.character(at: i)
            if isNewline(ch) {
                // Sentence ends before newline.
                let raw = NSRange(location: start, length: max(0, i - start))
                appendTrimmed(raw, in: text, to: &out, isWhitespace: isWhitespace, isNewline: isNewline)
                start = i + 1
                i += 1
                continue
            }

            if isTerminator(ch) {
                // Include the terminator.
                let raw = NSRange(location: start, length: max(0, (i + 1) - start))
                appendTrimmed(raw, in: text, to: &out, isWhitespace: isWhitespace, isNewline: isNewline)
                start = i + 1
                i += 1
                continue
            }

            i += 1
        }

        if start < n {
            let raw = NSRange(location: start, length: n - start)
            appendTrimmed(raw, in: text, to: &out, isWhitespace: isWhitespace, isNewline: isNewline)
        }

        return out
    }

    private static func appendTrimmed(
        _ range: NSRange,
        in text: NSString,
        to out: inout [NSRange],
        isWhitespace: (unichar) -> Bool,
        isNewline: (unichar) -> Bool
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        let n = text.length
        guard range.location >= 0, NSMaxRange(range) <= n else { return }

        var left = range.location
        var rightExclusive = NSMaxRange(range)

        while left < rightExclusive {
            let ch = text.character(at: left)
            if isWhitespace(ch) || isNewline(ch) {
                left += 1
            } else {
                break
            }
        }

        while rightExclusive > left {
            let ch = text.character(at: rightExclusive - 1)
            if isWhitespace(ch) || isNewline(ch) {
                rightExclusive -= 1
            } else {
                break
            }
        }

        let finalLen = rightExclusive - left
        guard finalLen > 0 else { return }
        out.append(NSRange(location: left, length: finalLen))
    }
}
