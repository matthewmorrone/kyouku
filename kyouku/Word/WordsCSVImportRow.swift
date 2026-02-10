import SwiftUI
import UniformTypeIdentifiers

struct WordsCSVImportRow: View {
    let item: WordsCSVImportItem

    var body: some View {
        let surface = item.finalSurface ?? "—"
        let kana = item.finalKana ?? ""
        let meaning = item.finalMeaning ?? "—"

        return HStack(spacing: 12) {
            Text(surface)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(kana)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(meaning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

