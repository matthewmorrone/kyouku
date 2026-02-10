import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import UIKit

struct ParticleTagEditor: View {
    @Binding var tags: [String]
    @State private var draft: String = ""

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 70), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tags.isEmpty {
                Text("No particles configured yet. Add particles to hide them from the Extract Words list when filtering is enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(for: tag)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add particle", text: $draft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { commitDraft() }

                Button("Add") { commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(CommonParticleSettings.normalizedToken(draft).isEmpty)
            }

            Text("Tap a tag’s × button to remove it. These values inform the ‘Hide common particles’ filter in Extract Words.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tagChip(for tag: String) -> some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.subheadline)
            Button(role: .destructive) {
                remove(tag: tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func commitDraft() {
        let normalized = CommonParticleSettings.normalizedToken(draft)
        guard normalized.isEmpty == false else { return }
        if tags.contains(normalized) == false {
            tags.append(normalized)
            tags.sort()
        }
        draft = ""
    }

    private func remove(tag: String) {
        tags.removeAll { $0 == tag }
    }
}

