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
        TestCase(title: "Exact Kanji", term: "食べる", note: "Baseline exact-match lookup", limit: 5),
        TestCase(title: "Exact Kanji (銀行)", term: "銀行", note: "Second baseline to compare warm vs cold cache", limit: 5),
        TestCase(title: "Kana Reading", term: "たべる", note: "Reading-only query", limit: 5),
        TestCase(title: "Long Kana", term: "おもしろかった", note: "Checks longer kana under surface token limit", limit: 5),
        TestCase(title: "Fuzzy Substring", term: "日本", note: "Substring match on kanji/readings", limit: 5),
        TestCase(title: "Romaji", term: "taberu", note: "Short romaji conversion", limit: 5),
        TestCase(title: "Romaji Long", term: "shitsumonshiteiru", note: "Stress roman-to-kana conversion", limit: 5),
        TestCase(title: "Romaji Mixed", term: "ryokucha", note: "Romaji with y/ky digraphs", limit: 5),
        TestCase(title: "Full-width Romaji", term: "ｔａｂｅｒｕ", note: "Ensure full-width rejection/handling is fast", limit: 5),
        TestCase(title: "Whitespace Noise", term: "   先生   ", note: "Trimming/normalization timing", limit: 5),
        TestCase(title: "High Frequency Kana", term: "の", note: "Large match sets should remain responsive", limit: 10),
        TestCase(title: "Surface Index", term: "語学", note: "Forces substring token index when no exact hit", limit: 5),
        TestCase(title: "Surface Index Unicode", term: "東京🗼", note: "Mixed scripts plus emoji", limit: 5),
        TestCase(title: "English Gloss", term: "bank", note: "Single-token FTS query", limit: 5),
        TestCase(title: "English Phrase", term: "bank account", note: "Multi-token FTS AND query", limit: 5),
        TestCase(title: "English Verb Phrase", term: "take a bath", note: "FTS with stop-words+spaces", limit: 5),
    ]

    var body: some View {
        List {
            ForEach(Array(cases.enumerated()), id: \.element.id) { index, c in
                Section(header: Text("\(index + 1). \(c.title)")) {
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

                    if let note = c.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let d = durations[c.id] {
                        Text("Duration: \(formatDuration(d))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = errors[c.id] {
                        Text(err)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    if let rows = results[c.id] {
                        if rows.isEmpty {
                            Text("No results")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rows.prefix(c.limit), id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                        .font(.headline)
                                    if !entry.reading.isEmpty {
                                        Text(entry.reading)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(firstGloss(entry.gloss))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else if isRunning {
                        ProgressView()
                            .controlSize(.small)
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
