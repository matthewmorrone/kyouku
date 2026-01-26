import SwiftUI

/// Read-only UI for exploring semantically nearby words.
///
/// Constraints:
/// - Must not affect token boundaries.
/// - Must not affect dictionary lookup logic.
/// - Must hide gracefully if embeddings are unavailable.
struct SemanticNeighborhoodExplorerView: View {
    @ObservedObject var lookup: DictionaryLookupViewModel
    var topN: Int = 30

    @State private var neighbors: [EmbeddingNeighborsService.Neighbor] = []
    @State private var isLoading: Bool = false
    @State private var isAvailable: Bool = true
    @State private var debugStatus: String? = nil

    private var showScores: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NEIGHBOR_SCORE_DEBUG"] == "1"
        #else
        return false
        #endif
    }

    private var showDebugStatus: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NEIGHBOR_DEBUG"] == "1"
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if isAvailable, neighbors.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Nearby")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(neighbors, id: \.word) { n in
                                neighborCard(n)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if showDebugStatus, let msg = debugStatus, msg.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task(id: lookup.resolvedEmbeddingTerm ?? "") {
            await refresh()
        }
    }

    @ViewBuilder
    private func neighborCard(_ n: EmbeddingNeighborsService.Neighbor) -> some View {
        Button {
            Task { @MainActor in
                await lookup.lookup(term: n.word)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(n.word)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if showScores {
                    Text(String(format: "%.3f", n.score))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minWidth: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        let term = await MainActor.run { lookup.resolvedEmbeddingTerm }
        guard let term, term.isEmpty == false else {
            await MainActor.run {
                neighbors = []
                isAvailable = true
                isLoading = false
                debugStatus = nil
            }
            return
        }

        // Do not consult global embedding gates. This feature is additive and should simply
        // hide silently if embeddings are unavailable or the term has no embedding.

        await MainActor.run {
            isAvailable = true
            isLoading = true
        }

        let service = EmbeddingNeighborsService.shared
        let fetched = await service.neighbors(for: term, topN: topN)

        // Hide if there is no embedding or no neighbors.
        await MainActor.run {
            neighbors = fetched ?? []
            isLoading = false
            debugStatus = (fetched == nil) ? "No embedding for ‘\(term)’" : nil
        }
    }
}
