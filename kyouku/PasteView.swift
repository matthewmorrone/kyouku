import SwiftUI

struct PasteView: View {
    @EnvironmentObject var store: WordStore
    
    @State private var inputText: String = ""
    @State private var tokens: [ParsedToken] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $inputText)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4))
                    )
                    .padding(.horizontal)
                
                Button("Analyze Text") {
                    tokens = JapaneseParser.parse(text: inputText)
                }
                .buttonStyle(.borderedProminent)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(tokens) { token in
                            Button {
                                store.add(from: token)
                            } label: {
                                FuriganaTokenView(token: token)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .navigationTitle("Paste")
        }
    }
}
