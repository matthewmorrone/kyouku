import Foundation
import Combine

@MainActor
final class ThemeDiscoveryStore: ObservableObject {
    @Published private(set) var state: ThemeDiscoveryState = ThemeDiscoveryState()

    private var cancellables: Set<AnyCancellable> = []
    private var recomputeTask: Task<Void, Never>? = nil

    // Cache note → embedding snapshot.
    private var noteSnapshots: [UUID: ThemeNoteEmbeddingSnapshot] = [:]

    // Most recent note list (for recompute scheduling).
    private var lastNotes: [Note] = []
    private weak var lastReadingOverrides: ReadingOverridesStore? = nil
    private weak var lastTokenBoundaries: TokenBoundariesStore? = nil

    func bind(notesStore: NotesStore, readingOverrides: ReadingOverridesStore, tokenBoundaries: TokenBoundariesStore) {
        // Avoid double-binding.
        if cancellables.isEmpty == false { return }

        self.lastReadingOverrides = readingOverrides
        self.lastTokenBoundaries = tokenBoundaries

        notesStore.$notes
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] notes in
                self?.scheduleRecompute(notes: notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
            }
            .store(in: &cancellables)

        // Overrides change (reading overrides are used by Stage-2).
        NotificationCenter.default
            .publisher(for: .readingOverridesDidChange, object: readingOverrides)
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRecompute(notes: notesStore.notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
            }
            .store(in: &cancellables)

        // Token boundaries changes.
        tokenBoundaries.$spansByNote
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleRecompute(notes: notesStore.notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
            }
            .store(in: &cancellables)

        tokenBoundaries.$hardCutsByNote
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleRecompute(notes: notesStore.notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
            }
            .store(in: &cancellables)

        // Initial compute.
        scheduleRecompute(notes: notesStore.notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
    }

    func scheduleRecompute(notes: [Note], readingOverrides: ReadingOverridesStore, tokenBoundaries: TokenBoundariesStore) {
        lastNotes = notes
        lastReadingOverrides = readingOverrides
        lastTokenBoundaries = tokenBoundaries

        recomputeTask?.cancel()
        recomputeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            // Cheap idle delay to avoid thrash while typing.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard Task.isCancelled == false else { return }

            await self.recomputeNow(notes: notes, readingOverrides: readingOverrides, tokenBoundaries: tokenBoundaries)
        }
    }

    private func recomputeNow(notes: [Note], readingOverrides: ReadingOverridesStore, tokenBoundaries: TokenBoundariesStore) async {
        state.isComputing = true

        // Drop cache entries for deleted notes.
        let ids = Set(notes.map { $0.id })
        noteSnapshots = noteSnapshots.filter { ids.contains($0.key) }

        // Snapshot per-note inputs on main actor.
        let inputs: [ThemeNoteEmbeddingInput] = notes.map { note in
            let hardCuts = tokenBoundaries.hardCuts(for: note.id, text: note.text)
            let baseSpans = tokenBoundaries.spans(for: note.id, text: note.text)
            let overrides = readingOverrides.overrides(for: note.id).filter { $0.userKana != nil }
            return ThemeNoteEmbeddingInput(
                noteID: note.id,
                text: note.text,
                hardCuts: hardCuts,
                baseSpans: baseSpans,
                overrides: overrides
            )
        }

        // Compute or reuse per-note centroids.
        var updatedSnapshots: [UUID: ThemeNoteEmbeddingSnapshot] = noteSnapshots
        updatedSnapshots.reserveCapacity(inputs.count)

        for input in inputs {
            if Task.isCancelled { break }

            let sig = ThemeNoteEmbeddingBuilder.signature(for: input)
            if let existing = updatedSnapshots[input.noteID], existing.signature == sig {
                continue
            }

            let snapshot = await ThemeNoteEmbeddingBuilder.computeSnapshot(input: input)
            updatedSnapshots[input.noteID] = snapshot
        }

        noteSnapshots = updatedSnapshots

        // Cluster.
        let clusters = ThemeDiscoveryBuilder.buildClusters(from: notes, snapshots: updatedSnapshots)

        state.clusters = clusters
        state.lastUpdatedAt = Date()
        state.isComputing = false
    }
}

