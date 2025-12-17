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
import OSLog

fileprivate let interactionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Interaction")

extension NSAttributedString.Key {
    static let tokenBackgroundColor = NSAttributedString.Key("TokenBackgroundColor")
}

final class RoundedBackgroundLayoutManager: NSLayoutManager {
    var cornerRadius: CGFloat = 5
    var horizontalPadding: CGFloat = 2
    var verticalPadding: CGFloat = 0.5

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage = self.textStorage, let textContainer = self.textContainers.first else { return }

        let fullLength = textStorage.length
        guard fullLength > 0 else { return }

        // Enumerate our custom background attribute across the visible glyph range
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.tokenBackgroundColor, in: characterRange, options: []) { value, range, _ in
            guard let color = value as? UIColor else { return }
            let highlightGlyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if highlightGlyphRange.length == 0 { return }

            // Draw per line fragment to avoid spanning across lines and to keep tight bounds
            self.enumerateLineFragments(forGlyphRange: highlightGlyphRange) { (rect, usedRect, container, glyphRange, stop) in
                let intersection = NSIntersectionRange(highlightGlyphRange, glyphRange)
                if intersection.length == 0 { return }

                let tight = self.boundingRect(forGlyphRange: intersection, in: container)
                var drawRect = tight.offsetBy(dx: origin.x, dy: origin.y)
                drawRect = drawRect.insetBy(dx: -self.horizontalPadding, dy: -self.verticalPadding)
                let path = UIBezierPath(roundedRect: drawRect, cornerRadius: self.cornerRadius)
                color.setFill()
                path.fill()
            }
        }
    }
}

struct FuriganaTextEditor: UIViewRepresentable {
    @Binding var text: String
    var showFurigana: Bool
    var isEditable: Bool = true
    var allowTokenTap: Bool = true
    var onTokenTap: (ParsedToken) -> Void
    var showSegmentHighlighting: Bool = true

    var baseFontSize: Double? = nil
    var rubyFontSize: Double? = nil
    var lineSpacing: Double? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        // Use a custom layout manager to draw rounded token backgrounds
        let textStorage = NSTextStorage()
        let layoutManager = RoundedBackgroundLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        let tv = UITextView(frame: .zero, textContainer: textContainer)

        tv.isEditable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        // Ensure the text container has sufficient height for multi-line layout and accurate hit-testing
        let initialWidth = max(0, tv.bounds.width - (tv.textContainerInset.left + tv.textContainerInset.right))
        textContainer.size = CGSize(width: initialWidth, height: .greatestFiniteMagnitude)

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
        tv.accessibilityIdentifier = "FuriganaTextEditorTextView"
        let grCount = tv.gestureRecognizers?.count ?? 0

        // Initial content
        context.coordinator.updateTextView(tv, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap, showSegmentHighlighting: showSegmentHighlighting)
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

        // Keep text container size in sync with view for accurate multi-line hit-testing
        let width = max(0, uiView.bounds.width - (uiView.textContainerInset.left + uiView.textContainerInset.right))
        if width > 0 {
            uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }

        context.coordinator.tapRecognizer?.isEnabled = allowTokenTap && showFurigana && !isEditable

        context.coordinator.updateTextView(uiView, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap, showSegmentHighlighting: showSegmentHighlighting)

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
        
