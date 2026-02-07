import Foundation

func buildNoteTitlesByID(from notes: [Note], maxDerivedTitleLength: Int = 42) -> [UUID: String] {
    var titles: [UUID: String] = [:]
    titles.reserveCapacity(notes.count)

    for note in notes {
        let trimmedTitle = (note.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedTitle.isEmpty == false {
            titles[note.id] = trimmedTitle
            continue
        }

        let firstLine = note.text
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
            ?? "Untitled Note"

        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxDerivedTitleLength {
            titles[note.id] = trimmed
        } else {
            let prefix = trimmed.prefix(maxDerivedTitleLength)
            titles[note.id] = "\(prefix)…"
        }
    }

    return titles
}

func buildNoteWordCountsByID(from words: [Word]) -> [UUID: Int] {
    var counts: [UUID: Int] = [:]
    for word in words {
        guard let noteID = word.sourceNoteID else { continue }
        counts[noteID, default: 0] += 1
    }
    return counts
}

func buildSortedNoteCountEntries(
    from words: [Word],
    titleFor noteTitle: (UUID) -> String
) -> [(noteID: UUID, title: String, count: Int)] {
    let counts = buildNoteWordCountsByID(from: words)
    guard counts.isEmpty == false else { return [] }

    return counts
        .map { (noteID, count) in
            (noteID: noteID, title: noteTitle(noteID), count: count)
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
}
