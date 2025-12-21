import SwiftUI

struct ImportPreviewDetectedRow: View {
    let surface: String
    let reading: String
    let meaning: String
    let note: String?

    var body: some View {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)

        func isEnglishLike(_ t: String) -> Bool {
            // Detect presence of ASCII letters; do not treat as kana
            return t.range(of: "[A-Za-z]", options: .regularExpression) != nil
        }

        var used = Set<String>()

        let kanjiText: String = {
            if !s.isEmpty && containsKanji(s) { used.insert(s); return s }
            if !r.isEmpty && containsKanji(r) { used.insert(r); return r }
            if !m.isEmpty && containsKanji(m) { used.insert(m); return m }
            return ""
        }()

        let kanaText: String = {
            if !r.isEmpty && isKana(r) && !used.contains(r) { used.insert(r); return r }
            if !s.isEmpty && isKana(s) && !used.contains(s) { used.insert(s); return s }
            if !m.isEmpty && isKana(m) && !used.contains(m) { used.insert(m); return m }
            return ""
        }()

        let englishText: String = {
            if !m.isEmpty && isEnglishLike(m) && !used.contains(m) { used.insert(m); return m }
            if !s.isEmpty && isEnglishLike(s) && !used.contains(s) { used.insert(s); return s }
            if !r.isEmpty && isEnglishLike(r) && !used.contains(r) { used.insert(r); return r }
            return ""
        }()

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kanji")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(kanjiText.isEmpty ? "—" : kanjiText)
                    .font(.body)
                    .foregroundColor(kanjiText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Kana")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(kanaText.isEmpty ? "—" : kanaText)
                    .font(.body)
                    .foregroundColor(kanaText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("English")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(englishText.isEmpty ? "—" : englishText)
                    .font(.body)
                    .foregroundColor(englishText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private func labelColor(for label: String) -> Color {
        switch label {
        case "Kanji/Mixed": return .orange
        case "Kana": return .blue
        case "English": return .green
        case "Note": return .secondary
        default: return .secondary
        }
    }

    private func typeLabel(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if containsKanji(trimmed) { return "Kanji/Mixed" }
        if isKana(trimmed) { return "Kana" }
        // If it has ASCII letters or spaces, call it English
        if trimmed.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            return "English"
        }
        return "Kanji/Mixed"
    }
}

// Minimal helpers duplicated to keep this component independent.
private func containsKanji(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) ||
           (0x3400...0x4DBF).contains(scalar.value) ||
           (0xF900...0xFAFF).contains(scalar.value) {
            return true
        }
    }
    return false
}

private func isKana(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    for scalar in s.unicodeScalars {
        let v = scalar.value
        let isHiragana = (0x3040...0x309F).contains(v)
        let isKatakana = (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
        let isProlonged = v == 0x30FC
        let isSmallTsu = v == 0x3063 || v == 0x30C3
        let isPunctuation = v == 0x3001 || v == 0x3002
        if !(isHiragana || isKatakana || isProlonged || isSmallTsu || isPunctuation) {
            return false
        }
    }
    return true
}

#Preview {
    List {
        ImportPreviewDetectedRow(surface: "食べる", reading: "たべる", meaning: "to eat", note: "verb")
        ImportPreviewDetectedRow(surface: "りんご", reading: "リンゴ", meaning: "apple", note: nil)
        ImportPreviewDetectedRow(surface: "銀行", reading: "ぎんこう", meaning: "bank", note: "common")
    }
}
