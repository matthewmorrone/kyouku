import SwiftUI

struct PasteCoreToolbar<TokenListSheet: View>: ToolbarContent {
    @Binding var isTitleEditPresented: Bool
    @Binding var titleEditDraft: String

    let navigationTitleText: String

    let onResetSpans: () -> Void
    let onChooseKaraokeAudio: () -> Void
    let isKaraokeBusy: Bool

    @Binding var showTokensSheet: Bool
    let tokenListSheet: () -> TokenListSheet

    init(
        isTitleEditPresented: Binding<Bool>,
        titleEditDraft: Binding<String>,
        navigationTitleText: String,
        onResetSpans: @escaping () -> Void,
        onChooseKaraokeAudio: @escaping () -> Void,
        isKaraokeBusy: Bool,
        showTokensSheet: Binding<Bool>,
        tokenListSheet: @escaping () -> TokenListSheet
    ) {
        self._isTitleEditPresented = isTitleEditPresented
        self._titleEditDraft = titleEditDraft
        self.navigationTitleText = navigationTitleText
        self.onResetSpans = onResetSpans
        self.onChooseKaraokeAudio = onChooseKaraokeAudio
        self.isKaraokeBusy = isKaraokeBusy
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

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button {
                    onChooseKaraokeAudio()
                } label: {
                    if isKaraokeBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform")
                    }
                }
                .accessibilityLabel(isKaraokeBusy ? "Generating karaoke sync" : "Choose Karaoke Audio")
                .disabled(isKaraokeBusy)

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