struct ThemeNoteEmbeddingInput: Sendable {
    let noteID: UUID
    let text: String
    let hardCuts: [Int]
    let baseSpans: [TextSpan]?
    let overrides: [ReadingOverride]
}

enum ThemeNoteEmbeddingBuilder {
    static func signature(for input: ThemeNoteEmbeddingInput) -> Int {
        var hasher = Hasher()
        hasher.combine(input.text)
        hasher.combine(input.hardCuts.count)
        for c in input.hardCuts { hasher.combine(c) }

        if let spans = input.baseSpans {
            hasher.combine(spans.count)
            for s in spans {
                hasher.combine(s.range.location)
                hasher.combine(s.range.length)
                hasher.combine(s.isLexiconMatch ? 1 : 0)
            }
        } else {
            hasher.combine(0)
        }

        hasher.combine(input.overrides.count)
        for o in input.overrides {
            hasher.combine(o.rangeStart)
            hasher.combine(o.rangeLength)
            hasher.combine(o.userKana ?? "")
        }

        return hasher.finalize()
    }

    static func computeSnapshot(input: ThemeNoteEmbeddingInput) async -> ThemeNoteEmbeddingSnapshot {
        let sig = signature(for: input)
        let nsText = input.text as NSString
        let length = nsText.length
        guard length > 0 else {
            return ThemeNoteEmbeddingSnapshot(noteID: input.noteID, signature: sig, centroid: nil, topTerms: [:])
        }

        let stage2: FuriganaAttributedTextBuilder.Stage2Result
        do {
            stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                text: input.text,
                context: "ThemeDiscovery",
                tokenBoundaries: input.hardCuts,
                readingOverrides: input.overrides,
                baseSpans: input.baseSpans
            )
        } catch {
            return ThemeNoteEmbeddingSnapshot(noteID: input.noteID, signature: sig, centroid: nil, topTerms: [:])
        }

        let spans = stage2.annotatedSpans
        guard spans.isEmpty == false else {
            return ThemeNoteEmbeddingSnapshot(noteID: input.noteID, signature: sig, centroid: nil, topTerms: [:])
        }

        // Resolve EmbeddingAccess safely.
        let access = await MainActor.run(resultType: EmbeddingAccess.self, body: { EmbeddingAccess.shared })

        // Build per-token candidate keys and batch fetch.
        var tokens: [EmbeddingToken] = []
        tokens.reserveCapacity(spans.count)

        for s in spans {
            let surface = s.span.surface
            if surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let lemma = s.lemmaCandidates.first
            tokens.append(EmbeddingToken(surface: surface, lemma: lemma, reading: s.readingKana))
        }

        let candidateLists: [[String]] = tokens.map { EmbeddingFallbackPolicy.candidates(for: $0) }

        var unique: [String] = []
        unique.reserveCapacity(candidateLists.count * 2)
        var seen: Set<String> = []
        seen.reserveCapacity(candidateLists.count * 2)

        for cands in candidateLists {
            for c in cands {
                if c.isEmpty { continue }
                if seen.insert(c).inserted { unique.append(c) }
            }
        }

        let fetched = access.vectors(for: unique)

        func normalize(_ v: [Float]) -> [Float] {
            var sum: Float = 0
            for x in v { sum += x * x }
            let norm = sum.squareRoot()
            guard norm > 0 else { return v }
            return v.map { $0 / norm }
        }

        var centroidAcc: [Float]? = nil
        var count: Float = 0
        var termCounts: [String: Int] = [:]
        termCounts.reserveCapacity(32)

