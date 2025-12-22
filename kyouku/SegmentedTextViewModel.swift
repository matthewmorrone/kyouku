//
//  SegmentedTextViewModel.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import SwiftUI
import UIKit
import Combine

final class SegmentedTextViewModel: ObservableObject {
    @Published var text: String {
        didSet {
            if oldValue != text {
                recomputeSegments()
            }
        }
    }
    @Published var trie: Trie? {
        didSet {
            // Do not recompute segments when only the trie changes; keep boundaries stable
            // for the current text. We'll recompute when `text` actually changes.
        }
    }
    @Published private(set) var segments: [Segment] = []
    @Published var selected: Segment? = nil

    private var lastSegmentedText: String = ""

    init(text: String, trie: Trie?) {
        self.text = text
        self.trie = trie
        recomputeSegments()
    }

    func recomputeSegments() {
        // Avoid resegmenting if the text hasn't changed; this prevents runtime boundary snaps
        if text == lastSegmentedText { return }
        let engine = SegmentationEngine.current()
        if engine == .dictionaryTrie {
            if let trie {
                segments = DictionarySegmenter.segment(text: text, trie: trie)
            } else if let shared = TrieCache.shared {
                segments = DictionarySegmenter.segment(text: text, trie: shared)
            } else {
                segments = AppleSegmenter.segment(text: text)
            }
        } else {
            segments = AppleSegmenter.segment(text: text)
        }
        lastSegmentedText = text
        if let sel = selected {
            if !segments.contains(where: { $0.range == sel.range }) {
                selected = nil
            }
        }
    }
    
    func invalidateSegmentation() {
        lastSegmentedText = ""
        recomputeSegments()
    }

    func select(at index: String.Index) {
        if let seg = segments.first(where: { $0.range.contains(index) }) {
            selected = seg
        } else {
            selected = nil
        }
    }
}
