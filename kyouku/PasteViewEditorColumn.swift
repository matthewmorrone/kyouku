import SwiftUI
import UIKit
import Foundation

struct PasteEditorColumnBody: View {
    @Binding var text: String
    @Binding var editorSelectedRange: NSRange?

    let furiganaText: NSAttributedString?
    let furiganaSpans: [AnnotatedSpan]?
    let semanticSpans: [SemanticSpan]

    let textSize: CGFloat

    @Binding var isEditing: Bool
    @Binding var showFurigana: Bool
    @Binding var wrapLines: Bool
    @Binding var alternateTokenColors: Bool
    @Binding var highlightUnknownTokens: Bool
    @Binding var padHeadwordSpacing: Bool

    let incrementalLookupEnabled: Bool

    let lineSpacing: CGFloat
    let globalKerningPixels: CGFloat

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

    let coordinateSpaceName: String

    let interTokenSpacing: [Int: CGFloat]
    let tokenSpacingValueProvider: ((Int) -> CGFloat)?
    let onTokenSpacingChanged: ((Int, CGFloat, Bool) -> Void)?

    let onHideKeyboard: () -> Void
    let onPaste: () -> Void
    let onSave: () -> Void
    let onToggleFurigana: (Bool) -> Void
    let onShowToast: (String) -> Void
    let onHaptic: () -> Void

    private var effectiveShowFurigana: Bool {
        incrementalLookupEnabled ? false : showFurigana
    }

    private var effectiveAlternateTokenColors: Bool {
        incrementalLookupEnabled ? false : alternateTokenColors
    }

    private var effectiveHighlightUnknownTokens: Bool {
        incrementalLookupEnabled ? false : highlightUnknownTokens
    }

    var body: some View {
        VStack(spacing: 0) {
            PasteEditorTextArea(
                text: $text,
                editorSelectedRange: $editorSelectedRange,
                furiganaText: furiganaText,
                furiganaSpans: furiganaSpans,
                semanticSpans: semanticSpans,
                textSize: textSize,
                isEditing: isEditing,
                showFurigana: effectiveShowFurigana,
                lineSpacing: lineSpacing,
                globalKerningPixels: globalKerningPixels,
                padHeadwordSpacing: padHeadwordSpacing,
                wrapLines: wrapLines,
                alternateTokenColors: effectiveAlternateTokenColors,
                highlightUnknownTokens: effectiveHighlightUnknownTokens,
                tokenPalette: tokenPalette,
                unknownTokenColor: unknownTokenColor,
                selectedRangeHighlight: selectedRangeHighlight,
                scrollToSelectedRangeToken: scrollToSelectedRangeToken,
                customizedRanges: customizedRanges,
                extraTokenOverlays: extraTokenOverlays,
                bottomObstructionHeight: bottomObstructionHeight,
                onCharacterTap: onCharacterTap,
                onSpanSelection: onSpanSelection,
                enableDragSelection: enableDragSelection,
                onDragSelectionBegan: onDragSelectionBegan,
                onDragSelectionEnded: onDragSelectionEnded,
                contextMenuStateProvider: contextMenuStateProvider,
                onContextMenuAction: onContextMenuAction,
                viewMetricsContext: viewMetricsContext,
                onDebugTokenListTextChange: onDebugTokenListTextChange,
                interTokenSpacing: interTokenSpacing,
                tokenSpacingValueProvider: tokenSpacingValueProvider,
                onTokenSpacingChanged: onTokenSpacingChanged,
                coordinateSpaceName: coordinateSpaceName
            )

            PasteControlsBar(
                isEditing: $isEditing,
                showFurigana: $showFurigana,
                wrapLines: $wrapLines,
                alternateTokenColors: $alternateTokenColors,
                highlightUnknownTokens: $highlightUnknownTokens,
                padHeadwords: $padHeadwordSpacing,
                onHideKeyboard: onHideKeyboard,
                onPaste: onPaste,
                onSave: onSave,
                onToggleFurigana: onToggleFurigana,
                onShowToast: onShowToast,
                onHaptic: onHaptic
            )
        }
    }
}
