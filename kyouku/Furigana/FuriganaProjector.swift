import Foundation
import CoreFoundation

struct FuriganaAnnotationSegment {
    let range: NSRange
    let reading: String
    let commonKanaRemoved: String
}

enum FuriganaProjector {
    private struct CharInfo {
        let character: Character
        let utf16Location: Int
        let utf16Length: Int
        let isKanji: Bool
        let isKana: Bool
    }

    private struct KanjiCluster {
        let charStartIndex: Int
        let charEndIndex: Int
        let utf16Location: Int
        let utf16Length: Int
    }

    private static let kanaCharacterSet: CharacterSet = {
        var set = CharacterSet()
        set.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{309F}"))
        set.formUnion(CharacterSet(charactersIn: "\u{30A0}"..."\u{30FF}"))
        return set
    }()

    static func project(spanText: String, reading: String, spanRange: NSRange) -> [FuriganaAnnotationSegment] {
        guard reading.isEmpty == false else { return [] }

        // Normalize kana so surface-kana (often hiragana) can be matched against
        // MeCab readings (often katakana). Without this, spans like "時の" with
        // reading "トキノ" won't split at the "の" boundary and the full reading
        // gets applied over the kanji cluster.
        let normalizedReadingChars = Array(normalizedKana(reading))

        let charInfos = makeCharInfos(for: spanText)
        guard charInfos.contains(where: { $0.isKanji }) else { return [] }

        let clusters = makeClusters(from: charInfos)
        guard clusters.isEmpty == false else { return [] }

        let readingChars = normalizedReadingChars
        var readingIndex = 0
        var segments: [FuriganaAnnotationSegment] = []

        // Consume leading kana before the first kanji cluster
        var preIndex = 0
        while preIndex < charInfos.count, charInfos[preIndex].isKanji == false {
            if charInfos[preIndex].isKana {
                readingIndex = consumeKanaSequence(normalizedKanaSequence([charInfos[preIndex].character]), in: readingChars, from: readingIndex)
            }
            preIndex += 1
        }

        for (clusterIndex, cluster) in clusters.enumerated() {
            let nextKanaRaw = nextKanaSequence(startingAt: cluster.charEndIndex, chars: charInfos)
            let limited = limitNextKanaSequence(nextKanaRaw, in: readingChars, from: readingIndex)
            let nextKana = limited.normalized
            var extracted = extractReadingChunk(from: readingChars, readingIndex: &readingIndex, nextKana: nextKana, remainingClusters: clusters.count - clusterIndex - 1)
            var chunk = extracted.chunk

            if chunk.isEmpty {
                if extracted.removedKanaSuffix.isEmpty {
                    extracted = fallbackChunk(from: readingChars, readingIndex: &readingIndex)
                    chunk = extracted.chunk
                }
            }

            defer {
                readingIndex = consumeKanaSequence(nextKana, in: readingChars, from: readingIndex)
            }

            // Record the kana that were removed from the reading because they already exist as
            // visible surface kana immediately following this kanji cluster.
            let commonKanaRemoved = limited.rawUsed

            guard chunk.isEmpty == false else { continue }

            let range = NSRange(location: spanRange.location + cluster.utf16Location, length: cluster.utf16Length)
            segments.append(FuriganaAnnotationSegment(range: range, reading: chunk, commonKanaRemoved: commonKanaRemoved))
        }

        return segments
    }

    /// The surface may contain kana that are not part of the reading (e.g. following particles).
    /// To avoid blocking okurigana trimming/splitting, only keep the longest prefix of the
    /// surface-kana sequence that actually appears in the remaining reading.
    private static func limitNextKanaSequence(_ raw: [Character], in reading: [Character], from startIndex: Int) -> (rawUsed: String, normalized: [Character]) {
        guard raw.isEmpty == false else { return (rawUsed: "", normalized: []) }
        let normalizedRaw = normalizedKanaSequence(raw)
        guard normalizedRaw.isEmpty == false else { return (rawUsed: "", normalized: []) }
        guard startIndex < reading.count else { return (rawUsed: "", normalized: []) }

        // Try longest prefix first.
        for len in stride(from: normalizedRaw.count, through: 1, by: -1) {
            let candidate = Array(normalizedRaw.prefix(len))
            if let _ = findNextSequence(candidate, in: reading, start: startIndex) {
                let rawUsed = String(raw.prefix(len))
                return (rawUsed: rawUsed, normalized: candidate)
            }
        }

        return (rawUsed: "", normalized: [])
    }

