import Foundation

struct JapaneseVerbConjugation: Hashable, Sendable {
    let label: String
    let surface: String
}

struct JapaneseVerbConjugator {
    enum VerbClass: Hashable, Sendable {
        case ichidan
        case godan
        case suru
        case kuru
    }

    enum ConjugationSet: Hashable, Sendable {
        case common
        case all
    }

    static func detectVerbClass(fromJMDictPosTags tags: [String]) -> VerbClass? {
        let normalized = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.isEmpty == false }

        if normalized.contains("vk") { return .kuru }
        if normalized.contains(where: { $0.hasPrefix("vs") || $0 == "vs" }) { return .suru }
        if normalized.contains("v1") { return .ichidan }
        if normalized.contains(where: { $0.hasPrefix("v5") }) { return .godan }
        return nil
    }

    static func conjugations(for dictionaryForm: String, verbClass: VerbClass, set: ConjugationSet) -> [JapaneseVerbConjugation] {
        let base = dictionaryForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.isEmpty == false else { return [] }

        let all = buildAllConjugations(base: base, verbClass: verbClass)
        if set == .all { return all }

        let commonLabels: [String] = [
            "Polite (ます)",
            "Negative (ない)",
            "Past (た)",
            "て-form",
            "Potential",
            "Volitional"
        ]
        let byLabel = Dictionary(uniqueKeysWithValues: all.map { ($0.label, $0) })
        return commonLabels.compactMap { byLabel[$0] }
    }
}

private extension JapaneseVerbConjugator {
    static func buildAllConjugations(base: String, verbClass: VerbClass) -> [JapaneseVerbConjugation] {
        switch verbClass {
        case .ichidan:
            return ichidan(base)
        case .godan:
            return godan(base)
        case .suru:
            return suru(base)
        case .kuru:
            return kuru(base)
        }
    }

    static func ichidan(_ base: String) -> [JapaneseVerbConjugation] {
        guard base.hasSuffix("る"), base.count >= 2 else { return [] }
        let stem = String(base.dropLast(1))
        return orderedUnique([
            .init(label: "Dictionary", surface: base),
            .init(label: "Polite (ます)", surface: stem + "ます"),
            .init(label: "Polite past (ました)", surface: stem + "ました"),
            .init(label: "Polite negative (ません)", surface: stem + "ません"),
            .init(label: "Negative (ない)", surface: stem + "ない"),
            .init(label: "Negative past (なかった)", surface: stem + "なかった"),
            .init(label: "Past (た)", surface: stem + "た"),
            .init(label: "て-form", surface: stem + "て"),
            .init(label: "Progressive (ている)", surface: stem + "ている"),
            .init(label: "Potential", surface: stem + "られる"),
            .init(label: "Passive", surface: stem + "られる"),
            .init(label: "Causative", surface: stem + "させる"),
            .init(label: "Volitional", surface: stem + "よう"),
            .init(label: "Imperative", surface: stem + "ろ"),
            .init(label: "Conditional (ば)", surface: stem + "れば"),
            .init(label: "Conditional (たら)", surface: stem + "たら"),
            .init(label: "Prohibitive", surface: base + "な"),
            .init(label: "Desire (たい)", surface: stem + "たい")
        ])
    }

    static func godan(_ base: String) -> [JapaneseVerbConjugation] {
        guard let last = base.last else { return [] }
        let lastKana = String(last)
        let stem = String(base.dropLast(1))

        guard let iStem = godanStem(lastKana: lastKana, row: .i),
              let aStem = godanStem(lastKana: lastKana, row: .a),
              let eStem = godanStem(lastKana: lastKana, row: .e),
              let oStem = godanStem(lastKana: lastKana, row: .o)
        else {
            return []
        }

        let teTa = godanTeTa(base: base, lastKana: lastKana, stem: stem)
        let te = teTa.te
        let ta = teTa.ta

        return orderedUnique([
            .init(label: "Dictionary", surface: base),
            .init(label: "Polite (ます)", surface: stem + iStem + "ます"),
            .init(label: "Polite past (ました)", surface: stem + iStem + "ました"),
            .init(label: "Polite negative (ません)", surface: stem + iStem + "ません"),
            .init(label: "Negative (ない)", surface: stem + aStem + "ない"),
            .init(label: "Negative past (なかった)", surface: stem + aStem + "なかった"),
            .init(label: "Past (た)", surface: ta),
            .init(label: "て-form", surface: te),
            .init(label: "Progressive (ている)", surface: te + "いる"),
            .init(label: "Potential", surface: stem + eStem + "る"),
            .init(label: "Passive", surface: stem + aStem + "れる"),
            .init(label: "Causative", surface: stem + aStem + "せる"),
            .init(label: "Volitional", surface: stem + oStem + "う"),
            .init(label: "Imperative", surface: stem + eStem),
            .init(label: "Conditional (ば)", surface: stem + eStem + "ば"),
            .init(label: "Conditional (たら)", surface: ta + "ら"),
            .init(label: "Prohibitive", surface: base + "な"),
            .init(label: "Desire (たい)", surface: stem + iStem + "たい")
        ])
    }

