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
        let tokenizer = TokenizerFactory.make() ?? (try? Tokenizer(dictionary: IPADic()))
        let engine = SegmentationEngine.current()

        if engine == .dictionaryTrie, let trie = JMdictTrieCache.shared {
            let segments = DictionarySegmenter.segment(text: text, trie: trie)
            let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: segments, tokenizer: tokenizer)
            return enriched.map { item in
                ParsedToken(surface: item.segment.surface, reading: item.reading, meaning: nil)
            }
        } else if engine == .appleTokenizer {
            let segments = AppleSegmenter.segment(text: text)
            let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: segments, tokenizer: tokenizer)
            if enriched.isEmpty {
                return fallbackParse(text: text)
            }
            return enriched.map { ParsedToken(surface: $0.segment.surface, reading: $0.reading, meaning: nil) }
        }

        return fallbackParse(text: text)
    }

    private static func fallbackParse(text: String) -> [ParsedToken] {
        guard let fallbackTokenizer = try? Tokenizer(dictionary: IPADic()) else { return [] }
        let ann = fallbackTokenizer.tokenize(text: text)
        return ann.compactMap { ann in
            let surface = String(text[ann.range])
            if surface == "BOS" || surface == "EOS" { return nil }
            return ParsedToken(surface: surface, reading: ann.reading, meaning: nil)
        }
    }
}

