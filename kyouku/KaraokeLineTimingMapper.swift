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

    private struct TokenUnit {
        let text: String
        let normalized: String
        let range: NSRange
    }

    private struct LyricToken {
        let lineIndex: Int
        let unit: TokenUnit
    }

    private struct RecognitionToken {
        let normalized: String
        let startSeconds: Double
        let endSeconds: Double
        let confidence: Double
    }

    private struct TokenAnchor {
        let textRange: NSRange
        let startSeconds: Double
        let endSeconds: Double
        let confidence: Double
    }

    private struct LineAnchor {
        let startSeconds: Double
        let endSeconds: Double
        let confidence: Double
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

        let lyricTokens = buildLyricTokens(from: lines)
        let recognitionTokens = buildRecognitionTokens(from: recognition)
        var tokenAnchorsByLine: [Int: [TokenAnchor]] = [:]

        if lyricTokens.isEmpty == false, recognitionTokens.isEmpty == false {
            let matches = alignTokens(lyricTokens: lyricTokens, recognitionTokens: recognitionTokens)
            tokenAnchorsByLine = buildTokenAnchorsByLine(
                lyricTokens: lyricTokens,
                recognitionTokens: recognitionTokens,
                matches: matches
            )
        }

        for lineIndex in lines.indices {
            guard let tokenAnchors = tokenAnchorsByLine[lineIndex], tokenAnchors.isEmpty == false else { continue }
            let sorted = tokenAnchors.sorted { lhs, rhs in
                if lhs.startSeconds == rhs.startSeconds {
                    return lhs.endSeconds < rhs.endSeconds
                }
                return lhs.startSeconds < rhs.startSeconds
            }
            let startSeconds = sorted.first?.startSeconds ?? 0
            let endSeconds = sorted.last?.endSeconds ?? startSeconds
            let confidenceTotal = sorted.reduce(0.0) { partial, anchor in
                partial + anchor.confidence
            }
            let confidence = min(max(confidenceTotal / Double(sorted.count), 0), 1)
            anchors[lineIndex] = LineAnchor(
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                confidence: confidence
            )
        }

        fillMissingAnchors(&anchors, lines: lines, audioDurationSeconds: safeDuration)
        smoothAnchors(&anchors, lines: lines, audioDurationSeconds: safeDuration)
        return buildOutputSegments(
            lines: lines,
            anchors: anchors,
            tokenAnchorsByLine: tokenAnchorsByLine,
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

    private static func buildLyricTokens(from lines: [LyricLine]) -> [LyricToken] {
        var tokens: [LyricToken] = []
        tokens.reserveCapacity(lines.count * 8)

        for lineIndex in lines.indices {
            let units = tokenUnits(for: lines[lineIndex])
            for unit in units {
                tokens.append(LyricToken(lineIndex: lineIndex, unit: unit))
            }
        }

        return tokens
    }

    private static func buildRecognitionTokens(from recognition: [KaraokeRecognitionSegment]) -> [RecognitionToken] {
        var tokens: [RecognitionToken] = []
        tokens.reserveCapacity(recognition.count * 8)

        for segment in recognition {
            let ns = segment.text as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let duration = max(0, segment.endSeconds - segment.startSeconds)

            ns.enumerateSubstrings(in: fullRange, options: [.byComposedCharacterSequences]) { substring, substringRange, _, _ in
                guard let substring else { return }
                guard shouldIgnoreUnit(substring) == false else { return }

                let normalized = normalizeForMatch(substring)
                guard normalized.isEmpty == false else { return }

                let denominator = Double(max(ns.length, 1))
                let relativeStart = Double(substringRange.location) / denominator
                let relativeEnd = Double(NSMaxRange(substringRange)) / denominator

                let startSeconds = segment.startSeconds + (duration * relativeStart)
                let endSeconds = segment.startSeconds + (duration * relativeEnd)

                tokens.append(
                    RecognitionToken(
                        normalized: normalized,
                        startSeconds: startSeconds,
                        endSeconds: max(startSeconds, endSeconds),
                        confidence: segment.confidence
                    )
                )
            }
        }

        return tokens
    }

    private static func alignTokens(
        lyricTokens: [LyricToken],
        recognitionTokens: [RecognitionToken]
    ) -> [(lyricIndex: Int, recognitionIndex: Int, similarity: Double)] {
        let gapPenalty = -0.7
        let lyricCount = lyricTokens.count
        let recognitionCount = recognitionTokens.count

        guard lyricCount > 0, recognitionCount > 0 else { return [] }

        enum BacktrackStep {
            case diagonal
            case up
            case left
        }

        var scores = Array(
            repeating: Array(repeating: 0.0, count: recognitionCount + 1),
            count: lyricCount + 1
        )
        var steps: [[BacktrackStep]] = Array(
            repeating: Array(repeating: .left, count: recognitionCount + 1),
            count: lyricCount + 1
        )

        if lyricCount > 0 {
            for lyricIndex in 1...lyricCount {
                scores[lyricIndex][0] = Double(lyricIndex) * gapPenalty
                steps[lyricIndex][0] = .up
            }
        }
        if recognitionCount > 0 {
            for recognitionIndex in 1...recognitionCount {
                scores[0][recognitionIndex] = Double(recognitionIndex) * gapPenalty
                steps[0][recognitionIndex] = .left
            }
        }

        if lyricCount > 0 && recognitionCount > 0 {
            for lyricIndex in 1...lyricCount {
                for recognitionIndex in 1...recognitionCount {
                    let similarity = tokenSimilarity(
                        lyricTokens[lyricIndex - 1].unit.normalized,
                        recognitionTokens[recognitionIndex - 1].normalized
                    )
                    let matchScore = (similarity * 2.2) + (recognitionTokens[recognitionIndex - 1].confidence * 0.4) - 1.0
                    let diagonalScore = scores[lyricIndex - 1][recognitionIndex - 1] + matchScore
                    let upScore = scores[lyricIndex - 1][recognitionIndex] + gapPenalty
                    let leftScore = scores[lyricIndex][recognitionIndex - 1] + gapPenalty

                    if diagonalScore >= upScore, diagonalScore >= leftScore {
                        scores[lyricIndex][recognitionIndex] = diagonalScore
                        steps[lyricIndex][recognitionIndex] = .diagonal
                    } else if upScore >= leftScore {
                        scores[lyricIndex][recognitionIndex] = upScore
                        steps[lyricIndex][recognitionIndex] = .up
                    } else {
                        scores[lyricIndex][recognitionIndex] = leftScore
                        steps[lyricIndex][recognitionIndex] = .left
                    }
                }
            }
        }

        var lyricIndex = lyricCount
        var recognitionIndex = recognitionCount
        var matches: [(lyricIndex: Int, recognitionIndex: Int, similarity: Double)] = []

        while lyricIndex > 0 || recognitionIndex > 0 {
            let step = steps[lyricIndex][recognitionIndex]
            switch step {
            case .diagonal:
                let similarity = tokenSimilarity(
                    lyricTokens[lyricIndex - 1].unit.normalized,
                    recognitionTokens[recognitionIndex - 1].normalized
                )
                if similarity >= 0.62 {
                    matches.append((
                        lyricIndex: lyricIndex - 1,
                        recognitionIndex: recognitionIndex - 1,
                        similarity: similarity
                    ))
                }
                lyricIndex -= 1
                recognitionIndex -= 1
            case .up:
                lyricIndex -= 1
            case .left:
                recognitionIndex -= 1
            }
        }

        matches.reverse()
        return matches
    }

    private static func buildTokenAnchorsByLine(
        lyricTokens: [LyricToken],
        recognitionTokens: [RecognitionToken],
        matches: [(lyricIndex: Int, recognitionIndex: Int, similarity: Double)]
    ) -> [Int: [TokenAnchor]] {
        var grouped: [Int: [TokenAnchor]] = [:]

        for match in matches {
            guard match.lyricIndex < lyricTokens.count,
                  match.recognitionIndex < recognitionTokens.count else {
                continue
            }

            let lyricToken = lyricTokens[match.lyricIndex]
            let recognitionToken = recognitionTokens[match.recognitionIndex]
            let confidence = min(max(recognitionToken.confidence * match.similarity, 0), 1)

            grouped[lyricToken.lineIndex, default: []].append(
                TokenAnchor(
                    textRange: lyricToken.unit.range,
                    startSeconds: recognitionToken.startSeconds,
                    endSeconds: recognitionToken.endSeconds,
                    confidence: confidence
                )
            )
        }

        return grouped
    }

    private static func fillMissingAnchors(
        _ anchors: inout [LineAnchor?],
        lines: [LyricLine],
        audioDurationSeconds: Double
    ) {
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

            var weights: [Double] = []
            weights.reserveCapacity(count)
            for probe in runStart...runEnd {
                weights.append(timingWeight(for: lines[probe]))
            }
            let weightTotal = weights.reduce(0, +)
            var cursor = safeStart

            for offset in 0..<count {
                let start = cursor
                let isLast = (offset == count - 1)
                let end: Double
                if isLast {
                    end = safeEnd
                } else if weightTotal > 0 {
                    let ratio = weights[offset] / weightTotal
                    end = min(safeEnd, cursor + ((safeEnd - safeStart) * ratio))
                } else {
                    end = start
                }

                anchors[runStart + offset] = LineAnchor(
                    startSeconds: start,
                    endSeconds: max(start, end),
                    confidence: 0.05
                )
                cursor = max(cursor, end)
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

    private static func smoothAnchors(
        _ anchors: inout [LineAnchor?],
        lines: [LyricLine],
        audioDurationSeconds: Double
    ) {
        guard anchors.isEmpty == false else { return }
        guard lines.count == anchors.count else { return }

        let lineWeights = lines.map { line in
            Double(max(1, (normalizeForMatch(line.text) as NSString).length))
        }
        let totalWeight = max(lineWeights.reduce(0, +), 1)
        let totalDuration = max(0, audioDurationSeconds)

        var smoothed: [LineAnchor?] = anchors
        var cursor = 0.0

        for index in lines.indices {
            guard let anchor = anchors[index] else { continue }

            let confidence = min(max(anchor.confidence, 0), 1)
            let smoothingIntensity = max(0, min(1, (0.82 - confidence) / 0.82))
            let priorWeight = smoothingIntensity
            let observedDuration = max(0, anchor.endSeconds - anchor.startSeconds)
            let expectedDuration = totalDuration * (lineWeights[index] / totalWeight)
            let blendedDuration = (observedDuration * (1.0 - priorWeight)) + (expectedDuration * priorWeight)

            let minDuration = minDurationForLine(lines[index])
            let maxDuration = maxDurationForLine(lines[index], audioDurationSeconds: totalDuration)
            let targetDuration: Double
            if smoothingIntensity > 0 {
                targetDuration = min(max(blendedDuration, minDuration), maxDuration)
            } else {
                targetDuration = observedDuration
            }

            let continuityWeight = 0.4 * smoothingIntensity
            var start = anchor.startSeconds + ((cursor - anchor.startSeconds) * continuityWeight)
            start = min(max(start, cursor), totalDuration)

            let remainingMinDuration = minimumRequiredDuration(
                in: lines,
                from: index + 1,
                audioDurationSeconds: totalDuration
            )
            let maxAllowedEnd = max(start, totalDuration - remainingMinDuration)
            let lowerBoundDuration = smoothingIntensity > 0 ? minDuration : 0
            var end = min(max(start + targetDuration, start + lowerBoundDuration), maxAllowedEnd)
            if end < start {
                end = start
            }

            smoothed[index] = LineAnchor(
                startSeconds: start,
                endSeconds: end,
                confidence: confidence
            )
            cursor = end
        }

          if let lastIndex = lines.indices.last,
              let last = smoothed[lastIndex],
              totalDuration > 0,
              last.confidence <= 0.15 {
            let clampedStart = min(max(last.startSeconds, 0), totalDuration)
            let minDuration = minDurationForLine(lines[lastIndex])
            let desiredEnd = max(clampedStart + minDuration, totalDuration)
            let end = min(max(desiredEnd, clampedStart), totalDuration)
            smoothed[lastIndex] = LineAnchor(
                startSeconds: clampedStart,
                endSeconds: end,
                confidence: last.confidence
            )
        }

        anchors = smoothed
    }

    private static func minimumRequiredDuration(
        in lines: [LyricLine],
        from startIndex: Int,
        audioDurationSeconds: Double
    ) -> Double {
        guard startIndex < lines.count else { return 0 }
        let total = lines[startIndex...].reduce(0.0) { partial, line in
            partial + minDurationForLine(line)
        }
        return min(max(total, 0), max(0, audioDurationSeconds))
    }

    private static func minDurationForLine(_ line: LyricLine) -> Double {
        let normalizedLength = max(1, (normalizeForMatch(line.text) as NSString).length)
        let scaled = 0.06 + (0.012 * Double(normalizedLength))
        return min(max(scaled, 0.07), 0.45)
    }

    private static func maxDurationForLine(_ line: LyricLine, audioDurationSeconds: Double) -> Double {
        let normalizedLength = max(1, (normalizeForMatch(line.text) as NSString).length)
        let scaled = 0.18 + (0.24 * Double(normalizedLength))
        let maxFromAudio = max(0.22, audioDurationSeconds)
        return min(max(scaled, 0.22), maxFromAudio)
    }

    private static func buildOutputSegments(
        lines: [LyricLine],
        anchors: [LineAnchor?],
        tokenAnchorsByLine: [Int: [TokenAnchor]],
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

            let tokenSegments = buildTokenSegments(
                for: lines[index],
                tokenAnchors: tokenAnchorsByLine[index] ?? [],
                lineStartSeconds: start,
                lineEndSeconds: end,
                lineConfidence: anchor.confidence
            )
            let phraseSegments = buildPhraseSegments(
                for: lines[index],
                tokenSegments: tokenSegments,
                lineStartSeconds: start,
                lineEndSeconds: end,
                lineConfidence: anchor.confidence
            )

            segments.append(
                KaraokeAlignmentSegment(
                    textRange: lines[index].range,
                    startSeconds: start,
                    endSeconds: end,
                    confidence: anchor.confidence,
                    phraseSegments: phraseSegments.isEmpty ? nil : phraseSegments,
                    tokenSegments: tokenSegments.isEmpty ? nil : tokenSegments
                )
            )
            cursor = max(cursor, end)
        }

        return segments
    }

    private static func buildTokenSegments(
        for line: LyricLine,
        tokenAnchors: [TokenAnchor],
        lineStartSeconds: Double,
        lineEndSeconds: Double,
        lineConfidence: Double
    ) -> [KaraokeAlignmentChildSegment] {
        let minTokenDuration = 0.03
        let spanDuration = max(0, lineEndSeconds - lineStartSeconds)
        guard spanDuration > 0 else { return [] }

        let units = tokenUnits(for: line)
        guard units.isEmpty == false else { return [] }

        if tokenAnchors.isEmpty == false {
            let sortedAnchors = tokenAnchors.sorted { lhs, rhs in
                if lhs.textRange.location == rhs.textRange.location {
                    return lhs.textRange.length < rhs.textRange.length
                }
                return lhs.textRange.location < rhs.textRange.location
            }

            var children: [KaraokeAlignmentChildSegment] = []
            children.reserveCapacity(sortedAnchors.count)
            var cursor = lineStartSeconds

            for anchor in sortedAnchors {
                let clampedStart = min(max(anchor.startSeconds, cursor), lineEndSeconds)
                var clampedEnd = min(max(anchor.endSeconds, clampedStart), lineEndSeconds)
                if clampedEnd - clampedStart < minTokenDuration {
                    clampedEnd = min(lineEndSeconds, clampedStart + minTokenDuration)
                }

                children.append(
                    KaraokeAlignmentChildSegment(
                        granularity: .token,
                        textRange: anchor.textRange,
                        startSeconds: clampedStart,
                        endSeconds: clampedEnd,
                        confidence: anchor.confidence
                    )
                )
                cursor = max(cursor, clampedEnd)
            }

            if children.isEmpty == false {
                return children
            }
        }

        let totalWeight = units.reduce(0.0) { partial, unit in
            partial + Double(max(1, (unit.normalized as NSString).length))
        }
        guard totalWeight > 0 else { return [] }

        var cursor = lineStartSeconds
        var children: [KaraokeAlignmentChildSegment] = []
        children.reserveCapacity(units.count)

        for unitIndex in units.indices {
            let unit = units[unitIndex]
            let weight = Double(max(1, (unit.normalized as NSString).length))
            let duration = spanDuration * (weight / totalWeight)
            let isLast = (unitIndex == units.count - 1)
            let end = isLast ? lineEndSeconds : min(lineEndSeconds, cursor + duration)

            children.append(
                KaraokeAlignmentChildSegment(
                    granularity: .token,
                    textRange: unit.range,
                    startSeconds: cursor,
                    endSeconds: max(cursor, end),
                    confidence: lineConfidence * 0.8
                )
            )
            cursor = max(cursor, end)
        }

        return children
    }

    private static func buildPhraseSegments(
        for line: LyricLine,
        tokenSegments: [KaraokeAlignmentChildSegment],
        lineStartSeconds: Double,
        lineEndSeconds: Double,
        lineConfidence: Double
    ) -> [KaraokeAlignmentChildSegment] {
        let ranges = phraseRanges(for: line)
        guard ranges.isEmpty == false else { return [] }

        var weights: [Double] = []
        weights.reserveCapacity(ranges.count)

        for range in ranges {
            let phraseText = (line.text as NSString).substring(with: NSRange(
                location: range.location - line.range.location,
                length: range.length
            ))
            let normalizedLength = max(1, (normalizeForMatch(phraseText) as NSString).length)
            weights.append(Double(normalizedLength))
        }

        let weightTotal = max(weights.reduce(0, +), 1)
        var fallbackCursor = lineStartSeconds
        let spanDuration = max(0, lineEndSeconds - lineStartSeconds)

        var phraseSegments: [KaraokeAlignmentChildSegment] = []
        phraseSegments.reserveCapacity(ranges.count)

        for rangeIndex in ranges.indices {
            let phraseRange = ranges[rangeIndex]
            let overlappingTokens = tokenSegments.filter { token in
                NSIntersectionRange(token.textRange.nsRange, phraseRange).length > 0
            }

            if overlappingTokens.isEmpty == false {
                let start = overlappingTokens.first?.startSeconds ?? lineStartSeconds
                let end = overlappingTokens.last?.endSeconds ?? start
                let confidence = min(max(
                    overlappingTokens.reduce(0.0) { partial, token in
                        partial + token.confidence
                    } / Double(overlappingTokens.count),
                    0
                ), 1)

                phraseSegments.append(
                    KaraokeAlignmentChildSegment(
                        granularity: .phrase,
                        textRange: phraseRange,
                        startSeconds: start,
                        endSeconds: max(start, end),
                        confidence: confidence
                    )
                )
                continue
            }

            let isLast = (rangeIndex == ranges.count - 1)
            let duration = spanDuration * (weights[rangeIndex] / weightTotal)
            let end = isLast ? lineEndSeconds : min(lineEndSeconds, fallbackCursor + duration)

            phraseSegments.append(
                KaraokeAlignmentChildSegment(
                    granularity: .phrase,
                    textRange: phraseRange,
                    startSeconds: fallbackCursor,
                    endSeconds: max(fallbackCursor, end),
                    confidence: lineConfidence * 0.85
                )
            )
            fallbackCursor = max(fallbackCursor, end)
        }

        return phraseSegments
    }

    private static func phraseRanges(for line: LyricLine) -> [NSRange] {
        let ns = line.text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard fullRange.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var phraseStart = 0

        ns.enumerateSubstrings(in: fullRange, options: [.byComposedCharacterSequences]) { substring, substringRange, _, _ in
            guard let substring else { return }

            let shouldSplit = phraseSplitCharacterSet.contains(substring)
            if shouldSplit {
                let end = NSMaxRange(substringRange)
                let localRange = NSRange(location: phraseStart, length: end - phraseStart)
                let absoluteRange = NSRange(
                    location: line.range.location + localRange.location,
                    length: localRange.length
                )
                if localRange.length > 0,
                   shouldIgnoreRange(localRange, in: line.text) == false {
                    ranges.append(absoluteRange)
                }
                phraseStart = end
            }
        }

        if phraseStart < ns.length {
            let localRange = NSRange(location: phraseStart, length: ns.length - phraseStart)
            let absoluteRange = NSRange(
                location: line.range.location + localRange.location,
                length: localRange.length
            )
            if localRange.length > 0,
               shouldIgnoreRange(localRange, in: line.text) == false {
                ranges.append(absoluteRange)
            }
        }

        if ranges.isEmpty {
            return [line.range]
        }

        return ranges
    }

    private static func shouldIgnoreRange(_ localRange: NSRange, in lineText: String) -> Bool {
        let ns = lineText as NSString
        guard localRange.location >= 0,
              NSMaxRange(localRange) <= ns.length else {
            return true
        }
        let substring = ns.substring(with: localRange)
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func tokenUnits(for line: LyricLine) -> [TokenUnit] {
        let ns = line.text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var units: [TokenUnit] = []
        units.reserveCapacity(max(1, ns.length))

        ns.enumerateSubstrings(in: fullRange, options: [.byComposedCharacterSequences]) { substring, substringRange, _, _ in
            guard let substring else { return }
            guard shouldIgnoreUnit(substring) == false else { return }

            let normalized = normalizeForMatch(substring)
            guard normalized.isEmpty == false else { return }

            let absoluteRange = NSRange(
                location: line.range.location + substringRange.location,
                length: substringRange.length
            )
            units.append(
                TokenUnit(
                    text: substring,
                    normalized: normalized,
                    range: absoluteRange
                )
            )
        }

        return units
    }

    private static func shouldIgnoreUnit(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func timingWeight(for line: LyricLine) -> Double {
        let normalizedLength = max(1, (normalizeForMatch(line.text) as NSString).length)
        var pauseWeight = 0.0
        for scalar in line.text.unicodeScalars {
            switch scalar {
            case "、", ",":
                pauseWeight += 0.55
            case "。", "！", "？", "!", "?", "…":
                pauseWeight += 0.9
            default:
                continue
            }
        }
        return Double(normalizedLength) + pauseWeight
    }

    private static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs {
            return 1
        }

        let lhsValue = lhs as NSString
        let rhsValue = rhs as NSString
        let maxLength = max(lhsValue.length, rhsValue.length)
        guard maxLength > 0 else { return 0 }

        let distance = levenshteinDistance(lhs, rhs)
        let similarity = 1.0 - (Double(distance) / Double(maxLength))
        return max(0, min(similarity, 1))
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        guard lhsChars.isEmpty == false else { return rhsChars.count }
        guard rhsChars.isEmpty == false else { return lhsChars.count }

        var distances = Array(0...rhsChars.count)

        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var previousDiagonal = distances[0]
            distances[0] = lhsIndex + 1

            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let temp = distances[rhsIndex + 1]
                let substitutionCost = lhsChar == rhsChar ? 0 : 1
                distances[rhsIndex + 1] = min(
                    distances[rhsIndex + 1] + 1,
                    distances[rhsIndex] + 1,
                    previousDiagonal + substitutionCost
                )
                previousDiagonal = temp
            }
        }

        return distances[rhsChars.count]
    }

    private static let phraseSplitCharacterSet: Set<String> = [
        "、", ",", "。", "！", "？", "!", "?", "…", "・", ";", "；", ":", "："
    ]

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
