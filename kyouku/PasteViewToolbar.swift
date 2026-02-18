import SwiftUI

struct PasteCoreToolbar<TokenListSheet: View>: ToolbarContent {
    @Binding var isTitleEditPresented: Bool
    @Binding var titleEditDraft: String

    let navigationTitleText: String

    let onResetSpans: () -> Void
    let onCameraOCRTap: () -> Void
    let onKaraokePrimaryTap: () -> Void
    let onClearKaraoke: () -> Void
    let isKaraokeBusy: Bool
    let karaokeProgress: Double
    let isKaraokeReady: Bool
    let isKaraokePlaying: Bool

    @Binding var showTokensSheet: Bool
    let tokenListSheet: () -> TokenListSheet

    init(
        isTitleEditPresented: Binding<Bool>,
        titleEditDraft: Binding<String>,
        navigationTitleText: String,
        onResetSpans: @escaping () -> Void,
        onCameraOCRTap: @escaping () -> Void,
        onKaraokePrimaryTap: @escaping () -> Void,
        onClearKaraoke: @escaping () -> Void,
        isKaraokeBusy: Bool,
        karaokeProgress: Double,
        isKaraokeReady: Bool,
        isKaraokePlaying: Bool,
        showTokensSheet: Binding<Bool>,
        tokenListSheet: @escaping () -> TokenListSheet
    ) {
        self._isTitleEditPresented = isTitleEditPresented
        self._titleEditDraft = titleEditDraft
        self.navigationTitleText = navigationTitleText
        self.onResetSpans = onResetSpans
        self.onCameraOCRTap = onCameraOCRTap
        self.onKaraokePrimaryTap = onKaraokePrimaryTap
        self.onClearKaraoke = onClearKaraoke
        self.isKaraokeBusy = isKaraokeBusy
        self.karaokeProgress = karaokeProgress
        self.isKaraokeReady = isKaraokeReady
        self.isKaraokePlaying = isKaraokePlaying
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
                    onCameraOCRTap()
                } label: {
                    Image(systemName: "camera.viewfinder")
                }
                .accessibilityLabel("Capture text with camera")
                .accessibilityHint("Opens the iPhone camera and scans text")

                Button {
                    onKaraokePrimaryTap()
                } label: {
                    ZStack {
                        Image(systemName: "waveform")

                        if isKaraokeBusy {
                            Circle()
                                .fill(Color.accentColor.opacity(0.2))
                                .frame(width: 18, height: 18)
                            Circle()
                                .trim(from: 0, to: min(max(karaokeProgress, 0), 1))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 20, height: 20)
                                .rotationEffect(.degrees(-90))
                        } else if isKaraokeReady {
                            Image(systemName: isKaraokePlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .padding(3)
                                .background(.ultraThinMaterial, in: Circle())
                                .offset(x: 8, y: 8)
                        }
                    }
                }
                .accessibilityLabel(
                    isKaraokeBusy
                    ? "Generating karaoke sync"
                    : (isKaraokeReady
                       ? (isKaraokePlaying ? "Pause karaoke" : "Play karaoke")
                       : "Choose Karaoke Audio")
                )
                .disabled(isKaraokeBusy)
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard isKaraokeReady else { return }
                    onClearKaraoke()
                }

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
