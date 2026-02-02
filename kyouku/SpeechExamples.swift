import SwiftUI

/// Minimal, self-contained examples of wiring `SpeechManager` into SwiftUI.
///
/// These are not used by default, but they compile and serve as reference.
#if DEBUG
struct SpokenWordExampleView: View {
    let word: String
    let language: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(word)

            Button {
                SpeechManager.shared.speak(text: word, language: language)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speak")
        }
    }
}

struct SpokenWordContextMenuExampleView: View {
    let word: String

    var body: some View {
        Text(word)
            .contextMenu {
                Button {
                    SpeechManager.shared.speak(text: word)
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2")
                }
            }
    }
}
#endif
