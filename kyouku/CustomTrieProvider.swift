//
//  CustomTrieProvider.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import Foundation

enum CustomTrieProvider {
    /// Builds a Trie from the current lexicon. Cheap if list is small; call on demand.
    static func makeTrie() -> Trie? {
        let ws = CustomTokenizerLexicon.words()
        guard ws.isEmpty == false else { return nil }
        return Trie(words: ws)
    }
}