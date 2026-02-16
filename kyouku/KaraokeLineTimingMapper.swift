import Foundation

struct KaraokeRecognitionSegment: Hashable {
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var confidence: Double

    init(text: String, startSeconds: Double, durationSeconds: Double, confidence: Double) {
        let safeStart = max(0, startSeconds)
        let safeDuration = max(0, durationSeconds)
        self.text = text
        self.startSeconds = safeStart
        self.endSeconds = safeStart + safeDuration
        self.confidence = min(max(confidence, 0), 1)
    }

    init(text: String, startSeconds: Double, endSeconds: Double, confidence: Double) {
        let safeStart = max(0, startSeconds)
        self.text = text
        self.startSeconds = safeStart
        self.endSeconds = max(safeStart, endSeconds)
        self.confidence = min(max(confidence, 0), 1)
    }
}

enum KaraokeLineTimingMapper {
    private struct LyricLine {
        let text: String
        let range: NSRange
    }

    private struct LineAnchor {
        let startSeconds: Double
        let endSeconds: Double
        let confidence: Double
    }

    private struct RecognitionMap {
        let normalized: NSString
        let charToSegmentIndex: [Int]
    }

    static func lineSegments(
        for lyrics: String,
        recognition: [KaraokeRecognitionSegment],
        audioDurationSeconds: Double
    ) -> [KaraokeAlignmentSegment] {
        let lines = lyricLines(in: lyrics)
        guard lines.isEmpty == false else { return [] }

        let safeDuration = max(0, audioDurationSeconds)
        var anchors = Array<LineAnchor?>(repeating: nil, count: lines.count)

        if recognition.isEmpty == false {
            let map = buildRecognitionMap(from: recognition)
            var searchCursor = 0

            if map.normalized.length > 0 && map.charToSegmentIndex.isEmpty == false {
                for lineIndex in lines.indices {
                    let normalizedLine = normalizeForMatch(lines[lineIndex].text) as NSString
                    guard normalizedLine.length > 0 else { continue }
                    guard searchCursor < map.normalized.length else { break }

                    let searchRange = NSRange(
                        location: searchCursor,
                        length: map.normalized.length - searchCursor
                    )
                    let foundRange = map.normalized.range(
                        of: normalizedLine as String,
                        options: [],
                        range: searchRange
                    )
                    guard foundRange.location != NSNotFound else { continue }

                    let startCharIndex = foundRange.location
                    let endCharIndex = foundRange.location + foundRange.length - 1
                    guard startCharIndex >= 0,
                          endCharIndex >= startCharIndex,
                          endCharIndex < map.charToSegmentIndex.count else {
                        continue
                    }

                    let startSegmentIndex = map.charToSegmentIndex[startCharIndex]
                    let endSegmentIndex = map.charToSegmentIndex[endCharIndex]
                    guard startSegmentIndex < recognition.count,
                          endSegmentIndex < recognition.count else {
                        continue
                    }

                    let confidence = averageConfidence(
                        in: recognition,
                        startSegmentIndex: startSegmentIndex,
                        endSegmentIndex: endSegmentIndex
                    )
                    anchors[lineIndex] = LineAnchor(
                        startSeconds: recognition[startSegmentIndex].startSeconds,
                        endSeconds: recognition[endSegmentIndex].endSeconds,
                        confidence: confidence
                    )
                    searchCursor = foundRange.location + foundRange.length
                }
            }
        }

        fillMissingAnchors(&anchors, audioDurationSeconds: safeDuration)
        return buildOutputSegments(
            lines: lines,
            anchors: anchors,
            audioDurationSeconds: safeDuration
        )
    }

    private static func lyricLines(in lyrics: String) -> [LyricLine] {
        let ns = lyrics as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var lines: [LyricLine] = []

        ns.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let lineText = ns.substring(with: lineRange)
            if lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            lines.append(LyricLine(text: lineText, range: lineRange))
        }

