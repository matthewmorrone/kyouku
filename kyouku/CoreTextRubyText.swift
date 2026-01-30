import SwiftUI
import UIKit
import CoreText

/// Experimental CoreText-backed ruby renderer.
///
/// Designed specifically to support the "pad headwords" requirement by forcing the base
/// headword width to match its ruby reading width (when ruby is wider).
///
/// Tradeoffs (intentional): this bypasses `RubyText`/TextKit selection + hit-testing.
struct CoreTextRubyText: UIViewRepresentable {
    var attributed: NSAttributedString
    var fontSize: CGFloat
    var extraGap: CGFloat
    var textInsets: UIEdgeInsets
    var distinctKanaKanjiFonts: Bool = false

    func makeUIView(context: Context) -> CoreTextRubyScrollView {
        let scrollView = CoreTextRubyScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.renderView.backgroundColor = .clear
        return scrollView
    }

    func updateUIView(_ uiView: CoreTextRubyScrollView, context: Context) {
        uiView.renderView.fontSize = fontSize
        uiView.renderView.extraGap = extraGap
        uiView.renderView.textInsets = textInsets
        uiView.renderView.distinctKanaKanjiFonts = distinctKanaKanjiFonts
        uiView.renderView.setAttributedText(attributed)
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }
}

final class CoreTextRubyScrollView: UIScrollView {
    let renderView = CoreTextRubyRenderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(renderView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let targetWidth = max(1, bounds.width)
        let size = renderView.sizeThatFits(CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
        renderView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
    }
}

final class CoreTextRubyRenderView: UIView {
    private static let rubyReadingKey = NSAttributedString.Key("RubyReadingText")
    private static let rubyFontSizeKey = NSAttributedString.Key("RubyReadingFontSize")

    var fontSize: CGFloat = 17
    var extraGap: CGFloat = 0
    var textInsets: UIEdgeInsets = .zero
    var distinctKanaKanjiFonts: Bool = false

    private var rawAttributed: NSAttributedString = NSAttributedString(string: "")

    // The string we actually draw (may include invisible width attachments).
    private var displayAttributed: NSAttributedString = NSAttributedString(string: "")

    // For ruby runs that got a width attachment inserted at their end, record the attachment index.
    private var rubyEndAttachmentIndexByStart: [Int: Int] = [:]

    func setAttributedText(_ text: NSAttributedString) {
        rawAttributed = text
        rebuildDisplayAttributed()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard displayAttributed.length > 0 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // UIKit is y-down; CoreText is y-up.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let contentWidth = max(1, bounds.width - (textInsets.left + textInsets.right))
        let contentHeight = max(1, bounds.height - (textInsets.top + textInsets.bottom))
        let contentRect = CGRect(x: textInsets.left, y: textInsets.bottom, width: contentWidth, height: contentHeight)

        let path = CGMutablePath()
        path.addRect(contentRect)

        let framesetter = CTFramesetterCreateWithAttributedString(displayAttributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, displayAttributed.length), path, nil)

        // Draw base text.
        CTFrameDraw(frame, ctx)

        // Draw ruby overlays.
        drawRubyOverlays(frame: frame, context: ctx)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(1, size.width)
        guard displayAttributed.length > 0 else {
            return CGSize(width: width, height: 1)
        }

        let contentWidth = max(1, width - (textInsets.left + textInsets.right))
        let framesetter = CTFramesetterCreateWithAttributedString(displayAttributed)
        let constraint = CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, displayAttributed.length),
            nil,
            constraint,
            nil
        )

        // Add insets plus a tiny rounding cushion.
        let h = ceil(fit.height + textInsets.top + textInsets.bottom + 1)
        return CGSize(width: width, height: max(1, h))
    }
}

private extension CoreTextRubyRenderView {
    func rebuildDisplayAttributed() {
        let baseFont = UIFont.systemFont(ofSize: max(1, fontSize))
        let kanjiFont = ScriptFontStyler.resolveKanjiFont(baseFont: baseFont)

        // 1) Start from the raw text and enforce base font + paragraph spacing.
        let mutable = NSMutableAttributedString(attributedString: rawAttributed)
        let fullRange = NSRange(location: 0, length: mutable.length)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, extraGap)
        paragraph.lineHeightMultiple = 1.0
        paragraph.lineBreakMode = .byWordWrapping

        mutable.addAttributes([
            .font: baseFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ], range: fullRange)

