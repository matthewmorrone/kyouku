import SwiftUI
import UIKit

struct FuriganaRenderingHost: View {
    @Binding var text: String
    var furiganaText: NSAttributedString?
    var furiganaSpans: [AnnotatedSpan]?
    var semanticSpans: [SemanticSpan]
    var textSize: Double
    var isEditing: Bool
    var showFurigana: Bool
    var lineSpacing: Double
    var alternateTokenColors: Bool
    var highlightUnknownTokens: Bool
    var tokenPalette: [UIColor]
    var unknownTokenColor: UIColor
    var selectedRangeHighlight: NSRange?
    var customizedRanges: [NSRange]
    var extraTokenOverlays: [RubyText.TokenOverlay] = []
    var enableTapInspection: Bool = true
    var bottomOverscrollPadding: CGFloat = 0
    var onCharacterTap: ((Int) -> Void)? = nil
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var enableDragSelection: Bool = false
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let halfWidth = max(1, proxy.size.width * 0.5)
            HStack(spacing: 0) {
                Group {
                    if text.isEmpty {
                        EmptyView()
                    } else {
                        rubyBlock(annotationVisibility: showFurigana ? .visible : .removed)
                    }
                }
                .frame(width: halfWidth, alignment: .topLeading)

                Divider()

                editorContent
                    .frame(width: max(1, proxy.size.width - halfWidth), alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color(.systemBackground))
        .cornerRadius(12)
        .roundedBorder(Color(.white), cornerRadius: 12)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            EditingTextView(
                text: $text,
                isEditable: isEditing,
                fontSize: CGFloat(textSize),
                lineSpacing: CGFloat(lineSpacing),
                insets: UIEdgeInsets(
                    top: editorInsets.top,
                    left: editorInsets.leading,
                    bottom: editorInsets.bottom,
                    right: editorInsets.trailing
                )
            )
            .padding(0)
        }
    }

    private var editorInsets: EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let topInset = max(8.0, rubyHeadroom)

        // Compute symmetric horizontal overhang to match view mode ruby behavior.
        // Use the same helper RubyText uses so edit/view modes align.
        let attributed = furiganaText ?? NSAttributedString(string: text)
        let baseFont = UIFont.systemFont(ofSize: CGFloat(textSize))
        let defaultRubyFontSize = max(1.0, CGFloat(textSize) * 0.6)
        let rawOverhang = RubyText.requiredHorizontalInsetForRubyOverhang(
            in: attributed,
            baseFont: baseFont,
            defaultRubyFontSize: defaultRubyFontSize
        )
        let insetOverhang = max(ceil(rawOverhang), 2)
        let left = 12 + insetOverhang
        let right = 12 + insetOverhang
        return EdgeInsets(
            top: CGFloat(topInset),
            leading: CGFloat(left),
            bottom: CGFloat(12 + bottomOverscrollPadding),
            trailing: CGFloat(right)
        )
    }

    private func rubyBlock(annotationVisibility: RubyAnnotationVisibility) -> some View {
        let attributed = resolvedAttributedText
        let baseFont = UIFont.systemFont(ofSize: CGFloat(textSize))
        let defaultRubyFontSize = max(1, CGFloat(textSize) * 0.6)
        let rawOverhang = RubyText.requiredHorizontalInsetForRubyOverhang(
            in: attributed,
            baseFont: baseFont,
            defaultRubyFontSize: defaultRubyFontSize
        )
        let insetOverhang = max(ceil(rawOverhang), 2)
        let insets = UIEdgeInsets(
            top: 8,
            left: 12 + insetOverhang,
            bottom: 12 + bottomOverscrollPadding,
            right: 12 + insetOverhang
        )

        return RubyText(
            attributed: attributed,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            textInsets: insets,
            annotationVisibility: annotationVisibility,
            isScrollEnabled: true,
            allowSystemTextSelection: false,
            wrapLines: false,
            horizontalScrollEnabled: true,
            tokenOverlays: tokenColorOverlays,
            semanticSpans: semanticSpans,
            selectedRange: selectedRangeHighlight,
            customizedRanges: customizedRanges,
            enableTapInspection: enableTapInspection,
            enableDragSelection: enableDragSelection,
            onDragSelectionBegan: onDragSelectionBegan,
            onDragSelectionEnded: onDragSelectionEnded,
            onCharacterTap: onCharacterTap,
            onSpanSelection: onSpanSelection,
            contextMenuStateProvider: contextMenuStateProvider,
            onContextMenuAction: onContextMenuAction
        )
        // `RubyText` performs custom drawing for ruby annotations. When token overlay modes
        // toggle, UIKit doesn't always repaint the custom ruby layer immediately, so we
        // include overlay mode in the view identity to force a refresh.
        // IMPORTANT: do not include `annotationVisibility` in the identity, otherwise
        // toggling furigana recreates the view and resets the ScrollView to the top.
        .id(rubyViewIdentity())
        .frame(minHeight: 40, alignment: .topLeading)
    }

    private func rubyViewIdentity() -> String {
        // Keep this intentionally narrow to avoid unnecessary view re-creation.
        // This identity is used only to force refreshes when overlay modes change.
        let overlayMode = (alternateTokenColors ? 1 : 0) | (highlightUnknownTokens ? 2 : 0)
        return "ruby-overlay-\(overlayMode)"
    }

    private var resolvedAttributedText: NSAttributedString {
        furiganaText ?? NSAttributedString(string: text)
    }

    private var tokenColorOverlays: [RubyText.TokenOverlay] {
        let wantsTokenColors = (alternateTokenColors || highlightUnknownTokens)
        if wantsTokenColors == false {
            return extraTokenOverlays
        }
        guard semanticSpans.isEmpty == false else { return extraTokenOverlays }
        let backingString = furiganaText?.string ?? text
        let textStorage = backingString as NSString
        var overlays: [RubyText.TokenOverlay] = []

        if alternateTokenColors {
            let palette = tokenPalette.filter { $0.cgColor.alpha > 0 }
            if palette.isEmpty == false {
                let coverageRanges = Self.coverageRanges(from: semanticSpans, textStorage: textStorage)
                overlays.reserveCapacity(coverageRanges.count)
                for (index, range) in coverageRanges.enumerated() {
                    let color = palette[index % palette.count]
                    overlays.append(RubyText.TokenOverlay(range: range, color: color))
                }
            }
        }

        if highlightUnknownTokens {
            let unknowns = Self.unknownTokenOverlays(from: semanticSpans, annotatedSpans: furiganaSpans ?? [], textStorage: textStorage, color: unknownTokenColor)
            overlays.append(contentsOf: unknowns)
        }

        if extraTokenOverlays.isEmpty == false {
            overlays.append(contentsOf: extraTokenOverlays)
        }
        return overlays
    }

    private static func coverageRanges(from spans: [SemanticSpan], textStorage: NSString) -> [NSRange] {
        let textLength = textStorage.length
        guard textLength > 0 else { return [] }
        let bounds = NSRange(location: 0, length: textLength)
        let sorted = spans
            .map { $0.range }
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .map { NSIntersectionRange($0, bounds) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(sorted.count + 4)
        var cursor = 0
        for range in sorted {
            if range.location > cursor {
                let gap = NSRange(location: cursor, length: range.location - cursor)
                if containsNonWhitespace(in: gap, textStorage: textStorage) {
                    ranges.append(gap)
                }
            }
            ranges.append(range)
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < textLength {
            let trailing = NSRange(location: cursor, length: textLength - cursor)
            if containsNonWhitespace(in: trailing, textStorage: textStorage) {
                ranges.append(trailing)
            }
        }
        return ranges
    }

    private static func containsNonWhitespace(in range: NSRange, textStorage: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let substring = textStorage.substring(with: range)
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func clampRange(_ range: NSRange, length: Int) -> NSRange? {
        guard length > 0 else { return nil }
        let bounds = NSRange(location: 0, length: length)
        let clamped = NSIntersectionRange(range, bounds)
        return clamped.length > 0 ? clamped : nil
    }

    private static func unknownTokenOverlays(
        from semanticSpans: [SemanticSpan],
        annotatedSpans: [AnnotatedSpan],
        textStorage: NSString,
        color: UIColor
    ) -> [RubyText.TokenOverlay] {
        guard textStorage.length > 0 else { return [] }
        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(semanticSpans.count)

        for semantic in semanticSpans {
            let indices = semantic.sourceSpanIndices
            guard indices.isEmpty == false else { continue }
            guard indices.lowerBound >= 0, indices.upperBound <= annotatedSpans.count else { continue }
            let group = annotatedSpans[indices.lowerBound..<indices.upperBound]

            // "Unknown" should mean we failed to get any lexical signal for the *entire semantic token*.
            // Preserve the existing per-span criteria, but apply it across the semantic group.
            let isUnknown = group.allSatisfy { $0.lemmaCandidates.isEmpty && $0.span.isLexiconMatch == false }
            guard isUnknown else { continue }

            guard let clamped = Self.clampRange(semantic.range, length: textStorage.length) else { continue }
            if containsNonWhitespace(in: clamped, textStorage: textStorage) == false { continue }
            overlays.append(RubyText.TokenOverlay(range: clamped, color: color))
        }

        return overlays
    }
}

private struct EditingTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = isEditable
        view.delegate = context.coordinator
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.showsHorizontalScrollIndicator = true
        view.textContainer.widthTracksTextView = false
        view.textContainer.maximumNumberOfLines = 0
        view.textContainer.lineBreakMode = .byClipping
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = insets
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.delegate = context.coordinator
        view.font = UIFont.systemFont(ofSize: fontSize)
        view.textColor = UIColor.label

        view.textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)
        
        // Build attributed text from the same source as view mode, but remove ruby for editing.
        let baseAttributed = NSAttributedString(string: text)
        let processed = Self.removingRuby(from: baseAttributed)
        let fullRange = NSRange(location: 0, length: (processed.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineHeightMultiple = max(0.8, 1.0)
        paragraph.lineSpacing = max(0, lineSpacing)
        let baseFont = UIFont.systemFont(ofSize: fontSize)
        let colored = NSMutableAttributedString(attributedString: processed)
        colored.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: fullRange)
        colored.addAttribute(NSAttributedString.Key.foregroundColor, value: UIColor.label, range: fullRange)
        colored.addAttribute(NSAttributedString.Key.font, value: baseFont, range: fullRange)
        view.attributedText = colored

        // Apply paragraph style immediately so the first layout matches view mode metrics.
        let initialLength = view.textStorage.length
        if initialLength > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            view.textStorage.addAttributes([
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.foregroundColor: UIColor.label,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: fontSize)
            ], range: NSRange(location: 0, length: initialLength))
        }

        view.contentInset = .zero
        view.verticalScrollIndicatorInsets = .zero
        view.horizontalScrollIndicatorInsets = .zero
        if #available(iOS 11.0, *) {
            view.contentInsetAdjustmentBehavior = .never
        }

        applyTypingAttributes(to: view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        do {
            let baseAttributed = NSAttributedString(string: text)
            let processed = Self.removingRuby(from: baseAttributed)
            let fullRange = NSRange(location: 0, length: processed.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            let baseFont = UIFont.systemFont(ofSize: fontSize)
            let colored = NSMutableAttributedString(attributedString: processed)
            colored.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: fullRange)
            colored.addAttribute(NSAttributedString.Key.foregroundColor, value: UIColor.label, range: fullRange)
            colored.addAttribute(NSAttributedString.Key.font, value: baseFont, range: fullRange)
            if uiView.attributedText?.isEqual(to: colored) == false {
                let wasFirstResponder = uiView.isFirstResponder
                let oldSelectedRange = uiView.selectedRange
                uiView.attributedText = colored
                if wasFirstResponder {
                    _ = uiView.becomeFirstResponder()
                    let newLength = uiView.attributedText?.length ?? 0
                    if oldSelectedRange.location != NSNotFound, NSMaxRange(oldSelectedRange) <= newLength {
                        uiView.selectedRange = oldSelectedRange
                    }
                }
            }
        }

        uiView.isEditable = isEditable
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = UIColor.label
        uiView.textContainerInset = insets
        uiView.alwaysBounceHorizontal = true
        uiView.showsHorizontalScrollIndicator = true
        uiView.textContainer.widthTracksTextView = false
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = .byClipping
        uiView.textContainer.lineFragmentPadding = 0

        if uiView.textContainer.size.width < 20000 {
            uiView.textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)
        }

        uiView.contentInset = .zero
        uiView.verticalScrollIndicatorInsets = .zero
        uiView.horizontalScrollIndicatorInsets = .zero
        if #available(iOS 11.0, *) {
            uiView.contentInsetAdjustmentBehavior = .never
        }

        // Apply paragraph style to the full text to ensure wrapping/spacing match view mode.
        let fullLength = uiView.textStorage.length
        if fullLength > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            uiView.textStorage.addAttributes([
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.foregroundColor: UIColor.label,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: fontSize)
            ], range: NSRange(location: 0, length: fullLength))
        }

        applyTypingAttributes(to: uiView)
    }

    static func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize {
        let resolvedWidth: CGFloat = {
            if let width = proposal.width, width.isFinite, width > 0 {
                return width
            }
            if uiView.bounds.width.isFinite, uiView.bounds.width > 0 {
                return uiView.bounds.width
            }
            if let screen = uiView.window?.windowScene?.screen {
                return screen.bounds.width
            }
            return 320 // reasonable fallback width when no context is available
        }()

        let resolvedHeight: CGFloat = {
            if let height = proposal.height, height.isFinite, height > 0 {
                return height
            }
            if uiView.bounds.height.isFinite, uiView.bounds.height > 0 {
                return uiView.bounds.height
            }
            if let screen = uiView.window?.windowScene?.screen {
                // Use a small default height relative to screen to avoid zero sizing
                return max(10, screen.bounds.height * 0.1)
            }
            return 10
        }()

        return CGSize(width: resolvedWidth, height: resolvedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private func applyTypingAttributes(to textView: UITextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, lineSpacing)
        textView.typingAttributes = [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: fontSize),
            NSAttributedString.Key.foregroundColor: UIColor.label,
            NSAttributedString.Key.paragraphStyle: paragraph
        ]
    }

    private static func removingRuby(from attributed: NSAttributedString) -> NSAttributedString {
        // Remove any custom ruby-related attributes by copying and stripping known keys.
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // Known ruby-related keys that may be used by RubyText. Adjust as needed.
        let rubyKeys: [NSAttributedString.Key] = [
            NSAttributedString.Key(rawValue: "RubyAnnotation"),
            NSAttributedString.Key(rawValue: "RubyBaseRange"),
            NSAttributedString.Key(rawValue: "RubyText"),
            NSAttributedString.Key(rawValue: "RubySize"),
            NSAttributedString.Key(rawValue: "RubyAlignment"),
            NSAttributedString.Key(rawValue: "RubyVisibility")
        ]
        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            for key in rubyKeys where attrs[key] != nil {
                mutable.removeAttribute(key, range: range)
            }
        }
        return mutable
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

