//
//  JapaneseParser.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//
import Foundation
import Mecab_Swift
import IPADic

enum JapaneseParser {

    static func parse(text: String) -> [ParsedToken] {

        // Tokenizer may throw
        guard let tokenizer = try? Tokenizer(dictionary: IPADic()) else {
            return []
        }

        // This version of tokenize does NOT throw
        let ann = tokenizer.tokenize(text: text)

        var tokens: [ParsedToken] = []

        for a in ann {

            // Pull out exactly what your Annotation type provides
            let surface = String(text[a.range])
            let reading = a.reading

            // Skip BOS/EOS if they appear
            if surface == "BOS" || surface == "EOS" { continue }

            tokens.append(
                ParsedToken(
                    surface: surface,
                    reading: reading,
                    meaning: nil
                )
            )
        }

        return tokens
    }
}

