import SwiftUI
import UIKit

@MainActor
struct FuriganaRenderingHost: View {
    @AppStorage("readingFontName") private var readingFontName: String = ""
    @AppStorage("readingDistinctKanaKanjiFonts") private var readingDistinctKanaKanjiFonts: Bool = false
    @AppStorage("readingFuriganaBaselineGap") private var readingFuriganaBaselineGap: Double = 0.5
    @State private var scrollSyncGroupID: String = UUID().uuidString

    @Binding var text: String
    @Binding var editorSelectedRange: NSRange?
    var furiganaText: NSAttributedString?
    var furiganaSpans: [AnnotatedSpan]?
    var semanticSpans: [SemanticSpan]
    var interTokenSpacing: [Int: CGFloat] = [:]
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
    var extraTokenOverlays: [FuriganaText.TokenOverlay] = []
    var enableTapInspection: Bool = true
    /// Extra empty scroll space below the text, in points.
    ///
    /// Used to keep the last lines readable when bottom overlays (e.g. the token
    /// action panel) cover part of the text area.
    var bottomObstructionHeight: CGFloat = 0
    var onCharacterTap: ((Int) -> Void)? = nil
    var onSpanSelection: ((FuriganaSpanSelection?) -> Void)? = nil
    var tokenSpacingValueProvider: ((Int) -> CGFloat)? = nil
    var onTokenSpacingChanged: ((Int, CGFloat, Bool) -> Void)? = nil
    var enableDragSelection: Bool = false
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var contextMenuStateProvider: (() -> FuriganaContextMenuState?)? = nil
    var onContextMenuAction: ((FuriganaContextMenuAction) -> Void)? = nil
    var viewMetricsContext: FuriganaText.ViewMetricsContext? = nil
    var onDebugTokenListTextChange: ((String) -> Void)? = nil

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

    private func resolvedBaseUIFont() -> UIFont {
        let size = CGFloat(textSize)
        if readingFontName.isEmpty == false, let font = UIFont(name: readingFontName, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size)
    }

    private func rubyMetrics(baseFont: UIFont) -> (rubyHeadroom: CGFloat, effectiveLineSpacing: CGFloat) {
        let extraGap = CGFloat(max(0, lineSpacing))
        let furiganaBaselineGap = max(0, CGFloat(readingFuriganaBaselineGap))
        let defaultRubyFontSize = max(1, CGFloat(textSize) * 0.6)
        let attributed = resolvedAttributedText

        let rubyHeadroom = max(
            0,
            max(
                CGFloat(textSize) * 0.6 + extraGap,
                FuriganaText.requiredVerticalHeadroomForRuby(
                    in: attributed,
                    baseFont: baseFont,
                    defaultRubyFontSize: defaultRubyFontSize,
                    furiganaBaselineGap: furiganaBaselineGap
                )
            )
        )

        // Match FuriganaText's line spacing behavior when ruby metrics are enabled.
        let effectiveLineSpacing = max(extraGap, rubyHeadroom)
        return (rubyHeadroom, effectiveLineSpacing)
    }

