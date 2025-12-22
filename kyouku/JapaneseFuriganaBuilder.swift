//
//  JapaneseFuriganaBuilder.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import Foundation
import CoreFoundation
import CoreText
import Mecab_Swift
import IPADic
import UIKit

enum JapaneseFuriganaBuilder {

    // Shared tokenizer for furigana building (lazily initialized). If initialization fails at startup,
    // we will retry on demand so furigana doesn't permanently disable.
    private static var sharedTokenizer: Tokenizer? = {
        return try? Tokenizer(dictionary: IPADic())
    }()

    private static func tokenizer() -> Tokenizer? {
        if let t = sharedTokenizer { return t }
        sharedTokenizer = try? Tokenizer(dictionary: IPADic())
        return sharedTokenizer
    }

    /// Convert Katakana/Hiragana to Hiragana for consistent furigana display.
    /// MeCab (IPADic) commonly returns readings in Katakana.
    private static func toHiragana(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let m = NSMutableString(string: s) as CFMutableString
        // Use Hiragana<->Katakana transform with reverse=true to convert Katakana -> Hiragana.
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        return m as String
    }
    
    private static func refinedRubyTargets(range: NSRange, reading: String, in text: String) -> [(NSRange, String)] {
        guard let swiftRange = Range(range, in: text) else { return [] }
        let surface = String(text[swiftRange])
        let chars = Array(surface)

        // 1) Trim leading/trailing non-kanji (okurigana/punct)
        var lead = 0
        var trail = 0
        func isKanji(_ c: Character) -> Bool { String(c).containsKanji }
        while lead < chars.count, !isKanji(chars[lead]) { lead += 1 }
        while trail < chars.count - lead, !isKanji(chars[chars.count - 1 - trail]) { trail += 1 }
        let innerLen = chars.count - lead - trail
        guard innerLen > 0 else { return [] }
        let innerStart = range.location + lead
        let innerSurface = String(chars[lead..<(lead + innerLen)])

        // 2) Trim reading symmetrically at start/end based on outer okurigana
        let rAll = Array(reading)
        let startTrim = min(lead, rAll.count)
        let endTrim = min(trail, max(0, rAll.count - startTrim))
        let rTrimmed = Array(rAll.dropFirst(startTrim).dropLast(endTrim))

        // 3) Split innerSurface into alternating [KanjiRun][KanaSeq][KanjiRun]...
        struct Run { let start: Int; let length: Int }
        var kanjiRuns: [Run] = []
        var i = 0
        let innerChars = Array(innerSurface)
        while i < innerChars.count {
            if isKanji(innerChars[i]) {
                let start = i
                var j = i
                while j < innerChars.count && isKanji(innerChars[j]) { j += 1 }
                kanjiRuns.append(Run(start: start, length: j - start))
                i = j
            } else {
                i += 1
            }
        }
        if kanjiRuns.isEmpty { return [] }

        // 4) Use kana sequences in innerSurface as anchors to split the reading
        // Walk innerSurface and rTrimmed in parallel, carving reading slices for each kanji run until the next kana sequence in innerSurface appears in rTrimmed.
        func isKana(_ c: Character) -> Bool {
            for s in c.unicodeScalars {
                let v = s.value
                if (0x3040...0x309F).contains(v) { return true } // Hiragana
                if (0x30A0...0x30FF).contains(v) { return true } // Katakana
            }
            return false
        }

        var rIndex = 0
        var results: [(NSRange, String)] = []

        for (idx, run) in kanjiRuns.enumerated() {
            // Find the next kana sequence after this run in innerSurface
            let runEnd = run.start + run.length
            var nextKanaSeq = ""
            var k = runEnd
            while k < innerChars.count {
                if isKana(innerChars[k]) {
                    var kk = k
                    while kk < innerChars.count && isKana(innerChars[kk]) { kk += 1 }
                    nextKanaSeq = String(innerChars[k..<kk])
                    break
                }
                k += 1
            }

            let remaining = rIndex < rTrimmed.count ? String(rTrimmed[rIndex...]) : ""
            var slice = remaining
            var consumedAnchorCount = 0
            if !nextKanaSeq.isEmpty, let rangeInReading = remaining.range(of: nextKanaSeq) {
                slice = String(remaining[..<rangeInReading.lowerBound])
                // Skip over the kana anchor before processing the next kanji run
                consumedAnchorCount = nextKanaSeq.count
            } else if idx < kanjiRuns.count - 1 {
                // No anchor found but more kanji runs remain. First, see if the remaining reading can be split
                // exactly evenly across the remaining kanji runs; this helps for words like 巡り合う where the reading
                // (めぐりあう) needs "めぐ" + "り" + "あ" over the consecutive kanji segments.
                let remainingRuns = kanjiRuns.count - idx
                let remCount = remaining.count
                if remCount % remainingRuns == 0 {
                    let chunk = remCount / remainingRuns
                    slice = String(remaining.prefix(max(1, chunk)))
                } else {
                    let per = max(1, remCount / remainingRuns)
                    slice = String(remaining.prefix(per))
                }
            }
            // Advance rIndex by slice length
            rIndex += slice.count
            if consumedAnchorCount > 0 {
                rIndex += consumedAnchorCount
            }

            // Build NSRange for this kanji run relative to original text
            let rLoc = innerStart + run.start
            let rLen = run.length
            let ns = NSRange(location: rLoc, length: rLen)
            let ruby = slice.isEmpty ? String(remaining.prefix(1)) : slice
            results.append((ns, ruby))
        }

        return results
    }

