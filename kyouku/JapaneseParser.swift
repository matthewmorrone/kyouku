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

        if let trie = JMdictTrieCache.shared {
            let tokenizer = TokenizerFactory.make() ?? (try? Tokenizer(dictionary: IPADic()))
            let segments = DictionarySegmenter.segment(text: text, trie: trie)
            let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: segments, tokenizer: tokenizer)
            return enriched.map { item in
                ParsedToken(surface: item.segment.surface, reading: item.reading, meaning: nil)
            }
        }

        guard let fallbackTokenizer = try? Tokenizer(dictionary: IPADic()) else {
            return []
        }

        let ann = fallbackTokenizer.tokenize(text: text)
        var tokens: [ParsedToken] = []

        for a in ann {
            let surface = String(text[a.range])
            let reading = a.reading
            if surface == "BOS" || surface == "EOS" { continue }
            tokens.append(ParsedToken(surface: surface, reading: reading, meaning: nil))
        }

        return tokens
    }
}

