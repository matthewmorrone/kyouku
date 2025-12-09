//
//  JapaneseFuriganaBuilder.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import Foundation
import CoreText
import Mecab_Swift
import IPADic
import UIKit

enum JapaneseFuriganaBuilder {

    // Shared tokenizer for furigana building
    private static let sharedTokenizer: Tokenizer? = {
        return try? Tokenizer(dictionary: IPADic())
    }()

    @MainActor
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

        guard showFurigana, let tokenizer = sharedTokenizer else {
            return attributed
        }

        let annotations = tokenizer.tokenize(text: text)

        let rubyFont = UIFont.systemFont(ofSize: rubyFontSize)

        for ann in annotations {
            if !ann.containsKanji { continue }
            if ann.reading == String(text[ann.range]) { continue }

            let reading = ann.reading
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

    @MainActor
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
