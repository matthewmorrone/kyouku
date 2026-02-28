import SwiftUI

struct PasteCoreToolbar<TokenListSheet: View>: ToolbarContent {
    @Binding var isTitleEditPresented: Bool
    @Binding var titleEditDraft: String

    let navigationTitleText: String

    let onResetSpans: () -> Void
    let onCameraOCRTap: () -> Void
    let onKaraokePrimaryTap: () -> Void
    let onKaraokeRestartFromBeginning: () -> Void
    let onChooseAudio: () -> Void
    let onChooseSubtitles: () -> Void
    let onClearKaraoke: () -> Void
    let onRecomputeKaraoke: () -> Void
    let onOpenKaraokeDebugDump: () -> Void
    let isKaraokeAudioUploaded: Bool
    let isKaraokeFileUploaded: Bool
    let isKaraokeBusy: Bool
    let karaokeProgress: Double
    let isKaraokeReady: Bool
    let isKaraokePlaying: Bool

    @State private var didTriggerKaraokeLongPress = false

    @Binding var showTokensSheet: Bool
    let tokenListSheet: () -> TokenListSheet

    init(
        isTitleEditPresented: Binding<Bool>,
        titleEditDraft: Binding<String>,
        navigationTitleText: String,
        onResetSpans: @escaping () -> Void,
        onCameraOCRTap: @escaping () -> Void,
        onKaraokePrimaryTap: @escaping () -> Void,
        onKaraokeRestartFromBeginning: @escaping () -> Void,
        onChooseAudio: @escaping () -> Void,
        onChooseSubtitles: @escaping () -> Void,
        onClearKaraoke: @escaping () -> Void,
        onRecomputeKaraoke: @escaping () -> Void,
        onOpenKaraokeDebugDump: @escaping () -> Void,
        isKaraokeAudioUploaded: Bool,
        isKaraokeFileUploaded: Bool,
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
        self.onKaraokeRestartFromBeginning = onKaraokeRestartFromBeginning
        self.onChooseAudio = onChooseAudio
        self.onChooseSubtitles = onChooseSubtitles
        self.onClearKaraoke = onClearKaraoke
        self.onRecomputeKaraoke = onRecomputeKaraoke
        self.onOpenKaraokeDebugDump = onOpenKaraokeDebugDump
        self.isKaraokeAudioUploaded = isKaraokeAudioUploaded
        self.isKaraokeFileUploaded = isKaraokeFileUploaded
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
                    if didTriggerKaraokeLongPress {
                        didTriggerKaraokeLongPress = false
                        return
                    }
                    onKaraokePrimaryTap()
                } label: {
                    ZStack {
                        Image(systemName: "waveform")
                            .symbolEffect(
                                .pulse.byLayer,
                                options: .repeating,
                                isActive: isKaraokePlaying
                            )

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
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            didTriggerKaraokeLongPress = true
                            onKaraokeRestartFromBeginning()
                        }
                )
                .accessibilityLabel(
                    isKaraokeBusy
                    ? "Generating karaoke sync"
                    : (isKaraokeReady
                       ? (isKaraokePlaying ? "Pause karaoke" : "Play karaoke")
                       : "Choose Karaoke Audio")
                )
                .disabled(isKaraokeBusy)
                .contextMenu {
                    Button {
                        onChooseAudio()
                    } label: {
                        if isKaraokeAudioUploaded {
                            Label("audio uploaded ✓", systemImage: "checkmark")
                        } else {
                            Label("upload audio", systemImage: "speaker.wave.3")
                        }
                    }
                    Button {
                        onChooseSubtitles()
                    } label: {
                        if isKaraokeFileUploaded {
                            Label("srt/json uploaded ✓", systemImage: "checkmark")
                        } else {
                            Label("upload srt/json", systemImage: "doc.text")
                        }
                    }

                    Button(role: .destructive) {
                        onClearKaraoke()
                    } label: {
                        Label("reset karaoke", systemImage: "trash")
                    }
                }
                /*
                Button {
                    onResetSpans()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset Spans")
                */
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
