import UIKit

enum RubyTextConstants {
    static let debugBoundingDefaultStrokeColor = UIColor.systemPink.withAlphaComponent(0.9)
    static let debugBoundingDarkModeStrokeColor = UIColor(white: 1.0, alpha: 0.92)
    static let debugBoundingDashPattern: [NSNumber] = [4, 3]

    // When wrapping is disabled, we rely on a very wide text container so TextKit lays out
    // long lines without wrapping and UIScrollView has a meaningful horizontal contentSize.
    // Keep this large enough to accommodate real-world pasted text.
    static let noWrapContainerWidth: CGFloat = 200_000
}
