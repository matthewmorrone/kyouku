import Foundation

enum PasteTextTransforms {
    /// One-click Paste UI transform:
    /// 1) Replace U+3000 (full-width space) with ASCII space.
    /// 2) Transliterate Latin words to Katakana (loanword-style) while preserving all non-Latin text.
    static func transform(_ text: String) -> String {
        let normalizedSpaces = text.replacingOccurrences(of: "\u{3000}", with: " ")
        return transliteratingLatinWordsToKatakana(in: normalizedSpaces)
    }

    private static func transliteratingLatinWordsToKatakana(in text: String) -> String {
        guard text.isEmpty == false else { return text }

        // Match ASCII Latin words only; leave punctuation, numbers, kana/kanji unchanged.
        // Examples:
        // - "test case" -> "テスト ケース" (spaces preserved)
        // - "test-case" -> "テスト-ケース" (hyphen preserved)
        let pattern = "[A-Za-z]+(?:'[A-Za-z]+)*"
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return text
        }

        let nsText = text as NSString
        var result = text

        // Replace from the end to keep ranges valid.
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).reversed() {
            guard match.range.location != NSNotFound, match.range.length > 0 else { continue }
            let word = nsText.substring(with: match.range)
            let katakana = latinWordToKatakana(word)
            result = (result as NSString).replacingCharacters(in: match.range, with: katakana)
        }

        return result
    }

    private static func latinWordToKatakana(_ word: String) -> String {
        guard word.isEmpty == false else { return word }

        // Use the same romaji-to-kana rules as dictionary lookup so
        // sequences like "keshin" map cleanly to ケシン instead of
        // partially converted mixes like "kえしn".
        let hiragana = romanToHiragana(word)
        guard hiragana.isEmpty == false else { return word }

        let mutable = NSMutableString(string: hiragana)
        let ok = CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, false)
        let katakana = ok ? (mutable as String) : hiragana
        return katakana.isEmpty ? word : katakana
    }

    // MARK: - Romaji → Hiragana helper (mirrors DictionarySQLiteStore)

    private static func romanToHiragana(_ input: String) -> String {
        var s = input.lowercased()
        s = s.replacingOccurrences(of: "ā", with: "aa")
            .replacingOccurrences(of: "ī", with: "ii")
            .replacingOccurrences(of: "ū", with: "uu")
            .replacingOccurrences(of: "ē", with: "ee")
            .replacingOccurrences(of: "ō", with: "ou")
        s = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        let tri: [String: String] = [
            "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
            "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
            "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
            "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
            "ja": "じゃ", "ju": "じゅ", "jo": "じょ",
            "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
            "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
            "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
            "cya": "ちゃ", "cyu": "ちゅ", "cyo": "ちょ",
            "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
            "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
            "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
            "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
            "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
            "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
            "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
            "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
            "she": "しぇ", "che": "ちぇ", "je": "じぇ"
        ]

        let di: [String: String] = [
            "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
            "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
            "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
            "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
            "ji": "じ",
            "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
            "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
            "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
            "ha": "は", "hi": "ひ", "hu": "ふ", "he": "へ", "ho": "ほ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
            "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
            "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
            "ya": "や", "yu": "ゆ", "yo": "よ",
            "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
            "wa": "わ", "wo": "を", "we": "うぇ", "wi": "うぃ"
        ]

        let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
        let consonants: Set<Character> = Set("bcdfghjklmnpqrstvwxyz")

        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "n" && i + 1 < chars.count && chars[i + 1] == "'" {
                out += "ん"; i += 2; continue
            }
            if i + 1 < chars.count {
                let c = chars[i]
                let n = chars[i + 1]
                if c == n && consonants.contains(c) && c != "n" {
                    out += "っ"; i += 1; continue
                }
            }
            if i + 2 < chars.count {
                let key = String(chars[i...i + 2])
                if let kana = tri[key] {
                    out += kana; i += 3; continue
                }
            }
            if chars[i] == "n" {
                if i + 1 >= chars.count { out += "ん"; i += 1; continue }
                let next = chars[i + 1]
                if next == "n" { out += "ん"; i += 2; continue }
                if !vowels.contains(next) && next != "y" { out += "ん"; i += 1; continue }
            }
            if i + 1 < chars.count {
                let key = String(chars[i...i + 1])
                if let kana = di[key] {
                    out += kana; i += 2; continue
                }
            }
            let key1 = String(chars[i])
            switch key1 {
            case "a": out += "あ"
            case "i": out += "い"
            case "u": out += "う"
            case "e": out += "え"
            case "o": out += "お"
            default:
                out += key1
            }
            i += 1
        }
        return out
    }
}
