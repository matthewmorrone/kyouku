import SwiftUI

struct ThemesView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var readingOverrides: ReadingOverridesStore
    @EnvironmentObject var tokenBoundaries: TokenBoundariesStore
    @EnvironmentObject var themes: ThemeDiscoveryStore

    var body: some View {
        List {
            if themes.state.clusters.isEmpty {
                ContentUnavailableView(
                    "No themes yet",
                    systemImage: "sparkles",
                    description: Text(themes.state.isComputing ? "Computing themes…" : "Add a few notes to discover themes.")
                )
            } else {
                ForEach(themes.state.clusters) { cluster in
                    NavigationLink {
                        ThemeNotesListView(cluster: cluster)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: cluster.hasEmbedding ? "sparkles" : "circle.slash")
                                .foregroundStyle(cluster.hasEmbedding ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cluster.label)
                                    .font(.headline)
                                Text("\(cluster.noteCount) note\(cluster.noteCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Themes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if themes.state.isComputing {
                    ProgressView()
                }
            }
        }
        .onAppear {
            themes.bind(notesStore: notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
        }
    }
}

private struct ThemeNotesListView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    let cluster: ThemeCluster

    var body: some View {
        List {
            ForEach(notesForCluster) { note in
                Button {
                    router.noteToOpen = note
                    router.selectedTab = .paste
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((note.title?.isEmpty == false ? note.title! : "Untitled") as String)
                            .font(.headline)
                        Text(note.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(cluster.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var notesForCluster: [Note] {
        let idSet = Set(cluster.noteIDs)
        // Preserve NotesStore order.
        return notes.notes.filter { idSet.contains($0.id) }
    }
}