    private func editorContent(bottomObstruction: CGFloat) -> some View {
        let baseFont = resolvedBaseUIFont()
        let metrics = rubyMetrics(baseFont: baseFont)
        let insets = editorInsets(
            bottomObstruction: bottomObstruction,
            rubyHeadroom: metrics.rubyHeadroom,
            baseFont: baseFont
        )
        return VStack(spacing: 0) {
            EditingTextView(
                text: $text,
                selectedRange: $editorSelectedRange,
                isEditable: isEditing,
                fontName: readingFontName.isEmpty ? nil : readingFontName,
                fontSize: CGFloat(textSize),
                lineSpacing: metrics.effectiveLineSpacing,
                globalKerning: CGFloat(globalKerningPixels),
                distinctKanaKanjiFonts: readingDistinctKanaKanjiFonts,
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

    private func editorInsets(bottomObstruction: CGFloat, rubyHeadroom: CGFloat, baseFont: UIFont) -> EdgeInsets {
        // Match FuriganaText's top inset behavior: textInsets.top (8) + ruby headroom.
        let topInset = 8.0 + max(0.0, Double(rubyHeadroom))

        let attributed = resolvedAttributedText
        let defaultRubyFontSize = max(1.0, CGFloat(textSize) * 0.6)

        // Match FuriganaText's horizontal inset behavior when ruby metrics are enabled.
        // FuriganaText adds symmetric slack to prevent ruby overhang/clipping at the container edges.
        // This is independent of headword padding and is required for edit/view origin parity.
        let rubyHorizontalInset: CGFloat = {
            let raw = FuriganaText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            return raw > 0 ? raw : 0
        }()

        // Compute symmetric horizontal overhang to match view mode ruby behavior.
        // Use the same helper FuriganaText uses so edit/view modes align.
        let insetOverhang: CGFloat = {
            guard padHeadwordSpacing else {
                // When headword padding is disabled, allow ruby to overhang/clamp naturally.
                return 0
            }
            let rawOverhang = FuriganaText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            return max(ceil(rawOverhang), 2)
        }()
        // Keep the left edge stable regardless of headword padding.
        // We add any extra ruby overhang slack only on the trailing side so enabling
        // padding does not indent the entire text block.
        let left: CGFloat = 12 + rubyHorizontalInset
        let right = 12 + rubyHorizontalInset + insetOverhang
        return EdgeInsets(
            top: CGFloat(topInset),
            leading: CGFloat(left),
            bottom: CGFloat(12) + bottomObstruction,
            trailing: CGFloat(right)
        )
    }

    private func rubyBlock(
        annotationVisibility: FuriganaAnnotationVisibility,
        bottomObstruction: CGFloat,
        viewMetricsContext: FuriganaText.ViewMetricsContext?
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
            let rawOverhang = FuriganaText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseUIFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            return max(ceil(rawOverhang), 2)
        }()
        let insets = UIEdgeInsets(
            top: 8,
            left: 12,
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
                CoreTextFuriganaText(
                    attributed: attributed,
                    fontSize: CGFloat(textSize),
                    extraGap: CGFloat(max(0, lineSpacing)),
                    furiganaBaselineGap: CGFloat(readingFuriganaBaselineGap),
                    textInsets: insets,
                    distinctKanaKanjiFonts: readingDistinctKanaKanjiFonts
                )
                .id(rubyViewIdentity())
                .frame(minHeight: 40, alignment: .topLeading)
            )
        }

        return AnyView(FuriganaText(
            attributed: attributed,
            fontName: readingFontName.isEmpty ? nil : readingFontName,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            furiganaBaselineGap: CGFloat(readingFuriganaBaselineGap),
            textInsets: insets,
            bottomOverlayHeight: bottomObstruction,
            annotationVisibility: annotationVisibility,
            isScrollEnabled: true,
            allowSystemTextSelection: false,
            globalKerning: CGFloat(globalKerningPixels),
            padHeadwordSpacing: padHeadwordSpacing,
            furiganaHorizontalAlignment: .center,
            wrapLines: (onTokenSpacingChanged != nil) ? true : wrapLines,
            horizontalScrollEnabled: ((onTokenSpacingChanged != nil) ? true : wrapLines) == false,
            scrollSyncGroupID: scrollSyncGroupID,
            tokenOverlays: tokenColorOverlays,
            tokenColorPalette: tokenPalette,
            semanticSpans: semanticSpans,
            interTokenSpacing: interTokenSpacing,
            selectedRange: selectedRangeHighlight,
            scrollToSelectedRangeToken: scrollToSelectedRangeToken,
            customizedRanges: customizedRanges,
            alternateTokenColorsEnabled: alternateTokenColors,
            enableTapInspection: enableTapInspection,
            enableDragSelection: enableDragSelection,
            distinctKanaKanjiFonts: readingDistinctKanaKanjiFonts,
            onDragSelectionBegan: onDragSelectionBegan,
            onDragSelectionEnded: onDragSelectionEnded,
            onCharacterTap: onCharacterTap,
            onSpanSelection: onSpanSelection,
            contextMenuStateProvider: contextMenuStateProvider,
            onContextMenuAction: onContextMenuAction,
            tokenSpacingValueProvider: tokenSpacingValueProvider,
            onTokenSpacingChanged: onTokenSpacingChanged,
            viewMetricsContext: viewMetricsContext,
            onDebugTokenListTextChange: onDebugTokenListTextChange
        )
        // `FuriganaText` performs custom drawing for ruby annotations. When token overlay modes
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

    private var tokenColorOverlays: [FuriganaText.TokenOverlay] {
        let wantsTokenColors = (alternateTokenColors || highlightUnknownTokens)
        if wantsTokenColors == false {
            return extraTokenOverlays
        }
        guard semanticSpans.isEmpty == false else { return extraTokenOverlays }
        let backingString = furiganaText?.string ?? text
        let textStorage = backingString as NSString
        var overlays: [FuriganaText.TokenOverlay] = []

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

                    overlays.append(FuriganaText.TokenOverlay(range: range, color: color))
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
    ) -> [FuriganaText.TokenOverlay] {
        guard textStorage.length > 0 else { return [] }
        var overlays: [FuriganaText.TokenOverlay] = []
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
            overlays.append(FuriganaText.TokenOverlay(range: clamped, color: color))
        }

        return overlays
    }
}
