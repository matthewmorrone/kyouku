import Foundation
import UIKit

enum ScriptFontStyler {
    enum ScriptClass {
        case kanji
        case kana
        case other
    }

    static func resolveKanjiFont(baseFont: UIFont) -> UIFont {
        let size = baseFont.pointSize

        // Prefer Japanese Mincho faces if available.
        let candidates = [
            "HiraMinProN-W3",
            "HiraMinProN-W6",
            "Hiragino Mincho ProN W3",
            "Hiragino Mincho ProN W6",
            "YuMincho-Regular",
            "YuMincho-Medium",
            "YuMincho-Demibold"
        ]

        for name in candidates {
            if let f = UIFont(name: name, size: size) {
                return f
            }
        }

        // Fallback: try a serif design variant of the base font.
        if let serif = baseFont.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: serif, size: size)
        }

        return baseFont
    }

    static func applyDistinctKanaKanjiFonts(
        to attributed: NSMutableAttributedString,
        kanjiFont: UIFont
    ) {
        let ns = attributed.string as NSString
        let n = ns.length
        guard n > 0 else { return }

        var i = 0
        var runStart = 0
        var runClass: ScriptClass? = nil

        func flush(end: Int) {
            guard let cls = runClass else { return }
            guard end > runStart else { return }
            if cls == .kanji {
                attributed.addAttribute(.font, value: kanjiFont, range: NSRange(location: runStart, length: end - runStart))
            }
        }

        while i < n {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let s = ns.substring(with: r)
            let cls = classify(s)

            if runClass == nil {
                runClass = cls
                runStart = r.location
            } else if cls != runClass {
                flush(end: r.location)
                runClass = cls
                runStart = r.location
            }

            i = NSMaxRange(r)
        }

        flush(end: n)
    }

    private static func classify(_ s: String) -> ScriptClass {
        var hasKana = false
        var hasKanji = false

        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF: // Katakana
                hasKana = true
            case 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF: // CJK Unified Ideographs
                hasKanji = true
            default:
                break
            }
        }

        if hasKanji { return .kanji }
        if hasKana { return .kana }
        return .other
    }
}
