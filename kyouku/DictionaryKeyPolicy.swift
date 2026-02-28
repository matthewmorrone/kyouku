import Foundation

struct Token {
    let surface: String
    let lookupForm: String
    let rangeInSurface: NSRange
    let rangeInLookup: NSRange?
}

typealias NormalizedToken = Token

enum KyujitaiShinjitaiTable {
    nonisolated(unsafe) static let scalarMap: [UnicodeScalar: UnicodeScalar] = [
        "舊": "旧", "體": "体", "國": "国", "圓": "円", "圖": "図", "學": "学", "實": "実", "寫": "写",
        "會": "会", "發": "発", "變": "変", "壓": "圧", "醫": "医", "區": "区", "賣": "売", "單": "単",
        "收": "収", "臺": "台", "榮": "栄", "營": "営", "衞": "衛", "驛": "駅", "緣": "縁", "艷": "艶",
        "鹽": "塩", "奧": "奥", "應": "応", "橫": "横", "價": "価", "假": "仮", "氣": "気", "擧": "挙",
        "曉": "暁", "縣": "県", "廣": "広", "恆": "恒", "雜": "雑", "濕": "湿", "壽": "寿", "澁": "渋",
        "燒": "焼", "奬": "奨", "將": "将", "涉": "渉", "證": "証", "乘": "乗", "淨": "浄", "剩": "剰",
        "疊": "畳", "條": "条", "狀": "状", "讓": "譲", "釀": "醸", "觸": "触", "寢": "寝", "愼": "慎",
        "晉": "晋", "眞": "真", "盡": "尽", "粹": "粋", "醉": "酔", "穗": "穂", "瀨": "瀬", "聲": "声",
        "齊": "斉", "靜": "静", "攝": "摂", "竊": "窃", "專": "専", "戰": "戦", "淺": "浅", "潛": "潜",
        "纖": "繊", "禪": "禅", "雙": "双", "騷": "騒", "增": "増", "藏": "蔵", "臟": "臓", "續": "続",
        "墮": "堕", "對": "対", "帶": "帯", "滯": "滞", "擇": "択", "澤": "沢", "擔": "担", "膽": "胆",
        "團": "団", "彈": "弾", "晝": "昼", "蟲": "虫", "鑄": "鋳", "廳": "庁", "徵": "徴", "聽": "聴",
        "鎭": "鎮", "轉": "転", "傳": "伝", "燈": "灯", "當": "当", "黨": "党", "盜": "盗", "稻": "稲",
        "鬪": "闘", "德": "徳", "獨": "独", "讀": "読", "屆": "届", "貳": "弐", "腦": "脳", "霸": "覇",
        "廢": "廃", "拜": "拝", "賠": "陪", "麥": "麦", "髮": "髪", "拔": "抜", "蠻": "蛮", "祕": "秘",
        "彥": "彦", "濱": "浜", "甁": "瓶", "拂": "払", "佛": "仏", "竝": "並", "邊": "辺",
        "辨": "弁", "瓣": "弁", "辯": "弁", "舖": "舗", "寶": "宝", "萠": "萌", "褒": "褒", "豐": "豊",
        "沒": "没", "飜": "翻", "每": "毎", "萬": "万", "滿": "満", "默": "黙", "藥": "薬", "譯": "訳",
        "豫": "予", "餘": "余", "與": "与", "搖": "揺", "樣": "様", "謠": "謡", "來": "来", "賴": "頼",
        "亂": "乱", "覽": "覧", "龍": "竜", "壘": "塁", "淚": "涙", "勞": "労", "樓": "楼", "祿": "禄",
        "錄": "録", "灣": "湾", "嶌": "島", "嶋": "島", "嶽": "岳", "噓": "嘘"
    ]
}

nonisolated func normalizeForLookup(_ input: String) -> String {
    guard input.isEmpty == false else { return input }

    let nfc = input.precomposedStringWithCanonicalMapping
    let katakanaNormalized = normalizeHalfwidthKatakanaToFullwidth(nfc)

    var out = String.UnicodeScalarView()
    out.reserveCapacity(katakanaNormalized.unicodeScalars.count)

    for scalar in katakanaNormalized.unicodeScalars {
        if isVariationSelector(scalar) { continue }
        if isZeroWidthScalar(scalar) { continue }

        if scalar.value == 0xFF5E || scalar.value == 0x301C {
            out.append("〜")
            continue
        }

        if scalar.value == 0xFF65 {
            out.append("・")
            continue
        }

        if let mapped = KyujitaiShinjitaiTable.scalarMap[scalar] {
            out.append(mapped)
            continue
        }

        out.append(scalar)
    }

    let normalized = String(out)
    return expandIterationMarksForLookup(normalized)
}

nonisolated func expandIterationMarksForLookup(_ input: String) -> String {
    guard input.isEmpty == false else { return input }

    var out = String.UnicodeScalarView()
    out.reserveCapacity(input.unicodeScalars.count)

    var previous: UnicodeScalar? = nil

    for scalar in input.unicodeScalars {
        switch scalar.value {
        case 0x309D, 0x30FD: // ゝ / ヽ
            if let prev = previous,
               isRepeatableKana(prev) {
                out.append(prev)
                previous = prev
            } else {
                out.append(scalar)
                previous = scalar
            }

        case 0x309E, 0x30FE: // ゞ / ヾ
            if let prev = previous,
               isRepeatableKana(prev),
               let voiced = applyDakuten(to: prev) {
                out.append(voiced)
                previous = voiced
            } else if let prev = previous,
                      isRepeatableKana(prev) {
                out.append(prev)
                previous = prev
            } else {
                out.append(scalar)
                previous = scalar
            }

        default:
            out.append(scalar)
            previous = scalar
        }
    }

    return String(out)
}

