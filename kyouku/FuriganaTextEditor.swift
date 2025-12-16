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

        // Improve selection look & feel
        tv.tintColor = UIColor(named: "AccentColor") ?? .systemBlue
        tv.keyboardDismissMode = .interactive
        tv.delaysContentTouches = false
        tv.canCancelContentTouches = true
        tv.layoutManager.allowsNonContiguousLayout = false

        // Disable smart substitutions to avoid conflicts with IME
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no

        // Tap recognizer to detect token taps
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = true
        context.coordinator.tapRecognizer = tap
        tv.addGestureRecognizer(tap)

        // Initial content
        context.coordinator.updateTextView(tv, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Ensure enough top inset for ruby annotations when furigana is on
        let currentInsets = uiView.textContainerInset
        let baseTop: CGFloat = 8
        if showFurigana {
            // Give extra room for ruby above the first line; use ruby size if provided
            let ruby = CGFloat(self.rubyFontSize ?? 10)
            let extraTop = ruby + 6 // small cushion above ruby
            let newTop = max(baseTop, extraTop)
            if abs(currentInsets.top - newTop) > 0.5 {
                uiView.textContainerInset = UIEdgeInsets(top: newTop, left: currentInsets.left, bottom: currentInsets.bottom, right: currentInsets.right)
            }
        } else {
            if abs(currentInsets.top - baseTop) > 0.5 {
                uiView.textContainerInset = UIEdgeInsets(top: baseTop, left: currentInsets.left, bottom: currentInsets.bottom, right: currentInsets.right)
            }
        }

        context.coordinator.updateTextView(uiView, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap)

        // Auto-focus when editable and not showing furigana; resign otherwise
        if !showFurigana && isEditable {
            if uiView.window != nil && !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: FuriganaTextEditor
        private var isProgrammaticUpdate = false
        var tapRecognizer: UITapGestureRecognizer?
        private var highlightedRange: NSRange? = nil
        private var buildWorkItem: DispatchWorkItem? = nil
        private var buildWorkItemID: UUID? = nil
        private var lastAppliedBuildKey: String? = nil
        private var pendingBuildKey: String? = nil
        private var lastBuildKey: String? = nil

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

            // Clear highlight when token taps are disabled or furigana is off
            if !showFurigana || !allowTokenTap {
                highlightedRange = nil
            }

            // If there is active IME composition, avoid replacing content
            if textView.markedTextRange != nil {
                textView.isEditable = !showFurigana && isEditable
                return
            }

            isProgrammaticUpdate = true
            defer { isProgrammaticUpdate = false }

            let selected = textView.selectedRange

            if showFurigana {
                // Lock editing while we build attributed content
                textView.isEditable = false

                // Capture inputs and compute a build key
                let currentText = text
                let hr = highlightedRange
                let base = parent.baseFontSize
                let ruby = parent.rubyFontSize
                let spacing = parent.lineSpacing

                let key = "\(currentText)|\(hr?.location ?? -1):\(hr?.length ?? -1)|\(base?.description ?? "nil")|\(ruby?.description ?? "nil")|\(spacing?.description ?? "nil")"

                // If we've already applied this exact build, skip
                if lastAppliedBuildKey == key, textView.attributedText != nil {
                    return
                }
                // If an identical build is already pending, let it finish
                if pendingBuildKey == key {
                    return
                }

                // Cancel any previous pending work now that we know we need a new build
                buildWorkItem?.cancel()

                let workID = UUID()
                self.buildWorkItemID = workID
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    let attributed: NSAttributedString
                    if let base = base, let ruby = ruby, let spacing = spacing {
                        attributed = JapaneseFuriganaBuilder.buildAttributedText(
                            text: currentText,
                            showFurigana: true,
                            baseFontSize: CGFloat(base),
                            rubyFontSize: CGFloat(ruby),
                            lineSpacing: CGFloat(spacing)
                        )
                    } else {
                        attributed = JapaneseFuriganaBuilder.buildAttributedText(text: currentText, showFurigana: true)
                    }
                    let mutable = NSMutableAttributedString(attributedString: attributed)
                    if let hr = hr, hr.location != NSNotFound, hr.location + hr.length <= mutable.length {
                        mutable.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), range: hr)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        // Ensure this result is still the most recent request
                        if self.buildWorkItemID != workID { return }
                        // Avoid stomping on active IME composition
                        if textView.markedTextRange != nil { return }

                        self.isProgrammaticUpdate = true
                        if hr != nil {
                            UIView.transition(with: textView, duration: 0.12, options: .transitionCrossDissolve, animations: {
                                textView.textStorage.setAttributedString(mutable)
                            }, completion: nil)
                        } else {
                            textView.textStorage.setAttributedString(mutable)
                        }
                        // Ensure layout reflects ruby annotations immediately
                        textView.layoutManager.ensureLayout(for: textView.textContainer)
                        textView.setNeedsLayout()
                        textView.layoutIfNeeded()
                        self.isProgrammaticUpdate = false
                        textView.isEditable = false

                        self.lastAppliedBuildKey = key
                        self.pendingBuildKey = nil

                        // Restore selection if still valid after applying attributed text
                        let max = (textView.text as NSString).length
                        if selected.location <= max {
                            textView.selectedRange = selected
                        } else {
                            textView.selectedRange = NSRange(location: max, length: 0)
                        }
                    }
                }
                pendingBuildKey = key
                buildWorkItem = work
                DispatchQueue.global(qos: .userInitiated).async(execute: work)
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
                highlightedRange = nil
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
                lookupToken(at: charIndex, in: tv.text, textView: tv)
                return
            }

            let start = tv.offset(from: tv.beginningOfDocument, to: range.start)
            lookupToken(at: start, in: tv.text, textView: tv)
        }

        private func lookupToken(at charIndex: Int, in fullText: String, textView: UITextView) {
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
                    highlightedRange = ns
                    updateTextView(textView, with: parent.text, showFurigana: parent.showFurigana, isEditable: parent.isEditable, allowTokenTap: parent.allowTokenTap)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    parent.onTokenTap(token)
                    break
                }
            }
        }
    }
}

