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
        lineSpacing: CGFloat
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

        guard showFurigana, let tokenizer = tokenizer() else {
            return attributed
        }

        let annotations = tokenizer.tokenize(text: text)

        let rubyFont = UIFont.systemFont(ofSize: rubyFontSize)

        for ann in annotations {
            let surface = String(text[ann.range])
            // Skip if no kanji in the surface
            let hasKanji = surface.contains { ch in
                ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
            }
            if !hasKanji { continue }
            // Skip if tokenizer didn't provide a reading
            if ann.reading.isEmpty { continue }

            // Normalize ruby to hiragana so furigana is consistent in the UI.
            let reading = toHiragana(ann.reading)
            let nsRange = NSRange(ann.range, in: text)

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
                range: nsRange
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
}

