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

    static func buildAttributedText(text: String, showFurigana: Bool) -> NSAttributedString {
        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont
        ]

        // Begin with plain text
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)

        guard showFurigana, let tokenizer = sharedTokenizer else {
            return attributed
        }

        let annotations = tokenizer.tokenize(text: text)

        // Slightly smaller than body font → Apple Books-like ruby size
        let rubyFont = UIFont.systemFont(ofSize: baseFont.pointSize * 0.55)

        for ann in annotations {
            // Only add furigana when:
            // 1) token has kanji
            // 2) reading ≠ surface
            if !ann.containsKanji { continue }
            if ann.reading == String(text[ann.range]) { continue }

            let reading = ann.reading
            let nsRange = NSRange(ann.range, in: text)

            // Build a CTRubyAnnotation for furigana
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
}