        return lines
    }

    private static func buildRecognitionMap(from recognition: [KaraokeRecognitionSegment]) -> RecognitionMap {
        var normalized = ""
        var charToSegmentIndex: [Int] = []

        for (segmentIndex, segment) in recognition.enumerated() {
            let normalizedSegment = normalizeForMatch(segment.text)
            let normalizedLength = (normalizedSegment as NSString).length
            guard normalizedLength > 0 else { continue }

            normalized += normalizedSegment
            charToSegmentIndex.append(contentsOf: Array(repeating: segmentIndex, count: normalizedLength))
        }

        return RecognitionMap(normalized: normalized as NSString, charToSegmentIndex: charToSegmentIndex)
    }

    private static func averageConfidence(
        in recognition: [KaraokeRecognitionSegment],
        startSegmentIndex: Int,
        endSegmentIndex: Int
    ) -> Double {
        guard recognition.isEmpty == false else { return 0.05 }
        let lower = max(0, min(startSegmentIndex, endSegmentIndex))
        let upper = min(recognition.count - 1, max(startSegmentIndex, endSegmentIndex))
        guard lower <= upper else { return 0.05 }

        let matched = recognition[lower...upper]
        let total = matched.reduce(0) { partial, segment in
            partial + segment.confidence
        }
        return min(max(total / Double(matched.count), 0), 1)
    }

    private static func fillMissingAnchors(_ anchors: inout [LineAnchor?], audioDurationSeconds: Double) {
        guard anchors.isEmpty == false else { return }

        var index = 0
        while index < anchors.count {
            guard anchors[index] == nil else {
                index += 1
                continue
            }

            let runStart = index
            while index < anchors.count, anchors[index] == nil {
                index += 1
            }
            let runEnd = index - 1

            let previousEnd = previousAnchorEnd(before: runStart, in: anchors) ?? 0
            let nextStart = nextAnchorStart(after: runEnd, in: anchors) ?? audioDurationSeconds
            let safeStart = max(0, min(previousEnd, audioDurationSeconds))
            let safeEnd = max(safeStart, min(nextStart, audioDurationSeconds))
            let count = runEnd - runStart + 1
            let step = count > 0 ? (safeEnd - safeStart) / Double(count) : 0

            for offset in 0..<count {
                let start = safeStart + (step * Double(offset))
                let end = (offset == count - 1)
                    ? safeEnd
                    : safeStart + (step * Double(offset + 1))
                anchors[runStart + offset] = LineAnchor(
                    startSeconds: start,
                    endSeconds: max(start, end),
                    confidence: 0.05
                )
            }
        }
    }

    private static func previousAnchorEnd(before index: Int, in anchors: [LineAnchor?]) -> Double? {
        guard index > 0 else { return nil }
        for probe in stride(from: index - 1, through: 0, by: -1) {
            if let anchor = anchors[probe] { return anchor.endSeconds }
        }
        return nil
    }

    private static func nextAnchorStart(after index: Int, in anchors: [LineAnchor?]) -> Double? {
        guard index < anchors.count - 1 else { return nil }
        for probe in (index + 1)..<anchors.count {
            if let anchor = anchors[probe] { return anchor.startSeconds }
        }
        return nil
    }

    private static func buildOutputSegments(
        lines: [LyricLine],
        anchors: [LineAnchor?],
        audioDurationSeconds: Double
    ) -> [KaraokeAlignmentSegment] {
        guard lines.isEmpty == false else { return [] }
        let minSegmentDuration = 0.08
        var cursor = 0.0
        var segments: [KaraokeAlignmentSegment] = []
        segments.reserveCapacity(lines.count)

        for index in lines.indices {
            guard let anchor = anchors[index] else { continue }
            var start = min(max(cursor, anchor.startSeconds), audioDurationSeconds)
            var end = min(max(start, anchor.endSeconds), audioDurationSeconds)

            if end - start < minSegmentDuration && audioDurationSeconds > 0 {
                let expandedEnd = min(audioDurationSeconds, start + minSegmentDuration)
                if expandedEnd > start {
                    end = expandedEnd
                } else {
                    start = max(0, audioDurationSeconds - minSegmentDuration)
                    end = audioDurationSeconds
                }
            }

            segments.append(
                KaraokeAlignmentSegment(
                    textRange: lines[index].range,
                    startSeconds: start,
                    endSeconds: end,
                    confidence: anchor.confidence
                )
            )
            cursor = max(cursor, end)
        }

        return segments
    }

    private static func normalizeForMatch(_ value: String) -> String {
        let foldedKana = value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
        let foldedWidth = foldedKana.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? foldedKana
        let lowered = foldedWidth.lowercased()

        let scalars = lowered.unicodeScalars.filter { scalar in
            if scalar.value == 0x30FC { return true } // long vowel mark in katakana
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.punctuationCharacters.contains(scalar) { return false }
            if CharacterSet.symbols.contains(scalar) { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
