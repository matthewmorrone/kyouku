import Foundation

struct FuriganaPipelineService {
    private static func isIgnorableTokenSurfaceScalar(_ scalar: UnicodeScalar) -> Bool {
        // Regular whitespace/newlines.
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }

        // Common invisible separators that can appear in copied text.
        switch scalar.value {
        case 0x00AD: return true // soft hyphen
        case 0x034F: return true // combining grapheme joiner
        case 0x061C: return true // arabic letter mark
        case 0x180E: return true // mongolian vowel separator (deprecated but seen in the wild)
        case 0x200B: return true // zero width space
        case 0x200C: return true // zero width non-joiner
        case 0x200D: return true // zero width joiner
        case 0x2060: return true // word joiner
        case 0xFEFF: return true // zero width no-break space / BOM
        default: break
        }

        // Variation selectors (VS1..VS16) and IVS (Variation Selector Supplement).
        // These can appear in Japanese text like 朕󠄂 / 通󠄁 and render “invisible” on their own.
        if (0xFE00...0xFE0F).contains(scalar.value) { return true }
        if (0xE0100...0xE01EF).contains(scalar.value) { return true }

        return false
    }

    private static func isEffectivelyEmptyTokenSurface(_ surface: String) -> Bool {
        surface.unicodeScalars.allSatisfy { isIgnorableTokenSurfaceScalar($0) }
    }

    struct Input {
        let text: String
        let showFurigana: Bool
        let needsTokenHighlights: Bool
        let textSize: Double
        let furiganaSize: Double
        let recomputeSpans: Bool
        let existingSpans: [AnnotatedSpan]?
        let existingSemanticSpans: [SemanticSpan]
        let amendedSpans: [TextSpan]?
        let hardCuts: [Int]
        let readingOverrides: [ReadingOverride]
        let context: String
        let padHeadwordSpacing: Bool
    }

    struct Result {
        let spans: [AnnotatedSpan]?
        let semanticSpans: [SemanticSpan]
        let attributedString: NSAttributedString?
    }

    func render(_ input: Input) async -> Result {
        guard input.text.isEmpty == false else {
            return Result(spans: nil, semanticSpans: [], attributedString: nil)
        }

        var spans = input.existingSpans
        var semantic = input.existingSemanticSpans
        let hasInvalidSemantic = (spans?.isEmpty == false) && semantic.isEmpty
        if input.recomputeSpans || spans == nil || hasInvalidSemantic {
            do {
                let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                    text: input.text,
                    context: input.context,
                    tokenBoundaries: input.hardCuts,
                    readingOverrides: input.readingOverrides,
                    baseSpans: input.amendedSpans
                )
                spans = stage2.annotatedSpans
                semantic = stage2.semanticSpans
            } catch {
                CustomLogger.shared.error("\(input.context) span computation failed: \(String(describing: error))")
                return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
            }
        }

        guard let resolvedSpans = spans else {
            CustomLogger.shared.error("\(input.context) span computation returned nil even after recompute.")
            return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
        }

        // Hard invariant: semantic spans must never contain line breaks.
        // Newlines are hard boundaries for selection + dictionary lookup.
        let resolvedSemantic = Self.splitSemanticSpansOnLineBreaks(text: input.text, spans: semantic)

        let attributed: NSAttributedString?
        if input.showFurigana {
            let projected = FuriganaAttributedTextBuilder.project(
                text: input.text,
                semanticSpans: resolvedSemantic,
                textSize: input.textSize,
                furiganaSize: input.furiganaSize,
                context: input.context,
                padHeadwordSpacing: input.padHeadwordSpacing
            )
            attributed = projected
        } else {
            attributed = nil
        }

        return Result(spans: resolvedSpans, semanticSpans: resolvedSemantic, attributedString: attributed)
    }

    private static func splitSemanticSpansOnLineBreaks(text: String, spans: [SemanticSpan]) -> [SemanticSpan] {
        guard spans.isEmpty == false else { return [] }
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        var out: [SemanticSpan] = []
        out.reserveCapacity(spans.count)

        for span in spans {
            guard span.range.location != NSNotFound, span.range.length > 0 else { continue }
            guard span.range.location < length else { continue }
            let end = min(length, NSMaxRange(span.range))
            guard end > span.range.location else { continue }
            let clamped = NSRange(location: span.range.location, length: end - span.range.location)

            var cursor = clamped.location
            var pieceStart = cursor

            while cursor < end {
                let r = nsText.rangeOfComposedCharacterSequence(at: cursor)
                if r.length == 0 { break }
                let s = nsText.substring(with: r)
                let isLineBreak = (s.rangeOfCharacter(from: .newlines) != nil)
                if isLineBreak {
                    if pieceStart < r.location {
                        let piece = NSRange(location: pieceStart, length: r.location - pieceStart)
                        let surface = nsText.substring(with: piece)
                        if isEffectivelyEmptyTokenSurface(surface) == false {
                            out.append(
                                SemanticSpan(
                                    range: piece,
                                    surface: surface,
                                    sourceSpanIndices: span.sourceSpanIndices,
                                    readingKana: nil
                                )
                            )
                        }
                    }
                    pieceStart = NSMaxRange(r)
                }
                cursor = NSMaxRange(r)
            }

            if pieceStart < end {
                let piece = NSRange(location: pieceStart, length: end - pieceStart)
                let surface = nsText.substring(with: piece)
                if isEffectivelyEmptyTokenSurface(surface) == false {
                    let reading = (piece == clamped) ? span.readingKana : nil
                    out.append(
                        SemanticSpan(
                            range: piece,
                            surface: surface,
                            sourceSpanIndices: span.sourceSpanIndices,
                            readingKana: reading
                        )
                    )
                }
            }
        }

        return out
    }
}
