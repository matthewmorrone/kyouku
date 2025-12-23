import Foundation

/// Immutable furigana span ready for projection. All ranges are UTF-16 offsets
/// so they can interoperate with `NSRange` and other Foundation APIs.
struct FuriganaSpan: Hashable {
    enum Source: Int, CaseIterable {
        case heuristic
        case dictionary
        case userOverride

        /// Highest-priority sources appear first.
        static var priorityOrder: [Source] { [.userOverride, .dictionary, .heuristic] }
    }

    let rangeStart: Int
    let rangeLength: Int
    let kana: String
    let source: Source
    let weight: Int
}

/// Deterministic, stateless resolver that converts overlapping candidate spans
/// into a non-overlapping projection for display. This helper is intentionally
/// simple, replaceable, and safe to delete once a more sophisticated resolver
/// exists.
struct FuriganaSpanResolver {
    /// Resolves the provided candidates based on source priority and coverage.
    ///
    /// - Note: Higher priority sources always win. Within the same priority we
    ///   walk left-to-right and prefer longer spans. Winning spans never
    ///   overlap when the resolver finishes.
    func resolve(textLength: Int, candidates: [FuriganaSpan]) -> [FuriganaSpan] {
        guard textLength > 0 else { return [] }

        let bounded = candidates.filter { candidate in
            candidate.rangeLength > 0 &&
            candidate.rangeStart >= 0 &&
            candidate.rangeStart < textLength &&
            candidate.rangeStart + candidate.rangeLength <= textLength &&
            candidate.kana.isEmpty == false
        }

        var accepted: [FuriganaSpan] = []

        for priority in FuriganaSpan.Source.priorityOrder {
            let bucket = bounded
                .filter { $0.source == priority }
                .sorted(by: spanSort)

            for candidate in bucket {
                insert(candidate, into: &accepted)
            }
        }

        return accepted.sorted { lhs, rhs in
            lhs.rangeStart < rhs.rangeStart
        }
    }

    private func insert(_ candidate: FuriganaSpan, into accepted: inout [FuriganaSpan]) {
        var conflictingIndices: [Int] = []
        for (index, span) in accepted.enumerated() {
            if conflicts(candidate, span) {
                conflictingIndices.append(index)
            }
        }

        guard conflictingIndices.isEmpty == false else {
            accepted.append(candidate)
            return
        }

        let longestConflictLength = conflictingIndices.map { accepted[$0].rangeLength }.max() ?? 0
        guard candidate.rangeLength > longestConflictLength else {
            return
        }

        for index in conflictingIndices.sorted(by: >) {
            accepted.remove(at: index)
        }
        accepted.append(candidate)
    }

    private func spanSort(_ lhs: FuriganaSpan, _ rhs: FuriganaSpan) -> Bool {
        if lhs.rangeStart != rhs.rangeStart {
            return lhs.rangeStart < rhs.rangeStart
        }
        if lhs.rangeLength != rhs.rangeLength {
            return lhs.rangeLength > rhs.rangeLength
        }
        if lhs.weight != rhs.weight {
            return lhs.weight > rhs.weight
        }
        return lhs.kana < rhs.kana
    }

    private func conflicts(_ candidate: FuriganaSpan, _ existing: FuriganaSpan) -> Bool {
        let candStart = candidate.rangeStart
        let candEnd = candidate.rangeStart + candidate.rangeLength
        let spanStart = existing.rangeStart
        let spanEnd = existing.rangeStart + existing.rangeLength

        if candStart < spanEnd && spanStart < candEnd {
            return true
        }

        if candidate.source == .dictionary && existing.source == .dictionary {
            if candEnd == spanStart || spanEnd == candStart {
                return true
            }
        }

        return false
    }
}
