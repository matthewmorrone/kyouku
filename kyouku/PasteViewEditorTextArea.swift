import SwiftUI
import UIKit
import Foundation

struct PasteEditorTextArea: View {
    @Binding var text: String
    @Binding var editorSelectedRange: NSRange?

    let furiganaText: NSAttributedString?
    let furiganaSpans: [AnnotatedSpan]?
    let semanticSpans: [SemanticSpan]

    let textSize: CGFloat
    let isEditing: Bool
    let showFurigana: Bool
    let lineSpacing: CGFloat
    let globalKerningPixels: CGFloat
    let padHeadwordSpacing: Bool
    let wrapLines: Bool

    let alternateTokenColors: Bool
    let highlightUnknownTokens: Bool
    let tokenPalette: [UIColor]
    let unknownTokenColor: UIColor

    let selectedRangeHighlight: NSRange?
    let scrollToSelectedRangeToken: Int
    let customizedRanges: [NSRange]
    let extraTokenOverlays: [RubyText.TokenOverlay]

    let bottomObstructionHeight: CGFloat

    let onCharacterTap: ((Int) -> Void)?
    let onSpanSelection: ((RubySpanSelection?) -> Void)?

    let enableDragSelection: Bool
    let onDragSelectionBegan: () -> Void
    let onDragSelectionEnded: (NSRange) -> Void

    let contextMenuStateProvider: (() -> RubyContextMenuState?)?
    let onContextMenuAction: ((RubyContextMenuAction) -> Void)?

    let viewMetricsContext: RubyText.ViewMetricsContext
    let onDebugTokenListTextChange: (String) -> Void

    let interTokenSpacing: [Int: CGFloat]
    let tokenSpacingValueProvider: ((Int) -> CGFloat)?
    let onTokenSpacingChanged: ((Int, CGFloat, Bool) -> Void)?

    let coordinateSpaceName: String

    var body: some View {
        FuriganaRenderingHost(
            text: $text,
            editorSelectedRange: $editorSelectedRange,
            furiganaText: furiganaText,
            furiganaSpans: furiganaSpans,
            semanticSpans: semanticSpans,
            interTokenSpacing: interTokenSpacing,
            textSize: textSize,
            isEditing: isEditing,
            showFurigana: showFurigana,
            lineSpacing: lineSpacing,
            globalKerningPixels: globalKerningPixels,
            padHeadwordSpacing: padHeadwordSpacing,
            wrapLines: wrapLines,
            alternateTokenColors: alternateTokenColors,
            highlightUnknownTokens: highlightUnknownTokens,
            tokenPalette: tokenPalette,
            unknownTokenColor: unknownTokenColor,
            selectedRangeHighlight: selectedRangeHighlight,
            scrollToSelectedRangeToken: scrollToSelectedRangeToken,
            customizedRanges: customizedRanges,
            extraTokenOverlays: extraTokenOverlays,
            enableTapInspection: true,
            bottomObstructionHeight: bottomObstructionHeight,
            onCharacterTap: onCharacterTap,
            onSpanSelection: onSpanSelection,
            tokenSpacingValueProvider: tokenSpacingValueProvider,
            onTokenSpacingChanged: onTokenSpacingChanged,
            enableDragSelection: enableDragSelection,
            onDragSelectionBegan: onDragSelectionBegan,
            onDragSelectionEnded: onDragSelectionEnded,
            contextMenuStateProvider: contextMenuStateProvider,
            onContextMenuAction: onContextMenuAction,
            viewMetricsContext: viewMetricsContext,
            onDebugTokenListTextChange: onDebugTokenListTextChange
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PasteAreaFramePreferenceKey.self,
                    value: proxy.frame(in: .named(coordinateSpaceName))
                )
            }
        )
        .padding(.vertical, 16)
    }
}