        for (idx, cands) in candidateLists.enumerated() {
            var chosenKey: String? = nil
            var chosenVec: [Float]? = nil
            for c in cands {
                if let v = fetched[c] {
                    chosenKey = c
                    chosenVec = v
                    break
                }
            }
            guard let vec = chosenVec else { continue }

            if centroidAcc == nil {
                centroidAcc = Array(repeating: 0, count: vec.count)
            }
            guard var acc = centroidAcc else { continue }
            for j in 0..<vec.count {
                acc[j] += vec[j]
            }
            centroidAcc = acc
            count += 1

            // Use a display-friendly term: lemma > surface > embedding key.
            let t = tokens[idx]
            let display = (t.lemma?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? t.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = display.isEmpty ? (chosenKey ?? "") : display
            if key.isEmpty == false {
                termCounts[key, default: 0] += 1
            }
        }

        guard let acc = centroidAcc, count > 0 else {
            return ThemeNoteEmbeddingSnapshot(noteID: input.noteID, signature: sig, centroid: nil, topTerms: termCounts)
        }

        let mean = acc.map { $0 / count }
        let centroid = normalize(mean)

        return ThemeNoteEmbeddingSnapshot(noteID: input.noteID, signature: sig, centroid: centroid, topTerms: termCounts)
    }
}

enum ThemeDiscoveryBuilder {
    static func buildClusters(from notes: [Note], snapshots: [UUID: ThemeNoteEmbeddingSnapshot]) -> [ThemeCluster] {
        let ordered = notes
        let embedded: [(UUID, [Float], [String: Int])] = ordered.compactMap { note in
            guard let snap = snapshots[note.id], let c = snap.centroid else { return nil }
            return (note.id, c, snap.topTerms)
        }

        let unembeddedIDs: [UUID] = ordered.compactMap { note in
            guard let snap = snapshots[note.id] else { return note.id }
            return snap.centroid == nil ? note.id : nil
        }

        guard embedded.isEmpty == false else {
            if unembeddedIDs.isEmpty { return [] }
            return [ThemeCluster(id: "no-embedding", label: "No embedding", noteIDs: unembeddedIDs, hasEmbedding: false)]
        }

        let vectors = embedded.map { $0.1 }
        let k = min(ThemeClustering.chooseK(noteCount: vectors.count), vectors.count)
        let (assignments, _) = ThemeClustering.kMeansCosine(vectors: vectors, k: max(1, k))

        var buckets: [Int: [UUID]] = [:]
        var termBuckets: [Int: [String: Int]] = [:]

        for (i, a) in assignments.enumerated() {
            buckets[a, default: []].append(embedded[i].0)
            let terms = embedded[i].2
            if termBuckets[a] == nil { termBuckets[a] = [:] }
            for (t, c) in terms {
                termBuckets[a]?[t, default: 0] += c
            }
        }

        var clusters: [ThemeCluster] = []
        clusters.reserveCapacity(buckets.count + (unembeddedIDs.isEmpty ? 0 : 1))

        for key in buckets.keys.sorted() {
            let noteIDs = buckets[key] ?? []
            let label = ThemeLabeler.label(for: termBuckets[key] ?? [:])
            let id = "theme-\(key)-\(noteIDs.count)-\(stableIDHash(noteIDs))"
            clusters.append(ThemeCluster(id: id, label: label, noteIDs: noteIDs, hasEmbedding: true))
        }

        // Add a catch-all group for notes we couldn't embed.
        if unembeddedIDs.isEmpty == false {
            clusters.append(ThemeCluster(id: "no-embedding", label: "No embedding", noteIDs: unembeddedIDs, hasEmbedding: false))
        }

        // Prefer embedded clusters first, and sort by size.
        clusters.sort { a, b in
            if a.hasEmbedding != b.hasEmbedding { return a.hasEmbedding && !b.hasEmbedding }
            if a.noteCount != b.noteCount { return a.noteCount > b.noteCount }
            return a.label < b.label
        }

        return clusters
    }

    private static func stableIDHash(_ ids: [UUID]) -> Int {
        var hasher = Hasher()
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(id)
        }
        return hasher.finalize()
    }
}
