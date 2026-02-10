import SwiftUI
import UniformTypeIdentifiers

struct WordsCSVImportView: View {
    @EnvironmentObject private var store: WordsStore

    @Environment(\.dismiss) private var dismiss
    @State private var rawText: String = ""
    @FocusState private var isEditorFocused: Bool
    @State private var isParsing: Bool = false
    @State private var items: [WordsCSVImportItem] = []
    @State private var errorText: String? = nil
    @State private var isFileImporterPresented: Bool = false
    @State private var addToListMode: WordsCSVImportListMode = .none
    @State private var selectedExistingListID: UUID? = nil
    @State private var newListName: String = ""

    private var importableItems: [WordsCSVImportItem] {
        items.filter { item in
            item.finalSurface?.isEmpty == false && item.finalMeaning?.isEmpty == false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            inputControls
            listControls
            csvEditor
            previewList
            importButton
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            isEditorFocused = false
        }
        .navigationTitle("Import CSV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hide Keyboard") {
                    isEditorFocused = false
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private var inputControls: some View {
        HStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Choose CSV", systemImage: "doc")
            }

            Spacer()

            Button {
                Task { await parse() }
            } label: {
                if isParsing {
                    ProgressView()
                } else {
                    Text("Parse")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isParsing || rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var listControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add imported words to")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("List mode", selection: $addToListMode) {
                Text("No list").tag(WordsCSVImportListMode.none)
                Text("Existing list").tag(WordsCSVImportListMode.existing)
                Text("New list").tag(WordsCSVImportListMode.new)
            }
            .pickerStyle(.segmented)

            switch addToListMode {
            case .none:
                EmptyView()

            case .existing:
                if store.lists.isEmpty {
                    Text("No lists yet. Create one first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Existing list", selection: $selectedExistingListID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(store.lists) { list in
                            Text(list.name).tag(Optional(list.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

            case .new:
                TextField("New list name", text: $newListName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }

    private var csvEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste CSV text")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .focused($isEditorFocused)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                )

            if let errorText, errorText.isEmpty == false {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            let total = items.count
            let importable = importableItems.count
            Text(total == 0 ? "Parsed rows" : "Parsed rows: \(importable)/\(total) importable")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text("No rows parsed yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(items) { item in
                            WordsCSVImportRow(item: item)
                            Divider()
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var importButton: some View {
        Button {
            importWords()
            dismiss()
        } label: {
            Text("Import \(importableItems.count) Words")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(importableItems.isEmpty || importSelectionIsValid == false)
        .padding(.bottom, 8)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                errorText = "No file selected."
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                errorText = "Failed to access the file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let decoded = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .unicode)
                    ?? String(data: data, encoding: .ascii)
                guard let decoded else {
                    errorText = "Could not decode the file contents."
                    return
                }
                rawText = decoded
                errorText = nil
                items = []
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    @MainActor
    private func parse() async {
        isParsing = true
        defer { isParsing = false }
        errorText = nil

        let text = rawText
        let parsed = WordsCSVImport.parseItems(from: text)
        var enriched = parsed
        await WordsCSVImport.fillMissing(items: &enriched)
        items = enriched
    }

    private func importWords() {
        let listIDs = resolveImportListIDsCreatingIfNeeded().ids

        let payload: [WordsStore.WordToAdd] = importableItems.compactMap { item in
            guard let surface = item.finalSurface, surface.isEmpty == false else { return nil }
            guard let meaning = item.finalMeaning, meaning.isEmpty == false else { return nil }
            return WordsStore.WordToAdd(surface: surface, dictionarySurface: nil, kana: item.finalKana, meaning: meaning, note: item.finalNote)
        }

        store.addMany(payload, sourceNoteID: nil, listIDs: listIDs)
    }

    private var importSelectionIsValid: Bool {
        switch addToListMode {
        case .none:
            return true
        case .existing:
            guard let id = selectedExistingListID else { return false }
            return store.lists.contains(where: { $0.id == id })
        case .new:
            let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty == false
        }
    }

    private func resolveImportListIDsCreatingIfNeeded() -> (ids: [UUID], isValid: Bool) {
        switch addToListMode {
        case .none:
            return ([], true)
        case .existing:
            guard let id = selectedExistingListID else { return ([], false) }
            guard store.lists.contains(where: { $0.id == id }) else { return ([], false) }
            return ([id], true)
        case .new:
            let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return ([], false) }
            if let existing = store.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return ([existing.id], true)
            }
            if let created = store.createList(name: name) {
                return ([created.id], true)
            }
            if let fallback = store.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return ([fallback.id], true)
            }
            return ([], false)
        }
    }
}

private enum WordsCSVImportListMode: Hashable {
    case none
    case existing
    case new
}

private enum WordsCSVImport {
    static func parseItems(from text: String) -> [WordsCSVImportItem] {
        guard let firstNonEmptyLine = firstNonEmptyLine(in: text) else { return [] }
        if let delimiter = autoDelimiter(forFirstLine: firstNonEmptyLine) {
            return parseDelimited(text, delimiter: delimiter)
        }
        return parseListMode(text)
    }

    static func fillMissing(items: inout [WordsCSVImportItem]) async {
        guard items.isEmpty == false else { return }

        var updated = Array<WordsCSVImportItem?>(repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, WordsCSVImportItem).self) { group in
            for idx in items.indices {
                let original = items[idx]
                group.addTask {
                    var item = original

                    func localTrim(_ value: String?) -> String? {
                        guard let value else { return nil }
                        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }

                    func localFirstGloss(_ gloss: String) -> String {
                        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gloss
                    }

                    func localIsKanaOnly(_ text: String) -> Bool {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { return false }
                        var sawKana = false
                        for scalar in trimmed.unicodeScalars {
                            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                            switch scalar.value {
                            case 0x3040...0x309F,
                                 0x30A0...0x30FF,
                                 0xFF66...0xFF9F:
                                sawKana = true
                            default:
                                return false
                            }
                        }
                        return sawKana
                    }

                    func localContainsJapaneseScript(_ text: String) -> Bool {
                        for scalar in text.unicodeScalars {
                            switch scalar.value {
                            case 0x3040...0x309F,
                                 0x30A0...0x30FF,
                                 0xFF66...0xFF9F,
                                 0x3400...0x4DBF,
                                 0x4E00...0x9FFF,
                                 0xF900...0xFAFF:
                                return true
                            default:
                                continue
                            }
                        }
                        return false
                    }

                    let surface = localTrim(item.providedSurface ?? item.computedSurface)
                    let kana = localTrim(item.providedKana ?? item.computedKana)
                    let meaning = localTrim(item.providedMeaning ?? item.computedMeaning)

                    let needsSurface = (surface?.isEmpty ?? true)
                    let needsKana = (kana?.isEmpty ?? true)
                    let needsMeaning = (meaning?.isEmpty ?? true)
                    if needsSurface == false && needsKana == false && needsMeaning == false {
                        return (idx, item)
                    }

                    var candidates: [String] = []
                    if let s = surface, s.isEmpty == false { candidates.append(s) }
                    if let k = kana, k.isEmpty == false { candidates.append(k) }
                    if let m = meaning, m.isEmpty == false, (localContainsJapaneseScript(m) || localIsKanaOnly(m)) {
                        candidates.append(m)
                    }
                    var seen = Set<String>()
                    candidates = candidates.filter { seen.insert($0).inserted }

                    var hit: DictionaryEntry? = nil
                    for cand in candidates {
                        let keys = await MainActor.run { DictionaryKeyPolicy.keys(forDisplayKey: cand) }
                        guard keys.lookupKey.isEmpty == false else { continue }
                        let rows: [DictionaryEntry]
                        do {
                            rows = try await Task.detached(priority: .userInitiated, operation: { () async throws -> [DictionaryEntry] in
                                try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 1)
                            }).value
                        } catch {
                            continue
                        }

                        if let first = rows.first {
                            hit = first
                            break
                        }
                    }

                    if let entry = hit {
                        if needsSurface {
                            let proposed = entry.kanji.isEmpty ? (entry.kana ?? "") : entry.kanji
                            if proposed.isEmpty == false {
                                item.computedSurface = proposed
                            }
                        }
                        if needsKana {
                            if let k = entry.kana, k.isEmpty == false {
                                item.computedKana = k
                            }
                        }
                        if needsMeaning {
                            let gloss = localFirstGloss(entry.gloss)
                            if gloss.isEmpty == false {
                                item.computedMeaning = gloss
                            }
                        }
                    }

                    return (idx, item)
                }
            }

            for await (idx, newItem) in group {
                updated[idx] = newItem
            }
        }

        for idx in items.indices {
            if let u = updated[idx] {
                items[idx] = u
            }
        }
    }

    private static func parseListMode(_ text: String) -> [WordsCSVImportItem] {
        var out: [WordsCSVImportItem] = []
        var lineNo = 0
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let trimmedLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }

            if containsKanji(trimmedLine) {
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: trimmedLine, providedKana: nil, providedMeaning: nil, providedNote: nil))
            } else if isKanaOnly(trimmedLine) {
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: trimmedLine, providedMeaning: nil, providedNote: nil))
            } else {
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: nil, providedMeaning: trimmedLine, providedNote: nil))
            }
        }
        return out
    }

