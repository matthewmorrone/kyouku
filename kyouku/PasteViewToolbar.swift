import SwiftUI

struct PasteCoreToolbar<TokenListSheet: View>: ToolbarContent {
    @Binding var isTitleEditPresented: Bool
    @Binding var titleEditDraft: String

    let navigationTitleText: String
    let adjustedSpansDebugText: String

    let onResetSpans: () -> Void

    @Binding var showTokensSheet: Bool
    let tokenListSheet: () -> TokenListSheet

    init(
        isTitleEditPresented: Binding<Bool>,
        titleEditDraft: Binding<String>,
        navigationTitleText: String,
        adjustedSpansDebugText: String,
        onResetSpans: @escaping () -> Void,
        showTokensSheet: Binding<Bool>,
        tokenListSheet: @escaping () -> TokenListSheet
    ) {
        self._isTitleEditPresented = isTitleEditPresented
        self._titleEditDraft = titleEditDraft
        self.navigationTitleText = navigationTitleText
        self.adjustedSpansDebugText = adjustedSpansDebugText
        self.onResetSpans = onResetSpans
        self._showTokensSheet = showTokensSheet
        self.tokenListSheet = tokenListSheet
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                titleEditDraft = navigationTitleText == "Paste" ? "" : navigationTitleText
                isTitleEditPresented = true
            } label: {
                Text(navigationTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Title")
            .accessibilityHint("Shows an alert to set the note title")
        }

        ToolbarItem(placement: .topBarLeading) {
            PasteAdjustedSpansButton(debugText: adjustedSpansDebugText)
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button {
                    onResetSpans()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset Spans")

                Button {
                    showTokensSheet = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("Extract Words")
                .sheet(isPresented: $showTokensSheet) {
                    tokenListSheet()
                        .presentationDetents(Set([.large]))
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }
}

private struct PasteAdjustedSpansButton: View {
    let debugText: String

    @State private var isPresented: Bool = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Show Adjusted Spans")
        .popover(isPresented: $isPresented) {
            ScrollView {
                Text(debugText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}
