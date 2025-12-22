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
import CoreFoundation
import CoreText

fileprivate let interactionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Interaction")

extension NSAttributedString.Key {
    static let tokenBackgroundColor = NSAttributedString.Key("TokenBackgroundColor")
}

extension NSAttributedString.Key {
    static let rubyReading = NSAttributedString.Key("RubyReading")
}

struct ReadingOverride: Equatable {
    let range: NSRange
    let reading: String
}

final class RoundedBackgroundLayoutManager: NSLayoutManager {
    var cornerRadius: CGFloat = 5
    var interTokenGap: CGFloat = 0.75

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage = self.textStorage, let _ = self.textContainers.first else { return }

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

                // Use the glyph bounding rect to avoid including ruby (furigana) vertical space.
                // Add a tiny vertical inset for aesthetics.
                let verticalPad: CGFloat = 1.0
                if drawRect.height > verticalPad * 2 {
                    drawRect = drawRect.insetBy(dx: 0, dy: verticalPad)
                }

                // Clamp vertically to the current line fragment's used rect to avoid overflow.
                let lineRect = usedRect.offsetBy(dx: origin.x, dy: origin.y)
                if drawRect.minY < lineRect.minY { drawRect.origin.y = lineRect.minY }
                if drawRect.maxY > lineRect.maxY { drawRect.size.height = max(0, lineRect.maxY - drawRect.minY) }

                if drawRect.width <= 0 || drawRect.height <= 0 { return }

                // Add a small horizontal gap to keep rounded corners from touching neighbors.
                let horizontalPad: CGFloat = 1.0
                if drawRect.width > horizontalPad * 2 {
                    drawRect = drawRect.insetBy(dx: horizontalPad, dy: 0)
                }

