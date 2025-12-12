//
//  FuriganaTextEditor.swift
//  kyouku
//
//  Created by Assistant on 12/9/25.
//

import SwiftUI
import UIKit
import Mecab_Swift
import IPADic

struct FuriganaTextEditor: UIViewRepresentable {
    @Binding var text: String
    var showFurigana: Bool
    var isEditable: Bool = true
    var allowTokenTap: Bool = true
    var onTokenTap: (ParsedToken) -> Void

    var baseFontSize: Double? = nil
    var rubyFontSize: Double? = nil
    var lineSpacing: Double? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.isSelectable = true
        tv.textColor = .label

        // Disable smart substitutions to avoid conflicts with IME
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no

        // Tap recognizer to detect token taps
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        context.coordinator.tapRecognizer = tap
        tv.addGestureRecognizer(tap)

        // Initial content
        context.coordinator.updateTextView(tv, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.updateTextView(uiView, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap)
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: FuriganaTextEditor
        private var isProgrammaticUpdate = false
        var tapRecognizer: UITapGestureRecognizer?

        init(_ parent: FuriganaTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticUpdate else { return }
            // If IME composition is active, don't push partial text to SwiftUI binding
            if textView.markedTextRange != nil { return }
            parent.text = textView.text
        }

        // Update helper to rebuild attributed or plain text while preserving selection
        func updateTextView(_ textView: UITextView, with text: String, showFurigana: Bool, isEditable: Bool, allowTokenTap: Bool) {
            tapRecognizer?.isEnabled = allowTokenTap

            // If there is active IME composition, avoid replacing content
            if textView.markedTextRange != nil {
                textView.isEditable = !showFurigana && isEditable
                return
            }

            isProgrammaticUpdate = true
            defer { isProgrammaticUpdate = false }

            let selected = textView.selectedRange

            if showFurigana {
                let attributed: NSAttributedString
                if let base = parent.baseFontSize, let ruby = parent.rubyFontSize, let spacing = parent.lineSpacing {
                    attributed = JapaneseFuriganaBuilder.buildAttributedText(
                        text: text,
                        showFurigana: true,
                        baseFontSize: CGFloat(base),
                        rubyFontSize: CGFloat(ruby),
                        lineSpacing: CGFloat(spacing)
                    )
                } else {
                    attributed = JapaneseFuriganaBuilder.buildAttributedText(text: text, showFurigana: true)
                }
                textView.attributedText = attributed
                textView.isEditable = false
            } else {
                // Plain text mode: only assign if changed
                if textView.text != text {
                    textView.text = text
                }
                textView.textColor = .label

                let baseDefault = UIFont.preferredFont(forTextStyle: .body).pointSize
                let defaults = UserDefaults.standard
                let baseSize = defaults.object(forKey: "readingTextSize") as? Double ?? Double(baseDefault)
                let effectiveBaseSize = parent.baseFontSize ?? baseSize
                let desiredFont = UIFont.systemFont(ofSize: CGFloat(effectiveBaseSize))
                if textView.font?.pointSize != desiredFont.pointSize || textView.font?.fontName != desiredFont.fontName {
                    textView.font = desiredFont
                }
                textView.isEditable = isEditable
            }

            // Restore selection if still valid
            let max = (textView.text as NSString).length
            if selected.location <= max {
                textView.selectedRange = selected
            } else {
                textView.selectedRange = NSRange(location: max, length: 0)
            }
        }

        // MARK: Tap Handling
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = gesture.view as? UITextView else { return }
            let location = gesture.location(in: tv)

            // Determine character index at tap location
            guard let position = tv.closestPosition(to: location),
                  let range = tv.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue))
            else {
                // Fallback to layout manager mapping if tokenizer fails
                let lm = tv.layoutManager
                var point = location
                point.x -= tv.textContainerInset.left
                point.y -= tv.textContainerInset.top
                let glyphIndex = lm.glyphIndex(for: point, in: tv.textContainer)
                let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
                lookupToken(at: charIndex, in: tv.text)
                return
            }

            let start = tv.offset(from: tv.beginningOfDocument, to: range.start)
            lookupToken(at: start, in: tv.text)
        }

        private func lookupToken(at charIndex: Int, in fullText: String) {
            // Tokenize and find the annotation that contains the tapped index
            guard let tokenizer = try? Tokenizer(dictionary: IPADic()) else { return }
            let annotations = tokenizer.tokenize(text: fullText)

            for ann in annotations {
                let ns = NSRange(ann.range, in: fullText)
                if ns.location != NSNotFound,
                   charIndex >= ns.location,
                   charIndex < ns.location + ns.length {
                    let surface = String(fullText[ann.range])
                    let reading = ann.reading
                    let token = ParsedToken(surface: surface, reading: reading, meaning: nil)
                    parent.onTokenTap(token)
                    break
                }
            }
        }
    }
}

