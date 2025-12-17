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

    static func buildAttributedText(
        text: String,
        showFurigana: Bool,
        baseFontSize: CGFloat,
        rubyFontSize: CGFloat,
        lineSpacing: CGFloat,
        segments: [Segment]? = nil
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
            if let trie = JMdictTrieCache.shared {
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
            }
        }

        for (range, reading) in rubyTargets {
            let ruby = CTRubyAnnotationCreateWithAttributes(
                .auto,
                .auto,
                .before,
                reading as CFString,
                [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
            )

            attributed.addAttribute(
                NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                value: ruby,
                range: range
            )
        }

        return attributed
    }

    static func buildAttributedText(text: String, showFurigana: Bool) -> NSAttributedString {
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
            lineSpacing: CGFloat(spacing)
        )
    }
    
    static func buildAttributedText(text: String, showFurigana: Bool, segments: [Segment]) -> NSAttributedString {
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
            segments: segments
        )
    }
}

private extension String {
    var containsKanji: Bool {
        return unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