nonisolated func logSuspiciousScalars(_ input: String) {
    for scalar in input.unicodeScalars {
        let value = scalar.value
        let isPrivateUse = (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value)

        if isPrivateUse {
            print("[LookupNormalization] private-use scalar U+\(String(format: "%04X", value)) in '\(input)'")
            continue
        }
        if isVariationSelector(scalar) {
            print("[LookupNormalization] variation selector U+\(String(format: "%04X", value)) in '\(input)'")
            continue
        }
        if isZeroWidthScalar(scalar) {
            print("[LookupNormalization] zero-width scalar U+\(String(format: "%04X", value)) in '\(input)'")
            continue
        }
    }
}

private nonisolated func normalizeHalfwidthKatakanaToFullwidth(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformFullwidthHalfwidth, true)
    return mutable as String
}

private nonisolated func isVariationSelector(_ scalar: UnicodeScalar) -> Bool {
    (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
}

private nonisolated func isZeroWidthScalar(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF
}

private nonisolated func isRepeatableKana(_ scalar: UnicodeScalar) -> Bool {
    (0x3041...0x3096).contains(scalar.value) || // hiragana letters
    (0x30A1...0x30FA).contains(scalar.value)    // katakana letters
}

private nonisolated func applyDakuten(to scalar: UnicodeScalar) -> UnicodeScalar? {
    let mapping: [UnicodeScalar: UnicodeScalar] = [
        "う": "ゔ", "か": "が", "き": "ぎ", "く": "ぐ", "け": "げ", "こ": "ご",
        "さ": "ざ", "し": "じ", "す": "ず", "せ": "ぜ", "そ": "ぞ",
        "た": "だ", "ち": "ぢ", "つ": "づ", "て": "で", "と": "ど",
        "は": "ば", "ひ": "び", "ふ": "ぶ", "へ": "べ", "ほ": "ぼ",
        "ゝ": "ゞ",
        "ウ": "ヴ", "カ": "ガ", "キ": "ギ", "ク": "グ", "ケ": "ゲ", "コ": "ゴ",
        "サ": "ザ", "シ": "ジ", "ス": "ズ", "セ": "ゼ", "ソ": "ゾ",
        "タ": "ダ", "チ": "ヂ", "ツ": "ヅ", "テ": "デ", "ト": "ド",
        "ハ": "バ", "ヒ": "ビ", "フ": "ブ", "ヘ": "ベ", "ホ": "ボ",
        "ヽ": "ヾ"
    ]
    return mapping[scalar]
}

/// Centralized policy for dictionary lookup key handling.
///
/// Invariants:
/// - `displayKey` is always the exact original selected/entered text.
/// - `lookupKey` is the *only* normalization applied for DB queries.
enum DictionaryKeyPolicy {
    struct Keys: Equatable {
        let displayKey: String
        let lookupKey: String
    }

    nonisolated static func keys(forDisplayKey displayKey: String) -> Keys {
        let token = normalizedToken(forSurface: displayKey)
        return Keys(displayKey: token.surface, lookupKey: token.lookupForm)
    }

    nonisolated static func normalizedToken(forSurface surface: String) -> NormalizedToken {
        token(forSurface: surface, rangeInSurface: NSRange(location: 0, length: (surface as NSString).length))
    }

    nonisolated static func token(forSurface surface: String, rangeInSurface: NSRange) -> Token {
        let lookup = lookupKey(for: surface)
        let lookupLength = (lookup as NSString).length
        return Token(
            surface: surface,
            lookupForm: lookup,
            rangeInSurface: rangeInSurface,
            rangeInLookup: NSRange(location: 0, length: lookupLength)
        )
    }

    /// The single, consistent normalization used for DB queries.
    ///
    /// Required by spec: keep original display text, normalize only lookup key.
    nonisolated static func lookupKey(for displayKey: String) -> String {
        let trimmed = displayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let normalized = normalizeForLookup(trimmed)
        return normalizeFullWidthASCII(normalized)
    }

    // MARK: - Full-width ASCII normalization

    /// Converts full-width ASCII (Ｉ Ａ １ etc.) to regular ASCII equivalents.
    ///
    /// Important: This is intentionally limited to the full-width ASCII block.
    nonisolated static func normalizeFullWidthASCII(_ text: String) -> String {
        guard text.isEmpty == false else { return text }

        var out: String = ""
        out.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            // Full-width ASCII range.
            if (0xFF01...0xFF5E).contains(scalar.value) {
                let mapped = UnicodeScalar(scalar.value - 0xFEE0)!
                out.unicodeScalars.append(mapped)
                continue
            }

            // Full-width space.
            if scalar.value == 0x3000 {
                out.unicodeScalars.append(" ")
                continue
            }

            out.unicodeScalars.append(scalar)
        }

        return out
    }
}