    static func buildAttributedText(
        text: String,
        showFurigana: Bool,
        baseFontSize: CGFloat,
        rubyFontSize: CGFloat,
        lineSpacing: CGFloat,
        segments: [Segment]? = nil,
        forceMeCabOnly: Bool = false,
        perKanjiSplit: Bool = true
    ) -> NSAttributedString {
        let baseFont = UIFont.systemFont(ofSize: baseFontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor.label
        ]

        // Begin with plain text
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)

        guard showFurigana else {
            return attributed
        }

        let rubyFont = UIFont.systemFont(ofSize: rubyFontSize)
        var rubyTargets: [(NSRange, String)] = []

        if let fixedSegments = segments {
            // Use caller-provided segments to keep boundaries stable; MeCab only for readings
            if let mecab = tokenizer() {
                let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: fixedSegments, tokenizer: mecab)
                for item in enriched {
                    if !item.segment.surface.containsKanji { continue }
                    let reading = item.reading
                    if reading.isEmpty || reading == item.segment.surface { continue }
                    let nsRange = NSRange(item.segment.range, in: text)
                    if nsRange.location != NSNotFound {
                        rubyTargets.append((nsRange, toHiragana(reading)))
                    }
                }
            }
        } else {
            let engine = SegmentationEngine.current()
            if engine == .dictionaryTrie, let trie = TrieCache.shared, !forceMeCabOnly {
                let mecab = tokenizer()
                if let mecab {
                    let segments = DictionarySegmenter.segment(text: text, trie: trie)
                    let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: segments, tokenizer: mecab)
                    for item in enriched {
                        if !item.segment.surface.containsKanji { continue }
                        let reading = item.reading
                        if reading.isEmpty || reading == item.segment.surface { continue }
                        let nsRange = NSRange(item.segment.range, in: text)
                        rubyTargets.append((nsRange, toHiragana(reading)))
                    }
                }
            } else if engine == .appleTokenizer, !forceMeCabOnly {
                let mecab = tokenizer()
                if let mecab {
                    let appleSegments = AppleSegmenter.segment(text: text)
                    let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: appleSegments, tokenizer: mecab)
                    for item in enriched {
                        if !item.segment.surface.containsKanji { continue }
                        let reading = item.reading
                        if reading.isEmpty || reading == item.segment.surface { continue }
                        let nsRange = NSRange(item.segment.range, in: text)
                        rubyTargets.append((nsRange, toHiragana(reading)))
                    }
                }
            } else {
                // Fallback: no trie yet — use MeCab-only tokenization to attach ruby per annotation
                if let mecab = tokenizer() {
                    let anns = mecab.tokenize(text: text)
                    for a in anns {
                        let surface = String(text[a.range])
                        if !surface.containsKanji { continue }
                        let reading = a.reading
                        if reading.isEmpty || reading == surface { continue }
                        let nsRange = NSRange(a.range, in: text)
                        if nsRange.location != NSNotFound {
                            rubyTargets.append((nsRange, toHiragana(reading)))
                        }
                    }
                }
            }
        }

        fillMissingRubyTargets(&rubyTargets, text: text)

        // If furigana is relatively long, increase inter-character spacing a bit to give ruby room
        let computedKern = dynamicKerning(for: rubyTargets, in: text)
        if computedKern > 0 {
            attributed.addAttribute(.kern, value: computedKern, range: NSRange(location: 0, length: attributed.length))
        }

        func applyRuby(range: NSRange, reading: String) {
            let ruby = CTRubyAnnotationCreateWithAttributes(
                .auto,
                .auto,
                .before,
                reading as CFString,
                [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
            )
            attributed.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby, range: range)
            attributed.addAttribute(.rubyReading, value: reading, range: range)
        }

        for (range, reading) in rubyTargets {
            if perKanjiSplit {
                for (r2, rd2) in Self.refinedRubyTargets(range: range, reading: reading, in: text) {
                    applyRuby(range: r2, reading: rd2)
                }
            } else {
                applyRuby(range: range, reading: reading)
            }
        }

        return attributed
    }

    private static func dynamicKerning(for targets: [(NSRange, String)], in text: String) -> CGFloat {
        guard !targets.isEmpty else { return 0 }
        // Compute the maximum ratio of reading length to base length across targets
        var maxRatio: CGFloat = 1.0
        for (range, reading) in targets {
            guard range.length > 0 else { continue }
            let baseLen = max(1, range.length)
            let readingLen = max(0, reading.count)
            if baseLen > 0 {
                let ratio = CGFloat(readingLen) / CGFloat(baseLen)
                if ratio > maxRatio { maxRatio = ratio }
            }
        }
        if maxRatio <= 1.1 { return 0 } // no extra spacing needed
        // Heuristic: translate overage into kerning points, capped
        // e.g., ratio 1.6 -> 0.3pt, ratio 2.0 -> ~0.6pt, cap at 1.0pt
        let over = maxRatio - 1.0
        let kern = min(1.0, over * 0.6)
        return kern
    }

    private static func fillMissingRubyTargets(_ targets: inout [(NSRange, String)], text: String) {
        guard let mecab = tokenizer() else { return }

        var covered = IndexSet()
        for (range, _) in targets {
            if range.location != NSNotFound && range.length > 0 {
                covered.insert(integersIn: range.location ..< (range.location + range.length))
            }
        }

        let annotations = mecab.tokenize(text: text)
        for ann in annotations {
            let surface = String(text[ann.range])
            if !surface.containsKanji { continue }
            let nsRange = NSRange(ann.range, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 { continue }
            let raw = nsRange.location ..< (nsRange.location + nsRange.length)
            if covered.contains(integersIn: raw) { continue }
            let reading = ann.reading
            if reading.isEmpty || reading == surface { continue }
            covered.insert(integersIn: raw)
            targets.append((nsRange, toHiragana(reading)))
        }
    }

    static func buildAttributedText(text: String, showFurigana: Bool, forceMeCabOnly: Bool = false, perKanjiSplit: Bool = true) -> NSAttributedString {
        let baseDefault = UIFont.preferredFont(forTextStyle: .body).pointSize
        let defaults = UserDefaults.standard
        let baseSize = defaults.object(forKey: "readingTextSize") as? Double ?? Double(baseDefault)
        let rubySize = defaults.object(forKey: "readingFuriganaSize") as? Double ?? (baseSize * 0.55)
        let spacing = defaults.object(forKey: "readingLineSpacing") as? Double ?? 0

        return buildAttributedText(
            text: text,
            showFurigana: showFurigana,
            baseFontSize: CGFloat(baseSize),
            rubyFontSize: CGFloat(rubySize),
            lineSpacing: CGFloat(spacing),
            forceMeCabOnly: forceMeCabOnly,
            perKanjiSplit: perKanjiSplit
        )
    }
    
    static func buildAttributedText(text: String, showFurigana: Bool, segments: [Segment], forceMeCabOnly: Bool = false, perKanjiSplit: Bool = true) -> NSAttributedString {
        let baseDefault = UIFont.preferredFont(forTextStyle: .body).pointSize
        let defaults = UserDefaults.standard
        let baseSize = defaults.object(forKey: "readingTextSize") as? Double ?? Double(baseDefault)
        let rubySize = defaults.object(forKey: "readingFuriganaSize") as? Double ?? (baseSize * 0.55)
        let spacing = defaults.object(forKey: "readingLineSpacing") as? Double ?? 0
        return buildAttributedText(
            text: text,
            showFurigana: showFurigana,
            baseFontSize: CGFloat(baseSize),
            rubyFontSize: CGFloat(rubySize),
            lineSpacing: CGFloat(spacing),
            segments: segments,
            forceMeCabOnly: forceMeCabOnly,
            perKanjiSplit: perKanjiSplit
        )
    }

    static func buildWholeWordRuby(text: String, reading: String) -> NSAttributedString {
        let baseDefault = UIFont.preferredFont(forTextStyle: .body).pointSize
        let defaults = UserDefaults.standard
        let baseSize = defaults.object(forKey: "readingTextSize") as? Double ?? Double(baseDefault)
        let rubySize = defaults.object(forKey: "readingFuriganaSize") as? Double ?? (baseSize * 0.55)
        let spacing = defaults.object(forKey: "readingLineSpacing") as? Double ?? 0
        return buildWholeWordRuby(
            text: text,
            reading: reading,
            baseFontSize: CGFloat(baseSize),
            rubyFontSize: CGFloat(rubySize),
            lineSpacing: CGFloat(spacing)
        )
    }

    private static func buildWholeWordRuby(text: String, reading: String, baseFontSize: CGFloat, rubyFontSize: CGFloat, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: baseFontSize),
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor.label
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)

        // Apply a small kerning if reading is much longer than base to give ruby more space
        if !text.isEmpty {
            let baseLen = max(1, (text as NSString).length)
            let readingLen = max(0, reading.count)
            let ratio = CGFloat(readingLen) / CGFloat(baseLen)
            if ratio > 1.1 {
                let over = ratio - 1.0
                let kern = min(1.0, over * 0.6)
                if kern > 0 {
                    attributed.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: attributed.length))
                }
            }
        }

        let trimmedReading = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attributed.length > 0, trimmedReading.isEmpty == false else { return attributed }

        let rubyAttributes = [kCTFontAttributeName as NSAttributedString.Key: UIFont.systemFont(ofSize: rubyFontSize)] as CFDictionary
        let normalizedReading = toHiragana(trimmedReading)
        let ruby = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, normalizedReading as CFString, rubyAttributes)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby, range: range)
        attributed.addAttribute(.rubyReading, value: normalizedReading, range: range)
        return attributed
    }
}

private extension String {
    var containsKanji: Bool {
        return unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

