//  TokenSplitEditor.swift
//  Shared reusable split-token UI
//
//  Created by Assistant on 12/21/25.

import SwiftUI

struct TokenSplitEditor: View {
    let originalSurface: String
    @Binding var leftText: String
    @Binding var rightText: String
    @Binding var errorText: String?

    // Validation and actions are provided by the host view so logic stays local to the caller.
    var canApply: (String, String) -> Bool
    var onApply: () -> Void
    var onCancel: () -> Void

    // Configuration
    var showArrows: Bool = true
    var instructionText: String = "Use the arrows (or edit either field directly) to decide where the split should land."

    @FocusState private var leftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Split Token")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("Original surface")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(originalSurface)
                    .font(.headline)
            }

            Text(instructionText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Left side")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Left", text: $leftText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($leftFocused)
                        .onTapGesture { moveCharacterToLeft() }
                }

                if showArrows {
                    VStack(spacing: 8) {
                        Button(action: moveCharacterToLeft) {
                            Image(systemName: "arrow.left")
                                .font(.title2)
                        }
                        .disabled(rightText.isEmpty)

                        Button(action: moveCharacterToRight) {
                            Image(systemName: "arrow.right")
                                .font(.title2)
                        }
                        .disabled(leftText.isEmpty)
                    }
                }

                VStack(alignment: .leading) {
                    Text("Right side")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Right", text: $rightText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onTapGesture { moveCharacterToRight() }
                }
            }

            if let err = errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Apply Split") { onApply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply(leftText, rightText))
            }
        }
        .padding()
        .onAppear { leftFocused = true }
    }

    private func moveCharacterToLeft() {
        guard let first = rightText.first else { return }
        rightText.removeFirst()
        leftText.append(first)
        errorText = nil
    }

    private func moveCharacterToRight() {
        guard let last = leftText.popLast() else { return }
        rightText = String(last) + rightText
        errorText = nil
    }
}
