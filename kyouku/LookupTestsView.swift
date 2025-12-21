import SwiftUI

struct LookupTestsView: View {
    private struct TestCase: Identifiable {
        let id = UUID()
        let title: String
        let term: String
        let note: String?
        let limit: Int
    }

    @Environment(\.dismiss) private var dismiss

    @State private var isRunning: Bool = false
    @State private var results: [UUID: [DictionaryEntry]] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var durations: [UUID: TimeInterval] = [:]
    @State private var runTask: Task<Void, Never>? = nil

    private let cases: [TestCase] = [
        TestCase(title: "Exact Kanji", term: "食べる", note: "Should match exact kanji/reading entries", limit: 5),
        TestCase(title: "Kana Reading", term: "たべる", note: "Reading-only query", limit: 5),
        TestCase(title: "Romaji", term: "taberu", note: "Romaji should convert to kana internally", limit: 5),
        TestCase(title: "English Gloss", term: "bank", note: "Should search English glosses", limit: 5),
        TestCase(title: "Fuzzy Substring", term: "日本", note: "Substring match on kanji/readings", limit: 5)
    ]

    var body: some View {
        List {
            ForEach(cases) { c in
                Section(header: Text(c.title)) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.term)
                                .font(.headline)
                            Text("Limit: \(c.limit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(resultSummary(for: c.id))
                            .font(.subheadline)
                            .foregroundStyle(resultColor(for: c.id))
                    }

                    if let note = c.note { Text(note).font(.caption).foregroundStyle(.secondary) }

                    if let d = durations[c.id] {
                        Text("Duration: \(formatDuration(d))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = errors[c.id] {
                        Text(err).foregroundColor(.red).font(.footnote)
                    }

                    if let rows = results[c.id] {
                        if rows.isEmpty {
                            Text("No results").foregroundStyle(.secondary)
                        } else {
                            ForEach(rows.prefix(c.limit), id: \.id) { e in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.kanji.isEmpty ? e.reading : e.kanji)
                                        .font(.headline)
                                    if !e.reading.isEmpty {
                                        Text(e.reading)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(firstGloss(e.gloss))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle("Lookup Tests")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isRunning {
                    Button("Cancel") { cancelRun() }
                } else {
                    Button("Execute") { runAll() }
                }
            }
        }
    }

    private func runAll() {
        cancelRun()
        isRunning = true
        results = [:]
        errors = [:]
        durations = [:]
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for c in cases {
                    group.addTask {
                        if Task.isCancelled { return }
                        let start = Date()
                        do {
                            let rows = try await DictionarySQLiteStore.shared.lookup(term: c.term, limit: c.limit)
                            let elapsed = Date().timeIntervalSince(start)
                            if Task.isCancelled { return }
                            await MainActor.run {
                                guard !Task.isCancelled else { return }
                                results[c.id] = rows
                                durations[c.id] = elapsed
                            }
                        } catch {
                            let elapsed = Date().timeIntervalSince(start)
                            if Task.isCancelled { return }
                            await MainActor.run {
                                guard !Task.isCancelled else { return }
                                errors[c.id] = error.localizedDescription
                                results[c.id] = []
                                durations[c.id] = elapsed
                            }
                        }
                    }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                isRunning = false
                runTask = nil
            }
        }
        runTask = task
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func firstGloss(_ gloss: String) -> String {
        let parts = gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.first.map(String.init) ?? gloss
    }
    
    private func formatDuration(_ t: TimeInterval) -> String {
        if t < 1 {
            let ms = Int(t * 1000)
            return "\(ms) ms"
        } else {
            return String(format: "%.2f s", t)
        }
    }

    private func resultSummary(for caseID: UUID) -> String {
        if errors[caseID] != nil {
            return "Error"
        }
        if let rows = results[caseID] {
            return rows.isEmpty ? "No matches" : "\(rows.count) matches"
        }
        return isRunning ? "Running…" : "Pending"
    }

    private func resultColor(for caseID: UUID) -> Color {
        if errors[caseID] != nil { return .red }
        if results[caseID] != nil { return .primary }
        return .secondary
    }
}

#Preview {
    NavigationStack { LookupTestsView() }
}
