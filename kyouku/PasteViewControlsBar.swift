import SwiftUI
import UIKit

struct PasteControlsBar: View {
    @Binding var isEditing: Bool
    @Binding var showFurigana: Bool

    @Binding var wrapLines: Bool
    @Binding var alternateTokenColors: Bool
    @Binding var highlightUnknownTokens: Bool
    @Binding var padHeadwords: Bool

    let onHideKeyboard: () -> Void
    let onPaste: () -> Void
    let onSave: () -> Void

    let onToggleFurigana: (_ enabled: Bool) -> Void
    let onShowToast: (_ message: String) -> Void
    let onHaptic: () -> Void

    @State private var showingFuriganaOptions = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ControlCell {
                Button {
                    onHideKeyboard()
                    onShowToast("Keyboard hidden")
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                }
                .accessibilityLabel("Hide Keyboard")
            }

            ControlCell {
                Button(action: onPaste) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.title2)
                }
                .accessibilityLabel("Paste")
            }

            ControlCell {
                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                }
                .accessibilityLabel("Save")
            }

            ControlCell {
                EmptyView()
            }

            ControlCell {
                ZStack {
                    Color.clear.frame(width: 28, height: 28)
                    Image(showFurigana ? "furigana.on" : "furigana.off")
                        .renderingMode(.template)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 22))
                }
                .contentShape(Rectangle())
                .opacity(isEditing ? 0.45 : 1.0)
                .onTapGesture {
                    guard isEditing == false else { return }
                    showFurigana.toggle()
                    onToggleFurigana(showFurigana)
                    onShowToast(showFurigana ? "Furigana enabled" : "Furigana disabled")
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in
                            onHaptic()
                            showingFuriganaOptions = true
                        }
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(showFurigana ? "Disable Furigana" : "Enable Furigana")
                .accessibilityHint("Double tap to toggle. Press and hold for options.")
                .popover(
                    isPresented: $showingFuriganaOptions,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    FuriganaOptionsPopover(
                        wrapLines: $wrapLines,
                        alternateTokenColors: $alternateTokenColors,
                        highlightUnknownTokens: $highlightUnknownTokens,
                        padHeadwords: $padHeadwords
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }

            ControlCell {
                Toggle(isOn: $isEditing) {
                    if UIImage(systemName: "character.cursor.ibeam.ja") != nil {
                        Image(systemName: "character.cursor.ibeam.ja")
                    } else {
                        Image(systemName: "character.cursor.ibeam")
                    }
                }
                .labelsHidden()
                .toggleStyle(.button)
                .tint(.accentColor)
                .font(.title2)
                .accessibilityLabel("Edit")
            }
        }
        .controlSize(.small)
    }
}

private struct FuriganaOptionsPopover: View {
    @Binding var wrapLines: Bool
    @Binding var alternateTokenColors: Bool
    @Binding var highlightUnknownTokens: Bool
    @Binding var padHeadwords: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $wrapLines) {
                Label("Wrap Lines", systemImage: "text.append") //point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill
            }
            Toggle(isOn: $padHeadwords) {
                Label("Pad headwords", systemImage: "arrow.left.and.right.text.vertical")
            }
            Toggle(isOn: $alternateTokenColors) {
                Label("Alternate Token Colors", systemImage: "sparkle.text.clipboard")
            }
            Toggle(isOn: $highlightUnknownTokens) {
                Label("Highlight Unknown Words", systemImage: "questionmark.square.dashed")
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .frame(maxWidth: 320)
    }
}