    private static func makeCharInfos(for text: String) -> [CharInfo] {
        let ns = text as NSString
        var infos: [CharInfo] = []
        var index = 0
        while index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let substring = ns.substring(with: range)
            if let character = substring.first {
                infos.append(CharInfo(
                    character: character,
                    utf16Location: range.location,
                    utf16Length: range.length,
                    isKanji: containsKanji(character),
                    isKana: isKana(character)
                ))
            }
            index += range.length
        }
        return infos
    }

    private static func makeClusters(from chars: [CharInfo]) -> [KanjiCluster] {
        var clusters: [KanjiCluster] = []
        var index = 0
        while index < chars.count {
            if chars[index].isKanji {
                let start = index
                let startOffset = chars[index].utf16Location
                var length = chars[index].utf16Length
                index += 1
                while index < chars.count, chars[index].isKanji {
                    length += chars[index].utf16Length
                    index += 1
                }
                clusters.append(KanjiCluster(
                    charStartIndex: start,
                    charEndIndex: index,
                    utf16Location: startOffset,
                    utf16Length: length
                ))
            } else {
                index += 1
            }
        }
        return clusters
    }

    private static func nextKanaSequence(startingAt index: Int, chars: [CharInfo]) -> [Character] {
        var sequence: [Character] = []
        var idx = index
        while idx < chars.count, chars[idx].isKana {
            sequence.append(chars[idx].character)
            idx += 1
        }
        return sequence
    }

    private static func extractReadingChunk(from reading: [Character], readingIndex: inout Int, nextKana: [Character], remainingClusters: Int) -> (chunk: String, removedKanaSuffix: String) {
        guard readingIndex < reading.count else { return (chunk: "", removedKanaSuffix: "") }

        var endIndex: Int?
        if let boundary = findNextSequence(nextKana, in: reading, start: readingIndex), boundary > readingIndex {
            endIndex = boundary
        }

        var finalEnd = endIndex ?? reading.count
        if endIndex == nil, remainingClusters > 0 {
            let remaining = reading.count - readingIndex
            if remaining > 0 {
                let share = max(1, remaining / (remainingClusters + 1))
                finalEnd = min(reading.count, readingIndex + share)
            }
        }

        if finalEnd <= readingIndex {
            finalEnd = min(reading.count, readingIndex + 1)
        }

        var chunk = String(reading[readingIndex..<finalEnd])
        let trimCount = kanaSuffixTrimCount(in: chunk, nextKana: nextKana)
        var removed = ""
        if trimCount > 0, chunk.count >= trimCount {
            removed = String(chunk.suffix(trimCount))
            chunk.removeLast(trimCount)
            finalEnd -= trimCount
        }

        readingIndex = finalEnd
        return (chunk: chunk, removedKanaSuffix: removed)
    }

    private static func fallbackChunk(from reading: [Character], readingIndex: inout Int) -> (chunk: String, removedKanaSuffix: String) {
        guard readingIndex < reading.count else { return (chunk: "", removedKanaSuffix: "") }
        let next = min(reading.count, readingIndex + 1)
        let chunk = String(reading[readingIndex..<next])
        readingIndex = next
        return (chunk: chunk, removedKanaSuffix: "")
    }

    private static func consumeKanaSequence(_ sequence: [Character], in reading: [Character], from startIndex: Int) -> Int {
        guard sequence.isEmpty == false else { return startIndex }
        var idx = startIndex
        for kana in sequence {
            guard idx < reading.count else { return reading.count }
            if reading[idx] == kana {
                idx += 1
            } else if let match = findCharacter(kana, in: reading, start: idx) {
                idx = match + 1
            } else {
                return idx
            }
        }
        return idx
    }

    private static func findNextSequence(_ sequence: [Character], in reading: [Character], start: Int) -> Int? {
        guard sequence.isEmpty == false else { return nil }
        guard start < reading.count else { return nil }
        var idx = start
        while idx + sequence.count <= reading.count {
            var matches = true
            for offset in 0..<sequence.count {
                if reading[idx + offset] != sequence[offset] {
                    matches = false
                    break
                }
            }
            if matches {
                return idx
            }
            idx += 1
        }
        return nil
    }

    private static func findCharacter(_ character: Character, in reading: [Character], start: Int) -> Int? {
        guard start < reading.count else { return nil }
        var idx = start
        while idx < reading.count {
            if reading[idx] == character {
                return idx
            }
            idx += 1
        }
        return nil
    }

    private static func containsKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { kanaCharacterSet.contains($0) }
    }

    private static func kanaSuffixTrimCount(in chunk: String, nextKana: [Character]) -> Int {
        guard chunk.isEmpty == false else { return 0 }
        guard nextKana.isEmpty == false else { return 0 }
        let suffix = String(nextKana)
        guard suffix.isEmpty == false else { return 0 }
        let normalizedChunk = normalizedKana(chunk)
        let normalizedSuffix = normalizedKana(suffix)
        guard normalizedChunk.count >= normalizedSuffix.count else { return 0 }
        guard normalizedChunk.hasSuffix(normalizedSuffix) else { return 0 }
        return suffix.count
    }

    private static func normalizedKana(_ text: String) -> String {
        guard text.isEmpty == false else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    private static func normalizedKanaSequence(_ sequence: [Character]) -> [Character] {
        guard sequence.isEmpty == false else { return [] }
        return Array(normalizedKana(String(sequence)))
    }
}