    private struct HeaderMap {
        var surfaceIndex: Int?
        var kanaIndex: Int?
        var meaningIndex: Int?
        var noteIndex: Int?
    }

    private static func parseDelimited(_ text: String, delimiter: Character) -> [WordsCSVImportItem] {
        var out: [WordsCSVImportItem] = []
        var lineNo = 0
        var headerMap: HeaderMap? = nil
        var didConsumeHeader = false

        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let cols = splitCSVLine(line, delimiter: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if headerMap == nil {
                if let maybeHeader = buildHeaderMap(from: cols) {
                    headerMap = maybeHeader
                    didConsumeHeader = true
                    continue
                }
            }

            let item: WordsCSVImportItem
            if let headerMap {
                let surface = headerMap.surfaceIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let kana = headerMap.kanaIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let meaning = headerMap.meaningIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let note = headerMap.noteIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                item = WordsCSVImportItem(lineNumber: lineNo, providedSurface: surface, providedKana: kana, providedMeaning: meaning, providedNote: note)
            } else {
                let classified = classifyRowCells(cols)
                item = WordsCSVImportItem(lineNumber: lineNo, providedSurface: classified.surface, providedKana: classified.kana, providedMeaning: classified.meaning, providedNote: classified.note)
            }

            if didConsumeHeader {
                didConsumeHeader = false
            }

            out.append(item)
        }
        return out
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty == false {
                return line
            }
        }
        return nil
    }

    private static func autoDelimiter(forFirstLine line: String) -> Character? {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (delim: Character, count: Int)? = nil
        for delim in candidates {
            let count = line.filter { $0 == delim }.count
            if count == 0 { continue }
            if best == nil || count > best!.count {
                best = (delim, count)
            }
        }
        return best?.delim
    }

    static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func classifyRowCells(_ cols: [String]) -> (surface: String?, kana: String?, meaning: String?, note: String?) {
        let values = cols.compactMap { trim($0) }
        guard values.isEmpty == false else { return (nil, nil, nil, nil) }

        let kanjiSurface = values.first(where: { containsKanji($0) })
        let japaneseSurface = kanjiSurface ?? values.first(where: { containsJapaneseScript($0) })

        let kana = values.first(where: { isKanaOnly($0) })
            ?? values.first(where: { containsJapaneseScript($0) && containsKanji($0) == false && looksLikeEnglish($0) == false })

        let meaning = values.first(where: { looksLikeEnglish($0) })
            ?? values.first(where: { containsJapaneseScript($0) == false })

        var used = Set<String>()
        if let japaneseSurface { used.insert(japaneseSurface) }
        if let kana { used.insert(kana) }
        if let meaning { used.insert(meaning) }
        let noteParts = values.filter { used.contains($0) == false }
        let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")

        return (japaneseSurface, kana, meaning, note)
    }

    private static func buildHeaderMap(from cols: [String]) -> HeaderMap? {
        var map = HeaderMap()
        var hits = 0

        for (idx, raw) in cols.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty { continue }

            if ["surface", "kanji", "word", "term", "vocab"].contains(key) {
                map.surfaceIndex = map.surfaceIndex ?? idx
                hits += 1
                continue
            }
            if ["kana", "reading", "yomi", "pronunciation"].contains(key) {
                map.kanaIndex = map.kanaIndex ?? idx
                hits += 1
                continue
            }
            if ["meaning", "gloss", "definition", "english", "en"].contains(key) {
                map.meaningIndex = map.meaningIndex ?? idx
                hits += 1
                continue
            }
            if ["note", "notes", "memo"].contains(key) {
                map.noteIndex = map.noteIndex ?? idx
                hits += 1
                continue
            }
        }

        return hits >= 2 ? map : nil
    }

    private static func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func isKanaOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var sawKana = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch scalar.value {
            case 0x3040...0x309F,
                 0x30A0...0x30FF,
                 0xFF66...0xFF9F:
                sawKana = true
            default:
                return false
            }
        }
        return sawKana
    }

    private static func containsJapaneseScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F,
                 0x30A0...0x30FF,
                 0xFF66...0xFF9F,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func looksLikeEnglish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard containsJapaneseScript(trimmed) == false else { return false }
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                return true
            }
        }
        return false
    }

    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var out: [String] = []
        out.reserveCapacity(4)

        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    let nextIndex = i + 1
                    if nextIndex < chars.count, chars[nextIndex] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    current.append(ch)
                    i += 1
                    continue
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                    i += 1
                    continue
                }
                if ch == delimiter {
                    out.append(current)
                    current = ""
                    i += 1
                    continue
                }
                current.append(ch)
                i += 1
            }
        }

        out.append(current)
        return out
    }
}
