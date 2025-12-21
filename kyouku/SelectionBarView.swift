import SwiftUI

struct SelectionBarView: View {
    @Binding var isSelecting: Bool
    @Binding var selectedWordIDs: Set<UUID>
    var onDelete: () -> Void

    var body: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button("Cancel") {
                        isSelecting = false
                        selectedWordIDs.removeAll()
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Text("Delete Selected (\(selectedWordIDs.count))")
                    }
                    .disabled(selectedWordIDs.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.regularMaterial)
        }
    }
}
