import SwiftUI

struct FuriganaTokenView: View {
    var token: ParsedToken
    
    var body: some View {
        VStack(spacing: 4) {
            Text(token.reading)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(token.surface)
                .font(.title3)
            if let meaning = token.meaning, !meaning.isEmpty {
                Text(meaning)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.3))
        )
    }
}
