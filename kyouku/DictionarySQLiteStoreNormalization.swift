import Foundation
import SQLite3

extension DictionarySQLiteStore {

    func tableExists(_ name: String, in db: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func tableHasColumn(_ table: String, column: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) != SQLITE_OK {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                let name = String(cString: namePtr)
                if name == column {
                    return true
                }
            }
        }
        return false
    }

    func romanToHiragana(_ input: String) -> String {
        // Normalize
        var s = input.lowercased()
        // Replace macrons with typical IME equivalents
        s = s.replacingOccurrences(of: "ā", with: "aa")
            .replacingOccurrences(of: "ī", with: "ii")
            .replacingOccurrences(of: "ū", with: "uu")
            .replacingOccurrences(of: "ē", with: "ee")
            .replacingOccurrences(of: "ō", with: "ou")
        // Remove spaces and hyphens
        s = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        // Mappings inspired by iOS romaji IME
        let tri: [String: String] = [
            "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
            "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
            "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
            "shi": "し",
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
            // Core syllables
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
            // handle n'
            if chars[i] == "n" && i + 1 < chars.count && chars[i + 1] == "'" {
                out += "ん"; i += 2; continue
            }
            // sokuon for double consonants (except n)
            if i + 1 < chars.count {
                let c = chars[i]
                let n = chars[i + 1]
                if c == n && consonants.contains(c) && c != "n" {
                    out += "っ"; i += 1; continue
                }
            }
            // Try tri-graph
            if i + 2 < chars.count {
                let key = String(chars[i...i + 2])
                if let kana = tri[key] {
                    out += kana; i += 3; continue
                }
            }
            // Special handling for standalone 'n'
            if chars[i] == "n" {
                if i + 1 >= chars.count { out += "ん"; i += 1; continue }
                let next = chars[i + 1]
                if next == "n" { out += "ん"; i += 2; continue }
                if !vowels.contains(next) && next != "y" { out += "ん"; i += 1; continue }
                // else fallthrough to digraph handling (na, ni, nya, ...)
            }
            // Try di-graph
            if i + 1 < chars.count {
                let key = String(chars[i...i + 1])
                if let kana = di[key] {
                    out += kana; i += 2; continue
                }
            }
            // Single vowels
            let key1 = String(chars[i])
            switch key1 {
            case "a": out += "あ"
            case "i": out += "い"
            case "u": out += "う"
            case "e": out += "え"
            case "o": out += "お"
            default:
                // pass-through unknown character (e.g., punctuation)
                out += key1
            }
            i += 1
        }
        return out
    }

    func hiraganaToKatakana(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, false)
        return String(m)
    }

    func latinToKanaCandidates(for term: String) -> [String] {
        let hira = romanToHiragana(term)
        var result: Set<String> = []
        if !hira.isEmpty { result.insert(hira) }
        let kata = hiraganaToKatakana(hira)
        if !kata.isEmpty { result.insert(kata) }
        return Array(result)
    }

    func exactMatchCandidates(for term: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ value: String) {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        append(term)
        for variant in normalizedKanaVariants(for: term) {
            append(variant)
        }
        return ordered
    }

    func normalizedKanaVariants(for term: String) -> [String] {
        let hiragana = katakanaToHiragana(term)
        guard containsOnlyKana(hiragana) else { return [] }

        var bases = Set<String>()

        // Potential/passive (common learner pain points):
        // - Ichidan potential/passive: たべられる → たべる
        // - Godan potential ("e-row" + る): かける → かく, よめる → よむ, ぬぐえる → ぬぐう
        if hiragana.hasSuffix("られる"), hiragana.count > "られる".count {
            let base = String(hiragana.dropLast("られる".count)) + "る"
            bases.insert(base)
        }
        if hiragana.hasSuffix("る"), hiragana.count > 1 {
            let map: [Character: Character] = [
                "え": "う",
                "け": "く",
                "げ": "ぐ",
                "せ": "す",
                "ぜ": "ず",
                "て": "つ",
                "で": "づ",
                "ね": "ぬ",
                "へ": "ふ",
                "べ": "ぶ",
                "ぺ": "ぷ",
                "め": "む",
                "れ": "る"
            ]
            let chars = Array(hiragana)
            let penultimate = chars[chars.count - 2]
            if let replacement = map[penultimate] {
                let prefix = String(chars.dropLast(2))
                let base = prefix + String(replacement)
                if base.isEmpty == false {
                    bases.insert(base)
                }
            }
        }

        let adjectiveSuffixes: [(String, String)] = [
            ("くなかったです", "い"),
            ("くなかった", "い"),
            ("くないです", "い"),
            ("くない", "い"),
            ("かったです", "い"),
            ("かった", "い")
        ]
        for (suffix, replacement) in adjectiveSuffixes {
            if hiragana.hasSuffix(suffix), hiragana.count > suffix.count {
                let base = String(hiragana.dropLast(suffix.count)) + replacement
                bases.insert(base)
            }
        }

        let verbTeForms = ["している", "してます", "していた", "してる"]
        for suffix in verbTeForms {
            if hiragana.hasSuffix(suffix), hiragana.count > suffix.count {
                let base = String(hiragana.dropLast(suffix.count)) + "する"
                bases.insert(base)
            }
        }

        let baseSnapshot = bases
        for base in baseSnapshot where base.hasSuffix("する") {
            let noun = String(base.dropLast(2))
            if noun.isEmpty == false {
                bases.insert(noun)
            }
        }

        guard bases.isEmpty == false else { return [] }

        var variants: [String] = []
        var seen = Set<String>()
        for base in bases {
            if seen.insert(base).inserted { variants.append(base) }
            let kata = hiraganaToKatakana(base)
            if seen.insert(kata).inserted { variants.append(kata) }
        }
        return variants
    }

    func containsOnlyKana(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x30FC,          // Long vowel mark
                 0x3005:          // Iteration mark
                continue
            default:
                return false
            }
        }
        return true
    }

    func katakanaToHiragana(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        return String(m)
    }

    // normalizeFullWidthASCII removed: dictionary lookup keys are normalized upstream by DictionaryKeyPolicy.

    func sanitizeSurfaceToken(_ term: String) -> String {
        let allowedRanges: [ClosedRange<UInt32>] = [
            0x0030...0x0039, // ASCII digits
            0x0041...0x005A, // ASCII upper
            0x0061...0x007A, // ASCII lower
            0x3040...0x309F, // Hiragana
            0x30A0...0x30FF, // Katakana
            0x3400...0x4DBF, // CJK Ext A
            0x4E00...0x9FFF, // CJK Unified
            0xFF66...0xFF9F  // Half-width katakana
        ]
        var scalars: [UnicodeScalar] = []
        for scalar in term.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "ー" || scalar == "々" {
                scalars.append(scalar)
                continue
            }
            if allowedRanges.contains(where: { $0.contains(scalar.value) }) {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
