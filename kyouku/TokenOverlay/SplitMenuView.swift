import SwiftUI
import UIKit
import Foundation

struct SplitMenuView: View {
    let selectionCharacters: [Character]
    @Binding var leftBucketCount: Int
    let onCancel: () -> Void
    let onApply: (Int) -> Void

    private var canSplit: Bool {
        selectionCharacters.count > 1 && leftBucketCount > 0 && leftBucketCount < selectionCharacters.count
    }

    private var leftText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let count = max(0, min(leftBucketCount, selectionCharacters.count))
        return String(selectionCharacters.prefix(count))
    }

    private var rightText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let suffixCount = max(0, selectionCharacters.count - leftBucketCount)
        guard suffixCount > 0 else { return "" }
        return String(selectionCharacters.suffix(suffixCount))
    }

    private var leftUTF16Length: Int {
        guard canSplit else { return 0 }
        let prefixString = String(selectionCharacters.prefix(leftBucketCount))
        return prefixString.utf16.count
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                bucketButton(text: leftText, alignment: .trailing, isEnabled: leftBucketCount < selectionCharacters.count) {
                    moveCharacterRightToLeft()
                }

                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)

                bucketButton(text: rightText, alignment: .leading, isEnabled: leftBucketCount > 0) {
                    moveCharacterLeftToRight()
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)

                Button("Apply") {
                    guard canSplit else { return }
                    onApply(leftUTF16Length)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(canSplit == false)
            }
            .font(.caption)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func bucketButton(text: String, alignment: Alignment, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.isEmpty ? "" : text)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: alignment)
                .frame(height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isEnabled ? Color.appAccent : Color.appTextSecondary.opacity(0.5), lineWidth: 1.5)
        )
    }

    private func moveCharacterLeftToRight() {
        guard leftBucketCount > 0 else { return }
        leftBucketCount -= 1
    }

    private func moveCharacterRightToLeft() {
        guard leftBucketCount < selectionCharacters.count else { return }
        leftBucketCount += 1
    }
}