        private var cachedSegments: [Segment] = []
        private var cachedSegmentsKey: String = ""

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
        func updateTextView(_ textView: UITextView, with text: String, showFurigana: Bool, isEditable: Bool, allowTokenTap: Bool, showSegmentHighlighting: Bool) {
            tapRecognizer?.isEnabled = allowTokenTap && showFurigana && !isEditable

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
                    let segs = self.segments(for: currentText)
                    let segmentsArg: [Segment]? = segs.isEmpty ? nil : segs
                    if let base = base, let ruby = ruby, let spacing = spacing {
                        attributed = JapaneseFuriganaBuilder.buildAttributedText(
                            text: currentText,
                            showFurigana: true,
                            baseFontSize: CGFloat(base),
                            rubyFontSize: CGFloat(ruby),
                            lineSpacing: CGFloat(spacing),
                            segments: segmentsArg
                        )
                    } else {
                        if let segsNonEmpty = segmentsArg {
                            attributed = JapaneseFuriganaBuilder.buildAttributedText(text: currentText, showFurigana: true, segments: segsNonEmpty)
                        } else {
                            attributed = JapaneseFuriganaBuilder.buildAttributedText(text: currentText, showFurigana: true)
                        }
                    }
                    let mutable = NSMutableAttributedString(attributedString: attributed)
                    if !isEditable && showSegmentHighlighting {
                        applySegmentShading(to: mutable, baseText: currentText)
                    }
                    if let hr = hr, hr.location != NSNotFound, hr.location + hr.length <= mutable.length {
                        mutable.addAttribute(.tokenBackgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: hr)
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
                textView.textColor = .label

                let baseDefault = UIFont.preferredFont(forTextStyle: .body).pointSize
                let defaults = UserDefaults.standard
                let baseSize = defaults.object(forKey: "readingTextSize") as? Double ?? Double(baseDefault)
                let effectiveBaseSize = parent.baseFontSize ?? baseSize
                let desiredFont = UIFont.systemFont(ofSize: CGFloat(effectiveBaseSize))

                if isEditable {
                    if textView.text != text {
                        textView.text = text
                    }
                    if textView.font?.pointSize != desiredFont.pointSize || textView.font?.fontName != desiredFont.fontName {
                        textView.font = desiredFont
                    }
                    textView.isEditable = true
                    highlightedRange = nil
                } else {
                    let baseAttributes: [NSAttributedString.Key: Any] = [
                        .font: desiredFont,
                        .foregroundColor: UIColor.label
                    ]
                    let mutable = NSMutableAttributedString(string: text, attributes: baseAttributes)
                    if showSegmentHighlighting {
                        applySegmentShading(to: mutable, baseText: text)
                    }
                    textView.attributedText = mutable
                    textView.isEditable = false
                    highlightedRange = nil
                }
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
            let rawPoint = gesture.location(in: tv)
            var point = CGPoint(x: rawPoint.x - tv.textContainerInset.left,
                                y: rawPoint.y - tv.textContainerInset.top)

            let lm = tv.layoutManager
            let container = tv.textContainer

            // Resolve to a character index using TextKit mapping in container coordinates
            let charIndex = lm.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            
            lookupToken(at: charIndex, in: tv.text, textView: tv)
        }

        private func lookupToken(at charIndex: Int, in fullText: String, textView: UITextView) {
            let nsText = fullText as NSString
            let nsLen = nsText.length
            guard nsLen > 0 else { return }
            let idx = max(0, min(charIndex, nsLen - 1))

            let segs = segments(for: fullText)

            // Try direct NSRange containment first to avoid String.Index cross-string issues
            for (i, seg) in segs.enumerated() {
                let ns = NSRange(seg.range, in: fullText)
                guard ns.location != NSNotFound else { continue }
                if idx >= ns.location && idx < ns.location + ns.length {
                    select(seg: seg, fullText: fullText, textView: textView)
                    return
                }
            }

            // If no direct match (e.g., tapped exactly on a boundary), bias left then right
            if idx > 0 {
                let left = idx - 1
                for (i, seg) in segs.enumerated() {
                    let ns = NSRange(seg.range, in: fullText)
                    guard ns.location != NSNotFound else { continue }
                    if left >= ns.location && left < ns.location + ns.length {
                        select(seg: seg, fullText: fullText, textView: textView)
                        return
                    }
                }
            }

            if idx + 1 < nsLen {
                let right = idx + 1
                for (i, seg) in segs.enumerated() {
                    let ns = NSRange(seg.range, in: fullText)
                    guard ns.location != NSNotFound else { continue }
                    if right >= ns.location && right < ns.location + ns.length {
                        select(seg: seg, fullText: fullText, textView: textView)
                        return
                    }
                }
            }
        }

        private func select(seg: Segment, fullText: String, textView: UITextView) {
            // Compute the index of the selected segment within the current segmentation
            let segs = segments(for: fullText)
            let idx = segs.firstIndex(where: { $0.range == seg.range }) ?? -1

            let ns = NSRange(seg.range, in: fullText)
            let nsText = fullText as NSString
            let line: Int = {
                if ns.location != NSNotFound {
                    let prefix = nsText.substring(to: ns.location)
                    return prefix.filter { $0 == "\n" }.count
                } else { return -1 }
            }()

            let surface = seg.surface
            let reading = SegmentReadingAttacher.reading(for: surface, tokenizer: TokenizerFactory.make() ?? (try? Tokenizer(dictionary: IPADic())))
            let token = ParsedToken(surface: surface, reading: reading, meaning: nil)

            interactionLogger.info("Resolved tap to segment: index=\(idx), line=\(line), surface='\(surface, privacy: .public)', reading='\(reading, privacy: .public)'")

            highlightedRange = ns
            updateTextView(textView, with: fullText, showFurigana: parent.showFurigana, isEditable: parent.isEditable, allowTokenTap: parent.allowTokenTap, showSegmentHighlighting: parent.showSegmentHighlighting)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onTokenTap(token)
        }
        
        private func applySegmentShading(to attributed: NSMutableAttributedString, baseText: String) {
            let segments = segments(for: baseText)
            for (i, seg) in segments.enumerated() {
                let nsRange = NSRange(seg.range, in: baseText)
                if nsRange.location == NSNotFound { continue }
                let color: UIColor = (i % 2 == 0)
                    ? UIColor.systemMint.withAlphaComponent(0.24)
                    : UIColor.systemYellow.withAlphaComponent(0.30)
                attributed.addAttribute(.tokenBackgroundColor, value: color, range: nsRange)
            }
        }
        
        private func segments(for text: String) -> [Segment] {
            guard let trie = JMdictTrieCache.shared else { return [] }
            let key = text
            if key == cachedSegmentsKey { return cachedSegments }
            let segs = DictionarySegmenter.segment(text: text, trie: trie)
            cachedSegments = segs
            cachedSegmentsKey = key
            return segs
        }
    }
}

private extension String {
    func index(_ i: Index, offsetByUTF16 offset: Int) -> Index? {
        let utf16 = self.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex) else { return nil }
        guard let scalarIndex = String.Index(start, within: self) else { return nil }
        return scalarIndex
    }
}

