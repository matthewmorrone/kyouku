import Foundation

enum ThemeLabeler {
    static func label(for termCounts: [String: Int]) -> String {
        if termCounts.isEmpty {
            return "Theme"
        }

        // Prefer higher counts; tie-break by shorter label (usually nicer).
        let sorted = termCounts
            .filter { isUsableTerm($0.key) }
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                if a.key.count != b.key.count { return a.key.count < b.key.count }
                return a.key < b.key
            }

        let top = Array(sorted.prefix(3)).map { $0.key }
        if top.isEmpty {
            return "Theme"
        }
        return top.joined(separator: " · ")
    }

    private static func isUsableTerm(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        if trimmed.count == 1 { return false }
        // Filter obvious noise.
        if trimmed.allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}
