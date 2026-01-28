import SwiftUI
import UIKit

@MainActor
struct FuriganaRenderingHost: View {
    @AppStorage("readingFontName") private var readingFontName: String = ""
    @State private var scrollSyncGroupID: String = UUID().uuidString

    @Binding var text: String
    @Binding var editorSelectedRange: NSRange?
    var furiganaText: NSAttributedString?
    var furiganaSpans: [AnnotatedSpan]?
    var semanticSpans: [SemanticSpan]
    var textSize: Double
    var isEditing: Bool
    var showFurigana: Bool
    var lineSpacing: Double
    var globalKerningPixels: Double = 0
    var padHeadwordSpacing: Bool = false
    var wrapLines: Bool = false
    var alternateTokenColors: Bool
    var highlightUnknownTokens: Bool
    var tokenPalette: [UIColor]
    var unknownTokenColor: UIColor
    var selectedRangeHighlight: NSRange?
    var scrollToSelectedRangeToken: Int = 0
    var customizedRanges: [NSRange]
    var extraTokenOverlays: [RubyText.TokenOverlay] = []
    var enableTapInspection: Bool = true
    /// Extra empty scroll space below the text, in points.
    ///
    /// Used to keep the last lines readable when bottom overlays (e.g. the token
    /// action panel) cover part of the text area.
    var bottomObstructionHeight: CGFloat = 0
    var onCharacterTap: ((Int) -> Void)? = nil
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var enableDragSelection: Bool = false
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil
    var viewMetricsContext: RubyText.ViewMetricsContext? = nil

