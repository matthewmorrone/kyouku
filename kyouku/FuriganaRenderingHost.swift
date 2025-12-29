import SwiftUI
import UIKit

struct FuriganaRenderingHost: View {
    @Binding var text: String
    var furiganaText: NSAttributedString?
    var furiganaSpans: [AnnotatedSpan]?
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
    var enableTapInspection: Bool = true
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil

    var body: some View {
        Group {
            if isEditing {
                editorContent
            }
            else if text.isEmpty {
                displayShell { EmptyView() }
            }
            else if showFurigana {
                displayShell {
                    rubyBlock(annotationVisibility: .visible)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            else {
                displayShell {
                    rubyBlock(annotationVisibility: .removed)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color(.systemBackground))
        .cornerRadius(12)
        .roundedBorder(Color(.white), cornerRadius: 12)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: textSize))
                .lineSpacing(lineSpacing)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .foregroundColor(.primary)
                .padding(editorInsets)
        }
    }

    private var editorInsets: EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let topInset = max(8.0, rubyHeadroom)
        return EdgeInsets(top: CGFloat(topInset), leading: 11, bottom: 12, trailing: 12)
    }

    private func displayShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content()
                    .padding(8)
            }
            .font(.system(size: textSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rubyBlock(annotationVisibility: RubyAnnotationVisibility) -> some View {
        return RubyText(
            attributed: resolvedAttributedText,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            annotationVisibility: annotationVisibility,
            tokenOverlays: tokenColorOverlays,
            annotatedSpans: furiganaSpans ?? [],
            selectedRange: selectedRangeHighlight,
            customizedRanges: customizedRanges,
            enableTapInspection: enableTapInspection,
            onSpanSelection: onSpanSelection,
            contextMenuStateProvider: contextMenuStateProvider,
            onContextMenuAction: onContextMenuAction
        )
    }

    private var resolvedAttributedText: NSAttributedString {
        furiganaText ?? NSAttributedString(string: text)
    }

    private var tokenColorOverlays: [RubyText.TokenOverlay] {
        guard let spans = furiganaSpans, (alternateTokenColors || highlightUnknownTokens) else { return [] }
        let backingString = furiganaText?.string ?? text
        let textStorage = backingString as NSString
        var overlays: [RubyText.TokenOverlay] = []

        if alternateTokenColors {
            let palette = tokenPalette.filter { $0.cgColor.alpha > 0 }
            if palette.isEmpty == false {
                let coverageRanges = Self.coverageRanges(from: spans, textStorage: textStorage)
                overlays.reserveCapacity(coverageRanges.count)
                for (index, range) in coverageRanges.enumerated() {
                    let color = palette[index % palette.count]
                    overlays.append(RubyText.TokenOverlay(range: range, color: color))
                }
            }
        }

        if highlightUnknownTokens {
            let unknowns = Self.unknownTokenOverlays(from: spans, textStorage: textStorage, color: unknownTokenColor)
            overlays.append(contentsOf: unknowns)
        }

        return overlays
    }

    private static func coverageRanges(from spans: [AnnotatedSpan], textStorage: NSString) -> [NSRange] {
        let textLength = textStorage.length
        guard textLength > 0 else { return [] }
        let bounds = NSRange(location: 0, length: textLength)
        let sorted = spans
            .map { $0.span.range }
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

    private static func unknownTokenOverlays(from spans: [AnnotatedSpan], textStorage: NSString, color: UIColor) -> [RubyText.TokenOverlay] {
        guard textStorage.length > 0 else { return [] }
        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(spans.count)
        for span in spans where span.readingKana == nil {
            guard let clamped = Self.clampRange(span.span.range, length: textStorage.length) else { continue }
            if containsNonWhitespace(in: clamped, textStorage: textStorage) == false { continue }
            overlays.append(RubyText.TokenOverlay(range: clamped, color: color))
        }
        return overlays
    }
}
