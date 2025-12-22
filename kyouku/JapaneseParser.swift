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
        let tokenizer = try? Tokenizer(dictionary: IPADic())
        let engine = SegmentationEngine.current()

        func tokens(from segments: [Segment]) -> [ParsedToken] {
            guard !segments.isEmpty else { return [] }
            let enriched = SegmentReadingAttacher.attachReadings(text: text, segments: segments, tokenizer: tokenizer)
            return enriched.map { ParsedToken(surface: $0.segment.surface, reading: $0.reading, meaning: nil) }
        }

        if engine == .dictionaryTrie {
            if let trie = TrieCache.shared {
                let segments = DictionarySegmenter.segment(text: text, trie: trie)
                let parsed = tokens(from: segments)
                if !parsed.isEmpty {
                    return parsed
                }
            }
            // Dictionary engine selected but trie is not yet ready: fall back to the same Apple tokenizer
            // path that FuriganaTextEditor uses so both UIs stay in sync.
            let appleSegments = AppleSegmenter.segment(text: text)
            let parsed = tokens(from: appleSegments)
            if !parsed.isEmpty {
                return parsed
            }
            return fallbackParse(text: text)
        }

        if engine == .appleTokenizer {
            let appleSegments = AppleSegmenter.segment(text: text)
            let parsed = tokens(from: appleSegments)
            if !parsed.isEmpty {
                return parsed
            }
            return fallbackParse(text: text)
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