        if distinctKanaKanjiFonts {
            ScriptFontStyler.applyDistinctKanaKanjiFonts(to: mutable, kanjiFont: kanjiFont)
        }

        // 2) Apply kerning/attachments to force base width to match ruby width.
        rubyEndAttachmentIndexByStart = [:]

        // Gather ruby runs first.
        var rubyRuns: [(range: NSRange, reading: String, rubyFontSize: CGFloat)] = []
        rubyRuns.reserveCapacity(64)

        mutable.enumerateAttribute(Self.rubyReadingKey, in: fullRange, options: []) { value, range, _ in
            guard let reading = value as? String, reading.isEmpty == false else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }

            let rubySize: CGFloat = {
                if let stored = mutable.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? Double {
                    return max(1, CGFloat(stored))
                }
                if let stored = mutable.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? CGFloat {
                    return max(1, stored)
                }
                if let stored = mutable.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? NSNumber {
                    return max(1, CGFloat(stored.doubleValue))
                }
                return max(1, baseFont.pointSize * 0.6)
            }()

            rubyRuns.append((range: range, reading: reading, rubyFontSize: rubySize))
        }

        // Apply per-range adjustments.
        // IMPORTANT: insertions shift indices; collect single-glyph insertions and apply from end.
        var attachmentsToInsert: [(insertAt: Int, width: CGFloat, startKey: Int)] = []
        attachmentsToInsert.reserveCapacity(16)

        let ns = mutable.string as NSString

        for run in rubyRuns {
            let range = run.range
            guard NSMaxRange(range) <= ns.length else { continue }

            let headword = ns.substring(with: range)
            let rubyFont = UIFont.systemFont(ofSize: run.rubyFontSize)

            let baseWidth = measureWidth(string: headword, font: baseFont)
            let rubyWidth = measureWidth(string: run.reading, font: rubyFont)
            let overhang = rubyWidth - baseWidth
            if overhang <= 0.01 { continue }

            let glyphRanges = composedNonWhitespaceRanges(in: ns, range: range)
            if glyphRanges.count >= 2 {
                // Bias-free distribution:
                // - Keep spacing inside the headword (avoid a visible gap after the last glyph).
                // - Cap per-gap kern for 2-glyph words.
                // - Use `.expansion` to absorb remaining width without introducing gaps.
                let internalGapCount = max(1, glyphRanges.count - 1)
                let perGapRaw = overhang / CGFloat(internalGapCount)
                let maxPerGap = max(0.0, baseFont.pointSize * 0.22)
                let perGap = min(perGapRaw, maxPerGap)
                for r in glyphRanges.dropLast() {
                    if perGap > 0.001 {
                        mutable.addAttribute(.kern, value: perGap, range: r)
                    }
                }

                let appliedByKern = perGap * CGFloat(internalGapCount)
                let remaining = max(0.0, overhang - appliedByKern)
                if remaining > 0.01, baseWidth > 0.01 {
                    let expansion = min(0.20, remaining / baseWidth)
                    if expansion > 0.0005 {
                        mutable.addAttribute(.expansion, value: expansion, range: range)
                    }
                }
            } else if let only = glyphRanges.first {
                // Single glyph: prefer expansion to avoid introducing a visible trailing gap.
                if baseWidth > 0.01 {
                    let expansion = min(0.20, overhang / baseWidth)
                    if expansion > 0.0005 {
                        mutable.addAttribute(.expansion, value: expansion, range: only)
                    }
                }
            }
        }

        // Apply insertions from end to start to keep indices stable.
        attachmentsToInsert.sort { $0.insertAt > $1.insertAt }
        for item in attachmentsToInsert {
            let attachmentChar = "\u{FFFC}" // object replacement character
            let attr = makeWidthAttachmentAttributedString(width: item.width)
            let insert = NSMutableAttributedString(string: attachmentChar)
            insert.setAttributes(attr, range: NSRange(location: 0, length: insert.length))

            let safeIndex = max(0, min(mutable.length, item.insertAt))
            mutable.insert(insert, at: safeIndex)
            rubyEndAttachmentIndexByStart[item.startKey] = safeIndex
        }

        displayAttributed = mutable.copy() as? NSAttributedString ?? mutable
    }

    func drawRubyOverlays(frame: CTFrame, context ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard lines.isEmpty == false else { return }

        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        let fullRange = NSRange(location: 0, length: displayAttributed.length)

        // Enumerate ruby runs in displayAttributed.
        displayAttributed.enumerateAttribute(Self.rubyReadingKey, in: fullRange, options: []) { value, range, _ in
            guard let reading = value as? String, reading.isEmpty == false else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }

            let rubySize: CGFloat = {
                if let stored = displayAttributed.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? Double {
                    return max(1, CGFloat(stored))
                }
                if let stored = displayAttributed.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? CGFloat {
                    return max(1, stored)
                }
                if let stored = displayAttributed.attribute(Self.rubyFontSizeKey, at: range.location, effectiveRange: nil) as? NSNumber {
                    return max(1, CGFloat(stored.doubleValue))
                }
                return max(1, fontSize * 0.6)
            }()

            let rubyFont = UIFont.systemFont(ofSize: rubySize)
            let rubyAttrs: [NSAttributedString.Key: Any] = [
                .font: rubyFont,
                .foregroundColor: UIColor.label
            ]
            let rubyWidth = measureWidth(string: reading, font: rubyFont)

            // Determine which CTLine contains the start index.
            let startIndex = range.location
            guard let lineIndex = lineIndexContainingStringIndex(startIndex, lines: lines) else { return }

            let line = lines[lineIndex]
            let origin = origins[lineIndex]

            // Base x-range in this line.
            let startOffset = CGFloat(CTLineGetOffsetForStringIndex(line, startIndex, nil))

            // End index: if we inserted a width attachment at the end of this ruby run, include it.
            let endIndex: Int = {
                let naturalEnd = NSMaxRange(range)
                if let attachmentIndex = rubyEndAttachmentIndexByStart[range.location], attachmentIndex == naturalEnd {
                    return naturalEnd + 1
                }
                return naturalEnd
            }()
            let endOffset = CGFloat(CTLineGetOffsetForStringIndex(line, endIndex, nil))

            let baseWidth = max(0, endOffset - startOffset)

            // Center ruby over the base width.
            let x = origin.x + startOffset + ((baseWidth - rubyWidth) / 2.0)

            // Vertical placement: put ruby above the line ascent.
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let gap = max(1.0, extraGap * 0.12)
            let y = origin.y + ascent + gap

            // Draw ruby (remember: we're in flipped CoreText coords already).
            ctx.saveGState()
            ctx.textPosition = CGPoint(x: x, y: y)
            let rubyStr = NSAttributedString(string: reading, attributes: rubyAttrs)
            let rubyLine = CTLineCreateWithAttributedString(rubyStr)
            CTLineDraw(rubyLine, ctx)
            ctx.restoreGState()
        }
    }

    func lineIndexContainingStringIndex(_ index: Int, lines: [CTLine]) -> Int? {
        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            let start = r.location
            let end = r.location + r.length
            if index >= start && index < end {
                return i
            }
        }
        return nil
    }

    func measureWidth(string: String, font: UIFont) -> CGFloat {
        let attr = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func composedNonWhitespaceRanges(in text: NSString, range: NSRange) -> [NSRange] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let upper = NSMaxRange(range)
        guard upper <= text.length else { return [] }

        var out: [NSRange] = []
        out.reserveCapacity(min(8, range.length))

        var cursor = range.location
        while cursor < upper {
            let r = text.rangeOfComposedCharacterSequence(at: cursor)
            guard r.location != NSNotFound, r.length > 0 else { break }
            guard NSMaxRange(r) <= upper else { break }
            let s = text.substring(with: r)
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                out.append(r)
            }
            cursor = NSMaxRange(r)
        }
        return out
    }

    func makeWidthAttachmentAttributedString(width: CGFloat) -> [NSAttributedString.Key: Any] {
        let w = max(0, width)

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { ref in
                Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).release()
            },
            getAscent: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                // Keep attachment height 0 so it doesn't affect line ascent.
                _ = data
                return 0
            },
            getDescent: { _ in 0 },
            getWidth: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                return CGFloat(data.doubleValue)
            }
        )

        let boxed = NSNumber(value: Double(w))
        let ref = Unmanaged.passRetained(boxed).toOpaque()
        let delegate = CTRunDelegateCreate(&callbacks, ref)

        // `Unmanaged.passRetained` is balanced by `CTRunDelegateCallbacks.dealloc`.

        return [
            kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
            .foregroundColor: UIColor.clear
        ]
    }
}