    static func suru(_ base: String) -> [JapaneseVerbConjugation] {
        guard base.hasSuffix("する"), base.count >= 3 else { return [] }
        let stem = String(base.dropLast(2))
        return orderedUnique([
            .init(label: "Dictionary", surface: base),
            .init(label: "Polite (ます)", surface: stem + "します"),
            .init(label: "Polite past (ました)", surface: stem + "しました"),
            .init(label: "Polite negative (ません)", surface: stem + "しません"),
            .init(label: "Negative (ない)", surface: stem + "しない"),
            .init(label: "Negative past (なかった)", surface: stem + "しなかった"),
            .init(label: "Past (た)", surface: stem + "した"),
            .init(label: "て-form", surface: stem + "して"),
            .init(label: "Progressive (ている)", surface: stem + "している"),
            .init(label: "Potential", surface: stem + "できる"),
            .init(label: "Passive", surface: stem + "される"),
            .init(label: "Causative", surface: stem + "させる"),
            .init(label: "Volitional", surface: stem + "しよう"),
            .init(label: "Imperative", surface: stem + "しろ"),
            .init(label: "Imperative (alt)", surface: stem + "せよ"),
            .init(label: "Conditional (ば)", surface: stem + "すれば"),
            .init(label: "Conditional (たら)", surface: stem + "したら"),
            .init(label: "Prohibitive", surface: stem + "するな"),
            .init(label: "Desire (たい)", surface: stem + "したい")
        ])
    }

    static func kuru(_ base: String) -> [JapaneseVerbConjugation] {
        // Handle both kana and kanji spellings.
        if base.hasSuffix("くる") {
            let prefix = String(base.dropLast(2))
            return orderedUnique([
                .init(label: "Dictionary", surface: base),
                .init(label: "Polite (ます)", surface: prefix + "きます"),
                .init(label: "Polite past (ました)", surface: prefix + "きました"),
                .init(label: "Polite negative (ません)", surface: prefix + "きません"),
                .init(label: "Negative (ない)", surface: prefix + "こない"),
                .init(label: "Negative past (なかった)", surface: prefix + "こなかった"),
                .init(label: "Past (た)", surface: prefix + "きた"),
                .init(label: "て-form", surface: prefix + "きて"),
                .init(label: "Progressive (ている)", surface: prefix + "きている"),
                .init(label: "Potential", surface: prefix + "こられる"),
                .init(label: "Passive", surface: prefix + "こられる"),
                .init(label: "Causative", surface: prefix + "こさせる"),
                .init(label: "Volitional", surface: prefix + "こよう"),
                .init(label: "Imperative", surface: prefix + "こい"),
                .init(label: "Conditional (ば)", surface: prefix + "くれば"),
                .init(label: "Conditional (たら)", surface: prefix + "きたら"),
                .init(label: "Prohibitive", surface: base + "な")
            ])
        }

        if base.hasSuffix("来る") {
            let prefix = String(base.dropLast(1)) // drop る
            return orderedUnique([
                .init(label: "Dictionary", surface: base),
                .init(label: "Polite (ます)", surface: prefix + "ます"),
                .init(label: "Polite past (ました)", surface: prefix + "ました"),
                .init(label: "Polite negative (ません)", surface: prefix + "ません"),
                .init(label: "Negative (ない)", surface: prefix + "ない"),
                .init(label: "Negative past (なかった)", surface: prefix + "なかった"),
                .init(label: "Past (た)", surface: prefix + "た"),
                .init(label: "て-form", surface: prefix + "て"),
                .init(label: "Progressive (ている)", surface: prefix + "ている"),
                .init(label: "Potential", surface: prefix + "られる"),
                .init(label: "Passive", surface: prefix + "られる"),
                .init(label: "Causative", surface: prefix + "させる"),
                .init(label: "Volitional", surface: prefix + "よう"),
                .init(label: "Imperative", surface: prefix + "い"),
                .init(label: "Conditional (ば)", surface: prefix + "れば"),
                .init(label: "Conditional (たら)", surface: prefix + "たら"),
                .init(label: "Prohibitive", surface: base + "な")
            ])
        }

        // Fallback: treat any ...る as ichidan-like.
        return ichidan(base)
    }

    enum GodanRow {
        case a, i, e, o
    }

    static func godanStem(lastKana: String, row: GodanRow) -> String? {
        let table: [String: (a: String, i: String, e: String, o: String)] = [
            "う": ("わ", "い", "え", "お"),
            "く": ("か", "き", "け", "こ"),
            "ぐ": ("が", "ぎ", "げ", "ご"),
            "す": ("さ", "し", "せ", "そ"),
            "つ": ("た", "ち", "て", "と"),
            "ぬ": ("な", "に", "ね", "の"),
            "ぶ": ("ば", "び", "べ", "ぼ"),
            "む": ("ま", "み", "め", "も"),
            "る": ("ら", "り", "れ", "ろ")
        ]
        guard let entry = table[lastKana] else { return nil }
        switch row {
        case .a: return entry.a
        case .i: return entry.i
        case .e: return entry.e
        case .o: return entry.o
        }
    }

    static func godanTeTa(base: String, lastKana: String, stem: String) -> (te: String, ta: String) {
        // Special-case 行く / いく.
        if base.hasSuffix("行く") || base.hasSuffix("いく") {
            return (stem + "って", stem + "った")
        }
        switch lastKana {
        case "う", "つ", "る":
            return (stem + "って", stem + "った")
        case "む", "ぶ", "ぬ":
            return (stem + "んで", stem + "んだ")
        case "く":
            return (stem + "いて", stem + "いた")
        case "ぐ":
            return (stem + "いで", stem + "いだ")
        case "す":
            return (stem + "して", stem + "した")
        default:
            // If unknown, degrade reasonably.
            return (stem + lastKana + "て", stem + lastKana + "た")
        }
    }

    static func orderedUnique(_ items: [JapaneseVerbConjugation]) -> [JapaneseVerbConjugation] {
        var seen: Set<String> = []
        var out: [JapaneseVerbConjugation] = []
        out.reserveCapacity(items.count)
        for item in items {
            let key = item.label + "|" + item.surface
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out
    }
}