                if drawRect.minX < lineRect.minX {
                    let delta = lineRect.minX - drawRect.minX
                    drawRect.origin.x += delta
                    drawRect.size.width -= delta
                }
                if drawRect.maxX > lineRect.maxX {
                    let delta = drawRect.maxX - lineRect.maxX
                    drawRect.size.width -= delta
                }
                if drawRect.width <= 0 || drawRect.height <= 0 { return }
                let radius = min(self.cornerRadius, drawRect.height / 2, drawRect.width / 2)
                let path = UIBezierPath(roundedRect: drawRect, cornerRadius: radius)
                color.setFill()
                path.fill()
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Draw base glyphs first
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        // Then draw ruby readings on top so they aren't occluded by glyphs
        guard let textStorage = self.textStorage, let _ = self.textContainers.first else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.rubyReading, in: characterRange, options: []) { value, range, _ in
            guard let reading = value as? String, !reading.isEmpty else { return }
            let readingGlyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if readingGlyphRange.length == 0 { return }

            self.enumerateLineFragments(forGlyphRange: readingGlyphRange) { (rect, usedRect, container, glyphRange, stop) in
                let intersection = NSIntersectionRange(readingGlyphRange, glyphRange)
                if intersection.length == 0 { return }

                let tight = self.boundingRect(forGlyphRange: intersection, in: container)
                let drawRect = tight.offsetBy(dx: origin.x, dy: origin.y)

                // Determine a small font relative to the base font at this location
                var rubyFont: UIFont = .systemFont(ofSize: 9)
                let attrs = textStorage.attributes(at: range.location, effectiveRange: nil)
                if let base = attrs[.font] as? UIFont {
                    rubyFont = base.withSize(max(6, base.pointSize * 0.55))
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attrsDraw: [NSAttributedString.Key: Any] = [
                    .font: rubyFont,
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraph
                ]
                let size = (reading as NSString).size(withAttributes: attrsDraw)
                // Center above the base segment and add a small gap
                let gap: CGFloat = 2
                let originPoint = CGPoint(x: drawRect.midX - size.width / 2, y: drawRect.minY - size.height - gap)
                (reading as NSString).draw(at: originPoint, withAttributes: attrsDraw)
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
    var onSelectionCleared: () -> Void = {}
    var showSegmentHighlighting: Bool = true
    var perKanjiSplit: Bool = true

    var baseFontSize: Double? = nil
    var rubyFontSize: Double? = nil
    var lineSpacing: Double? = nil

    var readingOverrides: [ReadingOverride] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        // Use a custom layout manager to draw rounded token backgrounds
        let textStorage = NSTextStorage()
        let layoutManager = RoundedBackgroundLayoutManager()
        let _ = NSTextContainer(size: .zero)
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
        _ = tv.gestureRecognizers?.count ?? 0

        NotificationCenter.default.addObserver(forName: .customTokenizerLexiconDidChange, object: nil, queue: .main) { _ in
            context.coordinator.invalidateSegmentCache()
        }

        // Initial content
        context.coordinator.updateTextView(tv, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap, showSegmentHighlighting: showSegmentHighlighting, perKanjiSplit: perKanjiSplit, readingOverrides: self.readingOverrides)
        DispatchQueue.main.async {
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            tv.setNeedsLayout()
            tv.layoutIfNeeded()
        }
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
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)

        // Keep text container size in sync with view for accurate multi-line hit-testing
        let width = max(0, uiView.bounds.width - (uiView.textContainerInset.left + uiView.textContainerInset.right))
        if width > 0 {
            uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }

        context.coordinator.tapRecognizer?.isEnabled = allowTokenTap && !isEditable

        context.coordinator.updateTextView(uiView, with: text, showFurigana: showFurigana, isEditable: isEditable, allowTokenTap: allowTokenTap, showSegmentHighlighting: showSegmentHighlighting, perKanjiSplit: perKanjiSplit, readingOverrides: self.readingOverrides)

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
        
        func invalidateSegmentCache() {
            cachedSegments = []
            cachedSegmentsKey = ""
        }

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
        func updateTextView(_ textView: UITextView, with text: String, showFurigana: Bool, isEditable: Bool, allowTokenTap: Bool, showSegmentHighlighting: Bool, perKanjiSplit: Bool, readingOverrides: [ReadingOverride]) {
            tapRecognizer?.isEnabled = allowTokenTap && !isEditable

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

                // Initialize highlight to the first segment on first display when tapping is enabled
                if highlightedRange == nil && allowTokenTap {
                    let segsInit = self.segments(for: currentText)
                    if let first = segsInit.first {
                        let nsFirst = NSRange(first.range, in: currentText)
                        if nsFirst.location != NSNotFound {
                            self.highlightedRange = nsFirst
                        }
                    }
                }

                let hr = highlightedRange
                let base = parent.baseFontSize
                let ruby = parent.rubyFontSize
                let spacing = parent.lineSpacing

                let overridesKey = readingOverrides.map { "\($0.range.location):\($0.range.length)=\($0.reading)" }.joined(separator: "|")
                let key = "\(currentText)|\(hr?.location ?? -1):\(hr?.length ?? -1)|\(base?.description ?? "nil")|\(ruby?.description ?? "nil")|\(spacing?.description ?? "nil")|\(overridesKey)"

                // If we've already applied this exact build, skip
                if lastAppliedBuildKey == key, !(textView.attributedText?.string.isEmpty ?? true) {
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
                            segments: segmentsArg,
                            perKanjiSplit: perKanjiSplit
                        )
                    } else {
                        if let segsNonEmpty = segmentsArg {
                            attributed = JapaneseFuriganaBuilder.buildAttributedText(text: currentText, showFurigana: true, segments: segsNonEmpty, perKanjiSplit: perKanjiSplit)
                        } else {
                            attributed = JapaneseFuriganaBuilder.buildAttributedText(text: currentText, showFurigana: true, perKanjiSplit: perKanjiSplit)
                        }
                    }
                    let mutable = NSMutableAttributedString(attributedString: attributed)
                    // iOS 17 simulator/workaround: CTRuby on UITextView can cause text to disappear.
                    if #available(iOS 18.0, *) {
                        // Keep CTRuby annotations on iOS 18+
                    } else {
                        mutable.removeAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), range: NSRange(location: 0, length: mutable.length))
                    }
                    if !isEditable && showSegmentHighlighting {
                        applySegmentShading(to: mutable, baseText: currentText)
                    }
                    // Always apply the yellow highlight if hr is valid, regardless of showSegmentHighlighting
                    if let hr = hr, hr.location != NSNotFound, hr.location + hr.length <= mutable.length {
                        mutable.addAttribute(.tokenBackgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: hr)
                    }
                    for ov in readingOverrides {
                        let r = ov.range
                        if r.location != NSNotFound, r.location + r.length <= mutable.length, !ov.reading.isEmpty {
                            mutable.addAttribute(.rubyReading, value: ov.reading, range: r)
                        }
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
                    // Always apply the yellow highlight if hr is valid, regardless of showSegmentHighlighting
                    if let hr = highlightedRange, hr.location != NSNotFound, hr.location + hr.length <= mutable.length {
                        mutable.addAttribute(.tokenBackgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: hr)
                    }
                    textView.attributedText = mutable
                    textView.isEditable = false
                }

                // Force the next furigana build to refresh when toggled back on.
                lastAppliedBuildKey = nil
                pendingBuildKey = nil
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

            let point = CGPoint(x: rawPoint.x - tv.textContainerInset.left,
                                y: rawPoint.y - tv.textContainerInset.top)

            let lm = tv.layoutManager
            let container = tv.textContainer

            // If tap is outside the laid-out text area, clear selection
            let used = lm.usedRect(for: container)
            let withinX = point.x >= 0 && point.x <= container.size.width
            let withinY = point.y >= 0 && point.y <= used.maxY
            if !(withinX && withinY) {
                clearSelection(fullText: tv.text, textView: tv)
                return
            }

            lookupToken(at: lm.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil), in: tv.text, textView: tv, tapPoint: point)
        }

        private func lookupToken(at charIndex: Int, in fullText: String, textView: UITextView, tapPoint: CGPoint) {
            let nsText = fullText as NSString
            let nsLen = nsText.length
            guard nsLen > 0 else { return }
            let idx = max(0, min(charIndex, nsLen - 1))

            let segs = segments(for: fullText)

            let lm = textView.layoutManager
            let container = textView.textContainer

            // Hit-test: only select a segment if the tap falls within its glyph bounding rect
            for seg in segs {
                let ns = NSRange(seg.range, in: fullText)
                guard ns.location != NSNotFound else { continue }
                if idx >= ns.location && idx < ns.location + ns.length {
                    let glyphRange = lm.glyphRange(forCharacterRange: ns, actualCharacterRange: nil)
                    if glyphRange.length == 0 { continue }
                    let tight = lm.boundingRect(forGlyphRange: glyphRange, in: container)
                    // Add a small padding to make taps near edges more forgiving
                    let padded = tight.insetBy(dx: -3, dy: -2)
                    if padded.contains(tapPoint) {
                        select(seg: seg, fullText: fullText, textView: textView)
                        return
                    }
                }
            }

            // No hit on any segment: clear selection
            clearSelection(fullText: fullText, textView: textView)
        }

        private func select(seg: Segment, fullText: String, textView: UITextView) {
            // Compute the index of the selected segment within the current segmentation
            let segs = segments(for: fullText)
            _ = segs.firstIndex(where: { $0.range == seg.range }) ?? -1

            let ns = NSRange(seg.range, in: fullText)
            let nsText = fullText as NSString
            let line: Int = {
                if ns.location != NSNotFound {
                    let prefix = nsText.substring(to: ns.location)
                    return prefix.filter { $0 == "\n" }.count
                } else { return -1 }
            }()

            let surface = seg.surface
            let readingFromAttr = textView.textStorage.attribute(.rubyReading, at: ns.location, effectiveRange: nil) as? String
            var reading = (readingFromAttr?.isEmpty == false) ? readingFromAttr! : SegmentReadingAttacher.reading(for: surface, tokenizer: try? Tokenizer(dictionary: IPADic()))
            if surface.isKatakanaWord {
                if reading.isEmpty {
                    reading = surface
                } else {
                    reading = reading.katakanaTransformed()
                }
            }

            let token = ParsedToken(surface: surface, reading: reading, meaning: nil, range: ns)

            interactionLogger.info("FuriganaTextEditor: Resolved tap to segment, index=\(line), line=\(line), surface='\(surface, privacy: .public)', reading='\(reading, privacy: .public)'")

            highlightedRange = ns

            updateTextView(textView, with: fullText, showFurigana: parent.showFurigana, isEditable: parent.isEditable, allowTokenTap: parent.allowTokenTap, showSegmentHighlighting: parent.showSegmentHighlighting, perKanjiSplit: parent.perKanjiSplit, readingOverrides: parent.readingOverrides)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onTokenTap(token)
        }

        private func clearSelection(fullText: String, textView: UITextView) {
            let hadHighlight = highlightedRange != nil
            highlightedRange = nil
            if hadHighlight {
                updateTextView(textView, with: fullText, showFurigana: parent.showFurigana, isEditable: parent.isEditable, allowTokenTap: parent.allowTokenTap, showSegmentHighlighting: parent.showSegmentHighlighting, perKanjiSplit: parent.perKanjiSplit, readingOverrides: parent.readingOverrides)
            }
            parent.onSelectionCleared()
        }
        
        private func applySegmentShading(to attributed: NSMutableAttributedString, baseText: String) {
            let segments = segments(for: baseText)
            for (idx, seg) in segments.enumerated() {
                let nsRange = NSRange(seg.range, in: baseText)
                if nsRange.location == NSNotFound { continue }
                let color: UIColor = (idx % 2 == 0)
                    ? UIColor.systemRed.withAlphaComponent(0.24)
                    : UIColor.systemBlue.withAlphaComponent(0.28)
                attributed.addAttribute(.tokenBackgroundColor, value: color, range: nsRange)
            }
        }
        
        private func segments(for text: String) -> [Segment] {
            let engine = SegmentationEngine.current()
            let cacheKey = "\(engine.rawValue)|\(text)"
            if cacheKey == cachedSegmentsKey {
                return cachedSegments
            }

            let segs: [Segment]
            switch engine {
            case .dictionaryTrie:
                if let trie = TrieCache.shared {
                    segs = DictionarySegmenter.segment(text: text, trie: trie)
                } else {
                    segs = AppleSegmenter.segment(text: text)
                }
            case .appleTokenizer:
                segs = AppleSegmenter.segment(text: text)
            }

            cachedSegments = segs
            cachedSegmentsKey = cacheKey
            return segs
        }
        
        // Merge the segment containing `boundaryLeft` with the segment immediately to its right, if contiguous.
        func mergeAtBoundary(text: String, boundaryLeft: Int) -> String? {
            let segs = segments(for: text)
            guard !segs.isEmpty else { return nil }
            // Find the left segment whose upperBound (in UTF16) equals boundaryLeft
            for (i, s) in segs.enumerated() {
                let ns = NSRange(s.range, in: text)
                guard ns.location != NSNotFound else { continue }
                if ns.location + ns.length == boundaryLeft {
                    // Ensure there is a right neighbor and that they are contiguous
                    guard i + 1 < segs.count else { return nil }
                    let right = segs[i + 1]
                    let nsRight = NSRange(right.range, in: text)
                    guard nsRight.location == boundaryLeft else { return nil }
                    // Build new text by replacing the two ranges with their concatenation (which is effectively the same substring),
                    // but we will add the combined surface to the custom lexicon so future segmentations keep them as one token.
                    // Here, we simply return the original text because surface text doesn't change; caller will update lexicon.
                    return text
                }
            }
            return nil
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

    var isKatakanaWord: Bool {
        let filtered = unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !filtered.isEmpty else { return false }
        var sawSyllable = false
        for scalar in filtered {
            let value = scalar.value
            if value == 0x30FC || value == 0x30FB { continue } // prolong mark or middle dot
            if (0x30A0...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) {
                sawSyllable = true
                continue
            }
            return false
        }
        return sawSyllable
    }

    func katakanaTransformed() -> String {
        guard !isEmpty else { return self }
        let mutable = NSMutableString(string: self)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, false)
        return mutable as String
    }
}

