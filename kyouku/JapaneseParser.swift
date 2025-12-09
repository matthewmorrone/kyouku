//
//  JapaneseParser.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

enum JapaneseParser {
    static func parse(text: String) -> [ParsedToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        
        // Temporary fake tokenizer
        // MeCab will replace this entirely.
        return [
            ParsedToken(
                surface: trimmed,
                reading: trimmed,
                meaning: ""
            )
        ]
    }
}