    var body: some View {
        GeometryReader { proxy in
            let obstruction = min(max(0, bottomObstructionHeight), max(0, proxy.size.height))

            // IMPORTANT:
            // We keep both panes alive at all times and only toggle visibility.
            // SwiftUI `if` conditionals would destroy/recreate the UIViewRepresentables,
            // which resets scroll offsets and can effectively "tear out" scroll sync state.
            let paneBackground = isEditing ? Color.appSurface : Color.appBackground
            ZStack(alignment: .topLeading) {
                Group {
                    if text.isEmpty {
                        EmptyView()
                    } else {
                        rubyBlock(
                            annotationVisibility: showFurigana ? .visible : .hiddenKeepMetrics,
                            bottomObstruction: obstruction,
                            viewMetricsContext: viewMetricsContext
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(paneBackground)
                .clipped()
                .opacity(isEditing ? 0 : 1)
                .allowsHitTesting(isEditing == false)
                .accessibilityHidden(isEditing)

                editorContent(bottomObstruction: obstruction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(paneBackground)
                    .clipped()
                    .opacity(isEditing ? 1 : 0)
                    .allowsHitTesting(isEditing)
                    .accessibilityHidden(isEditing == false)
            }
            .background(isEditing ? Color.appSurface : Color.appBackground)
            .cornerRadius(12)
            .roundedBorder(Color.appBorder, cornerRadius: 12)
        }
    }

    private func editorContent(bottomObstruction: CGFloat) -> some View {
        let insets = editorInsets(bottomObstruction: bottomObstruction)
        return VStack(spacing: 0) {
            EditingTextView(
                text: $text,
                selectedRange: $editorSelectedRange,
                isEditable: isEditing,
                fontSize: CGFloat(textSize),
                lineSpacing: CGFloat(lineSpacing),
                wrapLines: wrapLines,
                scrollSyncGroupID: scrollSyncGroupID,
                insets: UIEdgeInsets(
                    top: insets.top,
                    left: insets.leading,
                    bottom: insets.bottom,
                    right: insets.trailing
                )
            )
            .padding(0)
        }
    }

    private func editorInsets(bottomObstruction: CGFloat) -> EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let topInset = max(8.0, rubyHeadroom)

        // Compute symmetric horizontal overhang to match view mode ruby behavior.
        // Use the same helper RubyText uses so edit/view modes align.
        let insetOverhang: CGFloat = {
            guard padHeadwordSpacing else {
                // When headword padding is disabled, allow ruby to overhang/clamp naturally.
                return 0
            }
            let attributed = furiganaText ?? NSAttributedString(string: text)
            let baseFont = UIFont.systemFont(ofSize: CGFloat(textSize))
            let defaultRubyFontSize = max(1.0, CGFloat(textSize) * 0.6)
            let rawOverhang = RubyText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            return max(ceil(rawOverhang), 2)
        }()
        let left = 12 + insetOverhang
        let right = 12 + insetOverhang
        return EdgeInsets(
            top: CGFloat(topInset),
            leading: CGFloat(left),
            bottom: CGFloat(12) + bottomObstruction,
            trailing: CGFloat(right)
        )
    }

    private func rubyBlock(
        annotationVisibility: RubyAnnotationVisibility,
        bottomObstruction: CGFloat,
        viewMetricsContext: RubyText.ViewMetricsContext?
    ) -> some View {
        let attributed = resolvedAttributedText
        let baseUIFont: UIFont = {
            let size = CGFloat(textSize)
            if readingFontName.isEmpty == false, let font = UIFont(name: readingFontName, size: size) {
                return font
            }
            return UIFont.systemFont(ofSize: size)
        }()
        let insetOverhang: CGFloat = {
            guard padHeadwordSpacing else {
                // When headword padding is disabled, allow ruby to overhang/clamp naturally.
                return 0
            }
            let defaultRubyFontSize = max(1, CGFloat(textSize) * 0.6)
            let rawOverhang = RubyText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseUIFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            return max(ceil(rawOverhang), 2)
        }()
        let insets = UIEdgeInsets(
            top: 8,
            left: 12 + insetOverhang,
            bottom: 12 + bottomObstruction,
            right: 12 + insetOverhang
        )

        // NOTE: TextKit cannot perfectly widen single-glyph headwords (e.g. lone kanji)
        // to match ruby width without side-effects. The experimental CoreText renderer
        // supports the exact width-matching behavior but intentionally bypasses TextKit
        // selection + hit-testing.
        let useCoreTextRenderer: Bool = {
            ProcessInfo.processInfo.environment["RUBY_CORETEXT"] == "1"
        }()

        if useCoreTextRenderer {
            return AnyView(
                CoreTextRubyText(
                    attributed: attributed,
                    fontSize: CGFloat(textSize),
                    extraGap: CGFloat(max(0, lineSpacing)),
                    textInsets: insets
                )
                .id(rubyViewIdentity())
                .frame(minHeight: 40, alignment: .topLeading)
            )
        }

        return AnyView(RubyText(
            attributed: attributed,
            fontName: readingFontName.isEmpty ? nil : readingFontName,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            textInsets: insets,
            bottomOverlayHeight: bottomObstruction,
            annotationVisibility: annotationVisibility,
            isScrollEnabled: true,
            allowSystemTextSelection: false,
            globalKerning: CGFloat(globalKerningPixels),
            padHeadwordSpacing: padHeadwordSpacing,
            rubyHorizontalAlignment: .center,
            wrapLines: wrapLines,
            horizontalScrollEnabled: wrapLines == false,
            scrollSyncGroupID: scrollSyncGroupID,
            tokenOverlays: tokenColorOverlays,
            tokenColorPalette: tokenPalette,
            semanticSpans: semanticSpans,
            selectedRange: selectedRangeHighlight,
            scrollToSelectedRangeToken: scrollToSelectedRangeToken,
            customizedRanges: customizedRanges,
            alternateTokenColorsEnabled: alternateTokenColors,
            enableTapInspection: enableTapInspection,
            enableDragSelection: enableDragSelection,
            onDragSelectionBegan: onDragSelectionBegan,
            onDragSelectionEnded: onDragSelectionEnded,
            onCharacterTap: onCharacterTap,
            onSpanSelection: onSpanSelection,
            contextMenuStateProvider: contextMenuStateProvider,
            onContextMenuAction: onContextMenuAction,
            viewMetricsContext: viewMetricsContext
        )
        // `RubyText` performs custom drawing for ruby annotations. When token overlay modes
        // toggle, UIKit doesn't always repaint the custom ruby layer immediately, so we
        // include overlay mode in the view identity to force a refresh.
        // IMPORTANT: do not include `annotationVisibility` in the identity, otherwise
        // toggling furigana recreates the view and resets the ScrollView to the top.
        .id(rubyViewIdentity())
        .frame(minHeight: 40, alignment: .topLeading))
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
                var alternationIndex = 0
                for range in coverageRanges {
                    let surface = textStorage.substring(with: range)
                    let isHardBoundary = Self.isHardBoundaryOnlySurface(surface)

                    let color: UIColor
                    if isHardBoundary {
                        let inheritedIndex = (alternationIndex == 0) ? 0 : (alternationIndex - 1)
                        color = palette[inheritedIndex % palette.count]
                    } else {
                        color = palette[alternationIndex % palette.count]
                        alternationIndex += 1
                    }

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
        // IMPORTANT: alternate-token-colors intentionally also colors “gaps” between
        // semantic spans, to make unknown surfaces readable.
        // However, copied Japanese text can include IVS/variation selectors and other
        // zero-width/invisible scalars that should NOT produce standalone “tokens”.
        return substring.unicodeScalars.contains { Self.isIgnorableTokenSurfaceScalar($0) == false }
    }

    private static func isHardBoundaryOnlySurface(_ surface: String) -> Bool {
        if surface.isEmpty { return true }
        let hardBoundary = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        for scalar in surface.unicodeScalars {
            if hardBoundary.contains(scalar) == false {
                return false
            }
        }
        return true
    }

    private static func isIgnorableTokenSurfaceScalar(_ scalar: UnicodeScalar) -> Bool {
        // Regular whitespace/newlines.
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }

        // Common invisible separators that can appear in copied text.
        switch scalar.value {
        case 0x00AD: return true // soft hyphen
        case 0x034F: return true // combining grapheme joiner
        case 0x061C: return true // arabic letter mark
        case 0x180E: return true // mongolian vowel separator (deprecated but seen in the wild)
        case 0x200B: return true // zero width space
        case 0x200C: return true // zero width non-joiner
        case 0x200D: return true // zero width joiner
        case 0x2060: return true // word joiner
        case 0xFEFF: return true // zero width no-break space / BOM
        default: break
        }

        // Variation selectors (VS1..VS16) and IVS (Variation Selector Supplement).
        // These can appear in Japanese text like 朕󠄂 / 通󠄁 and render “invisible” on their own.
        if (0xFE00...0xFE0F).contains(scalar.value) { return true }
        if (0xE0100...0xE01EF).contains(scalar.value) { return true }

        return false
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

@MainActor
private struct EditingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    let isEditable: Bool
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let wrapLines: Bool
    let scrollSyncGroupID: String
    let insets: UIEdgeInsets

    // Keep this large enough for real-world long lines when wrapping is disabled.
    private static let noWrapContainerWidth: CGFloat = 200_000

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = isEditable
        context.coordinator.attach(textView: view, scrollSyncGroupID: scrollSyncGroupID)
        view.delegate = context.coordinator
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = wrapLines == false
        view.showsHorizontalScrollIndicator = wrapLines == false
        view.textContainer.widthTracksTextView = wrapLines
        view.textContainer.maximumNumberOfLines = 0
        view.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = insets
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.delegate = context.coordinator
        view.font = UIFont.systemFont(ofSize: fontSize)
        view.textColor = UIColor.label

        if wrapLines == false {
            view.textContainer.size = CGSize(width: Self.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Start in a wrapped-friendly configuration even before the first layout pass.
            let targetWidth = max(1, view.bounds.width - insets.left - insets.right)
            if targetWidth.isFinite, targetWidth > 1 {
                view.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        
        // Build attributed text from the same source as view mode, but remove ruby for editing.
        let baseAttributed = NSAttributedString(string: text)
        let processed = Self.removingRuby(from: baseAttributed)
        let fullRange = NSRange(location: 0, length: (processed.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
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
            paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
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
        context.coordinator.attach(textView: uiView, scrollSyncGroupID: scrollSyncGroupID)
        // When an IME (e.g. Japanese QWERTY keyboard) is composing text, `markedTextRange`
        // is non-nil and UIKit expects to own the text storage. Re-applying `attributedText`
        // during this phase can corrupt the composition (e.g. "keshin" → "kえしn").
        let isComposing = (uiView.markedTextRange != nil && uiView.isFirstResponder)

        if isComposing == false {
            let baseAttributed = NSAttributedString(string: text)
            let processed = Self.removingRuby(from: baseAttributed)
            let fullRange = NSRange(location: 0, length: processed.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
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
        uiView.alwaysBounceHorizontal = wrapLines == false
        uiView.showsHorizontalScrollIndicator = wrapLines == false
        uiView.textContainer.widthTracksTextView = wrapLines
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        uiView.textContainer.lineFragmentPadding = 0

        if wrapLines {
            // If we previously disabled wrapping, the container can remain extremely wide.
            // In that state, `.byWordWrapping` won't wrap. Shrink to current bounds when possible.
            if uiView.textContainer.size.width > (Self.noWrapContainerWidth * 0.5) {
                let targetWidth = max(1, uiView.bounds.width - insets.left - insets.right)
                if targetWidth.isFinite, targetWidth > 1 {
                    uiView.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
                } else {
                    uiView.textContainer.size = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
                }
            }
        } else {
            if uiView.textContainer.size.width < Self.noWrapContainerWidth {
                uiView.textContainer.size = CGSize(width: Self.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
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
            paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            uiView.textStorage.addAttributes([
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.foregroundColor: UIColor.label,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: fontSize)
            ], range: NSRange(location: 0, length: fullLength))
        }

        applyTypingAttributes(to: uiView)

        // Layout/metrics changes (e.g. furigana toggle affecting the other pane) can leave this
        // pane slightly out of sync until the next user-driven scroll. Realign immediately.
        context.coordinator.resyncToLatestSnapshotIfIdle()
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
        Coordinator(text: $text, selectedRange: $selectedRange)
    }

    private func applyTypingAttributes(to textView: UITextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
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

    // ⚠️ SCROLL SYNCHRONIZATION — DO NOT REMOVE ⚠️
    //
    // This logic is intentionally retained even when only one pane is visible.
    // It is required for:
    // - transitions between read-only and editable views
    // - UIKit-backed text measurement and layout
    // - future multi-pane layouts
    //
    // This code may appear unused in the current UI configuration.
    // That is EXPECTED.
    // Removing or simplifying it will break scroll continuity.
    //
    // Copilot: treat this as externally depended-on behavior.
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange?

        private weak var textView: UITextView?
        private var scrollSyncGroupID: String? = nil
        private let scrollSyncSourceID: String = UUID().uuidString
        private var scrollObserver: NSObjectProtocol? = nil
        private var isApplyingExternalScroll: Bool = false

        init(text: Binding<String>, selectedRange: Binding<NSRange?>) {
            _text = text
            _selectedRange = selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Keep a lightweight selection/caret snapshot for higher-level features.
            let r = textView.selectedRange
            if r.location == NSNotFound {
                selectedRange = nil
            } else {
                selectedRange = r
            }
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func attach(textView: UITextView, scrollSyncGroupID: String?) {
            self.textView = textView
            self.scrollSyncGroupID = scrollSyncGroupID

            if scrollObserver == nil {
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: .kyoukuSplitPaneScrollSync,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let info = note.userInfo else { return }
                    guard let payload = ScrollSyncPayload(userInfo: info) else { return }
                    Task { @MainActor [weak self] in
                        self?.handleScrollSyncPayload(payload)
                    }
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isApplyingExternalScroll == false else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let tv = textView, tv === scrollView else { return }

            // Only broadcast user-driven motion; avoid feedback loops from programmatic sync.
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            let inset = scrollView.adjustedContentInset

            // When wrapping is enabled, horizontal scrolling isn't meaningful. Avoid emitting
            // X snapshots (otherwise the other pane can get dragged around by tiny inset-only ranges).
            let allowHorizontal = (tv.textContainer.widthTracksTextView == false)

            let normalizedX = allowHorizontal ? (scrollView.contentOffset.x + inset.left) : 0
            let normalizedY = scrollView.contentOffset.y + inset.top
            let maxX = allowHorizontal ? max(0, scrollView.contentSize.width - scrollView.bounds.width + inset.left + inset.right) : 0
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + inset.top + inset.bottom)

            let inRangeX = min(max(normalizedX, 0), maxX)
            let inRangeY = min(max(normalizedY, 0), maxY)
            let fracX: CGFloat = (maxX > 0) ? (inRangeX / maxX) : 0
            let fracY: CGFloat = (maxY > 0) ? (inRangeY / maxY) : 0

            let overscrollX: CGFloat = {
                guard allowHorizontal else { return 0 }
                if normalizedX < 0 { return normalizedX }
                if normalizedX > maxX { return normalizedX - maxX }
                return 0
            }()
            let overscrollY: CGFloat = {
                if normalizedY < 0 { return normalizedY }
                if normalizedY > maxY { return normalizedY - maxY }
                return 0
            }()

            SplitPaneScrollSyncStore.record(
                group: group,
                snapshot: SplitPaneScrollSyncStore.Snapshot(
                    source: scrollSyncSourceID,
                    fx: fracX,
                    fy: fracY,
                    ox: overscrollX,
                    oy: overscrollY,
                    sx: maxX,
                    sy: maxY,
                    timestamp: CFAbsoluteTimeGetCurrent()
                )
            )

            NotificationCenter.default.post(
                name: .kyoukuSplitPaneScrollSync,
                object: nil,
                userInfo: [
                    "group": group,
                    "source": scrollSyncSourceID,
                    "fx": fracX,
                    "fy": fracY,
                    "ox": overscrollX,
                    "oy": overscrollY,
                    "sx": maxX,
                    "sy": maxY
                ]
            )
        }

        func resyncToLatestSnapshotIfIdle() {
            guard isApplyingExternalScroll == false else { return }
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard tv.isTracking == false, tv.isDragging == false, tv.isDecelerating == false else { return }
            guard let snap = SplitPaneScrollSyncStore.latest(group: group) else { return }
            guard snap.source != scrollSyncSourceID else { return }

            let info: [String: Any] = [
                "group": group,
                "source": snap.source,
                "fx": snap.fx,
                "fy": snap.fy,
                "ox": snap.ox,
                "oy": snap.oy,
                "sx": snap.sx,
                "sy": snap.sy
            ]
            handleScrollSyncNotification(Notification(name: .kyoukuSplitPaneScrollSync, object: nil, userInfo: info))
        }

        private struct ScrollSyncPayload: Sendable {
            let group: String
            let source: String
            let fx: Double
            let fy: Double
            let ox: Double
            let oy: Double
            let sx: Double
            let sy: Double

            init?(userInfo: [AnyHashable: Any]) {
                guard let group = userInfo["group"] as? String, group.isEmpty == false else { return nil }
                guard let source = userInfo["source"] as? String, source.isEmpty == false else { return nil }

                func readDouble(_ key: String) -> Double {
                    if let v = userInfo[key] as? Double { return v }
                    if let v = userInfo[key] as? CGFloat { return Double(v) }
                    if let v = userInfo[key] as? NSNumber { return v.doubleValue }
                    return 0
                }

                self.group = group
                self.source = source
                self.fx = readDouble("fx")
                self.fy = readDouble("fy")
                self.ox = readDouble("ox")
                self.oy = readDouble("oy")
                self.sx = readDouble("sx")
                self.sy = readDouble("sy")
            }
        }

        private func handleScrollSyncNotification(_ note: Notification) {
            guard textView != nil else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let info = note.userInfo else { return }
            guard let payload = ScrollSyncPayload(userInfo: info) else { return }
            handleScrollSyncPayload(payload)
        }

        private func handleScrollSyncPayload(_ payload: ScrollSyncPayload) {
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard payload.group == group else { return }
            guard payload.source != scrollSyncSourceID else { return }

            let fx = CGFloat(payload.fx)
            let fy = CGFloat(payload.fy)
            let ox = CGFloat(payload.ox)
            let oy = CGFloat(payload.oy)
            let sx = CGFloat(payload.sx)
            let sy = CGFloat(payload.sy)

            tv.layoutIfNeeded()

            let inset = tv.adjustedContentInset
            let maxX = max(0, tv.contentSize.width - tv.bounds.width + inset.left + inset.right)
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + inset.top + inset.bottom)

            let clampedFX: CGFloat = min(max(fx, 0), 1)
            let clampedFY: CGFloat = min(max(fy, 0), 1)
            let currentNormalizedX = tv.contentOffset.x + inset.left
            let currentNormalizedY = tv.contentOffset.y + inset.top

            let shouldSyncX = (sx > 0) && (maxX > 0)
            let shouldSyncY = (sy > 0) && (maxY > 0)

            let effectiveFX: CGFloat = shouldSyncX ? clampedFX : 0
            let effectiveFY: CGFloat = shouldSyncY ? clampedFY : 0

            let desiredNormalized = CGPoint(
                x: shouldSyncX ? ((maxX * effectiveFX) + ox) : currentNormalizedX,
                y: shouldSyncY ? ((maxY * effectiveFY) + oy) : currentNormalizedY
            )

            let desired = CGPoint(
                x: desiredNormalized.x - inset.left,
                y: desiredNormalized.y - inset.top
            )

            // Clamp to an extended range so "bounce" overscroll stays synchronized.
            let minX = -inset.left
            let maxOffsetX = max(minX, tv.contentSize.width - tv.bounds.width + inset.right)
            let minY = -inset.top
            let maxOffsetY = max(minY, tv.contentSize.height - tv.bounds.height + inset.bottom)
            let allowX = max(60, tv.bounds.width * 0.25)
            let allowY = max(60, tv.bounds.height * 0.25)
            let clamped = CGPoint(
                x: min(max(desired.x, minX - allowX), maxOffsetX + allowX),
                y: min(max(desired.y, minY - allowY), maxOffsetY + allowY)
            )

            isApplyingExternalScroll = true
            if abs(tv.contentOffset.x - clamped.x) > 0.5 || abs(tv.contentOffset.y - clamped.y) > 0.5 {
                tv.setContentOffset(clamped, animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalScroll = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

