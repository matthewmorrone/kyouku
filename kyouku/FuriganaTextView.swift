//
//  FuriganaTextView.swift
//  Kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI
import UIKit

@MainActor
struct FuriganaTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    // Convenience initializers to build attributed text on the fly
    init(attributedText: NSAttributedString) {
        self.attributedText = attributedText
    }

    init(text: String, showFurigana: Bool = true, perKanjiFurigana: Bool = true) {
        self.attributedText = JapaneseFuriganaBuilder.buildAttributedText(
            text: text,
            showFurigana: showFurigana,
            perKanjiSplit: perKanjiFurigana
        )
    }

    init(token: ParsedToken, perKanjiFurigana: Bool = true) {
        if perKanjiFurigana {
            self.init(text: token.surface, showFurigana: true, perKanjiFurigana: true)
            return
        }

        let surface = token.surface
        guard surface.isEmpty == false else {
            self.init(attributedText: NSAttributedString(string: surface))
            return
        }

        let trimmedReading = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReading.isEmpty == false {
            let attributed = JapaneseFuriganaBuilder.buildWholeWordRuby(text: surface, reading: trimmedReading)
            self.init(attributedText: attributed)
            return
        }

        let range = surface.startIndex..<surface.endIndex
        let segment = Segment(range: range, surface: surface, isDictionaryMatch: true)
        let attributed = JapaneseFuriganaBuilder.buildAttributedText(
            text: surface,
            showFurigana: true,
            segments: [segment],
            forceMeCabOnly: true,
            perKanjiSplit: false
        )
        self.init(attributedText: attributed)
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.attributedText = attributedText
    }
}

