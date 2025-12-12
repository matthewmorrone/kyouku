//
//  SettingsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4

    @State private var preview: NSAttributedString = NSAttributedString(string: "")

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading Appearance") {
                    FuriganaTextView(attributedText: preview)
                        .frame(maxWidth: .infinity, idealHeight: 80, alignment: .leading)
                        .padding(.vertical, 8)

                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text("\(Int(textSize))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $textSize, in: 1...30, step: 1)

                    HStack {
                        Text("Furigana Size")
                        Spacer()
                        Text("\(Int(furiganaSize))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $furiganaSize, in: 1...30, step: 1)
                    
                    HStack {
                        Text("Line Spacing")
                        Spacer()
                        Text("\(Int(lineSpacing))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $lineSpacing, in: 1...30, step: 1)
                }

            }
            .navigationTitle("Settings")
            .onAppear { rebuildPreview() }
            .onChange(of: textSize) { rebuildPreview() }
            .onChange(of: furiganaSize) { rebuildPreview() }
            .onChange(of: lineSpacing) { rebuildPreview() }
        }
    }

    @MainActor
    private func rebuildPreview() {
        let sample = "日本語の文章です。\n日本語の文章です。"
        preview = JapaneseFuriganaBuilder.buildAttributedText(
            text: sample,
            showFurigana: true,
            baseFontSize: CGFloat(textSize),
            rubyFontSize: CGFloat(furiganaSize),
            lineSpacing: CGFloat(lineSpacing)
        )
    }
}

