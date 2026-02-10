import SwiftUI

struct TitleEditModalView: View {
    @Binding var isPresented: Bool
    @Binding var draft: String

    let onApply: () -> Void

    var body: some View {
        ZStack {
            // Tap-to-dismiss scrim.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Title", text: $draft)
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit {
                            onApply()
                            isPresented = false
                        }

                    if draft.isEmpty == false {
                        Button {
                            draft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.appTextSecondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear title")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    Button("Cancel", role: .cancel) {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Button("Set") {
                        onApply()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .frame(height: 180)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.98).combined(with: .opacity))
        }
    }
}
