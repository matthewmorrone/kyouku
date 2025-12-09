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

    init(text: String, showFurigana: Bool = true) {
        self.attributedText = JapaneseFuriganaBuilder.buildAttributedText(
            text: text,
            showFurigana: showFurigana
        )
    }

    init(token: ParsedToken) {
        self.init(text: token.surface, showFurigana: true)
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

