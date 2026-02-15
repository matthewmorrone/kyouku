import UIKit

enum TokenSpacingInvariantID {
    case leftBoundary
    case rightBoundary
    case nonOverlap
    case gapMatchesKern
    case rubyOverlapResolution
}

enum TokenSpacingInvariantSource {
    static func checkEnabled(_ invariant: TokenSpacingInvariantID) -> Bool {
        switch invariant {
        case .leftBoundary, .rightBoundary, .nonOverlap, .gapMatchesKern:
            return true
        case .rubyOverlapResolution:
            return false
        }
    }

    static func fixEnabled(_ invariant: TokenSpacingInvariantID) -> Bool {
        switch invariant {
        case .leftBoundary, .rubyOverlapResolution:
            return true
        case .rightBoundary, .nonOverlap, .gapMatchesKern:
            return false
        }
    }

    static func onePixel(in textView: TokenOverlayTextView) -> CGFloat {
        1.0 / max(1.0, textView.traitCollection.displayScale)
    }

    static func leftGuideX(in textView: TokenOverlayTextView) -> CGFloat {
        textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
    }

    static func rightGuideX(in textView: TokenOverlayTextView) -> CGFloat {
        textView.textContainerInset.left + (textView.textContainer.size.width - textView.textContainer.lineFragmentPadding)
    }

    static func leftBoundaryTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        max(onePixel(in: textView) * 2.0, 1.25)
    }

    static func rightBoundaryTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        max(onePixel(in: textView) * 2.0, 1.25)
    }

    static func overlapTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        max(onePixel(in: textView) * 1.5, 0.75)
    }

    static func kernGapTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        max(onePixel(in: textView) * 2.0, 1.25)
    }

    static func leftCrossingThreshold(in textView: TokenOverlayTextView) -> CGFloat {
        -max(onePixel(in: textView) * 2.0, 1.0)
    }

    static func alignedThreshold(in textView: TokenOverlayTextView) -> CGFloat {
        max(onePixel(in: textView) * 2.0, 1.0)
    }

    static var lineSpacerInsertionThreshold: CGFloat { 0.5 }
    static var lineSpacerResizeThreshold: CGFloat { 0.25 }
    static var rubyOverlapMinimumGap: CGFloat { 0.5 }
}
