import SwiftUI
import UIKit
import Combine

struct SegmentedTextView: View {
    @ObservedObject var viewModel: SegmentedTextViewModel

    // Styling for selected vs normal text
    var selectedColor: Color = .yellow.opacity(0.35)

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                textStack
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                TapCaptureLayer(text: viewModel.text, font: UIFont.preferredFont(forTextStyle: .body)) { tapIndex in
                    guard let tapIndex else { return }
                    viewModel.select(at: tapIndex)
                }
            }
        }
        .padding()
    }

    private var textStack: some View {
        HStack(spacing: 0) {
            ForEach(Array(viewModel.segments.enumerated()), id: \.offset) { _, seg in
                let surface = seg.surface
                Text(surface)
                    .background(
                        Group {
                            if let sel = viewModel.selected, sel == seg {
                                Rectangle().fill(selectedColor).cornerRadius(4)
                            } else {
                                Color.clear
                            }
                        }
                    )
            }
        }
    }
}


// A transparent overlay that maps tap locations to String.Index within the text.
// It uses NSLayoutManager/TextKit to layout the string with the system body font and map point -> character index.


final class TapCaptureView: UIView {
    var text: String = ""
    var font: UIFont = .systemFont(ofSize: UIFont.labelFontSize)
    var onTapIndex: ((String.Index?) -> Void)?

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textContainer.size = bounds.size
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes([
            .font: font
        ], range: NSRange(location: 0, length: (text as NSString).length))
        textStorage.setAttributedString(attr)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: self)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(point) else {
            onTapIndex?(nil)
            return
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let ns = text as NSString
        if charIndex >= 0 && charIndex <= ns.length {
            if let idx = text.index(text.startIndex, offsetByUTF16: charIndex) {
                onTapIndex?(idx)
                return
            }
        }
        onTapIndex?(nil)
    }
}

private extension String {
    // Safe conversion from UTF-16 offset to String.Index in Swift
    func index(_ i: Index, offsetByUTF16 offset: Int) -> Index? {
        let utf16 = self.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex) else { return nil }
        guard let scalarIndex = String.Index(start, within: self) else { return nil }
        return scalarIndex
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    // Example demonstrating that JMdict-backed trie longest match selects なりたくて as one unit
    let words = ["成る", "なる", "なり", "なりたい", "なりたくて", "見る", "見ている", "日本", "日本語"]
    let trie = Trie(words: words)
    let text = "日本語を見ているけど、なりたくて困る。"
    let vm = SegmentedTextViewModel(text: text, trie: trie)
    return SegmentedTextView(viewModel: vm)
        .padding()
}
#endif
