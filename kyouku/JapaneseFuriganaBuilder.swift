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

            let rTrimmedStr = String(rTrimmed)
            let remaining = rIndex < rTrimmed.count ? String(rTrimmed[rIndex...]) : ""
            var slice = remaining
            if !nextKanaSeq.isEmpty, let rangeInReading = remaining.range(of: nextKanaSeq) {
                slice = String(remaining[..<rangeInReading.lowerBound])
                // Do not consume the kana anchor; leave it for the next iteration
            } else if idx < kanjiRuns.count - 1 {
                // No anchor found but more kanji runs remain: split remaining roughly equally by remaining runs
                let remainingRuns = kanjiRuns.count - idx
                let remCount = remaining.count
                let per = max(1, remCount / remainingRuns)
                slice = String(remaining.prefix(per))
            }
            // Advance rIndex by slice length
            rIndex += slice.count

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
        forceMeCabOnly: Bool = false
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
            if let mecab = TokenizerFactory.make() ?? tokenizer() {
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
            if let trie = JMdictTrieCache.shared, !forceMeCabOnly {
                let mecab = TokenizerFactory.make() ?? tokenizer()
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
            } else {
                // Fallback: no trie yet — use MeCab-only tokenization to attach ruby per annotation
                if let mecab = TokenizerFactory.make() ?? tokenizer() {
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

        for (range, reading) in rubyTargets {
            for (r2, rd2) in Self.refinedRubyTargets(range: range, reading: reading, in: text) {
                let ruby = CTRubyAnnotationCreateWithAttributes(
                    .auto,
                    .auto,
                    .before,
                    rd2 as CFString,
                    [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
                )
                attributed.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby, range: r2)
                attributed.addAttribute(.rubyReading, value: rd2, range: r2)
            }
        }

        return attributed
    }

    static func buildAttributedText(text: String, showFurigana: Bool, forceMeCabOnly: Bool = false) -> NSAttributedString {
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
            forceMeCabOnly: forceMeCabOnly
        )
    }
    
    static func buildAttributedText(text: String, showFurigana: Bool, segments: [Segment], forceMeCabOnly: Bool = false) -> NSAttributedString {
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
            forceMeCabOnly: forceMeCabOnly
        )
    }
}

private extension String {
    var containsKanji: Bool {
        return unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

