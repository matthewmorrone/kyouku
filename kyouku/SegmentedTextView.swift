import SwiftUI
import UIKit
import Combine

final class SegmentedTextViewModel: ObservableObject {
    @Published var text: String {
        didSet {
            if oldValue != text {
                recomputeSegments()
            }
        }
    }
    @Published var trie: Trie? {
        didSet {
            // Do not recompute segments when only the trie changes; keep boundaries stable
            // for the current text. We'll recompute when `text` actually changes.
        }
    }
    @Published private(set) var segments: [Segment] = []
    @Published var selected: Segment? = nil

    private var lastSegmentedText: String = ""

    init(text: String, trie: Trie?) {
        self.text = text
        self.trie = trie
        recomputeSegments()
    }

    func recomputeSegments() {
        // Avoid resegmenting if the text hasn't changed; this prevents runtime boundary snaps
        if text == lastSegmentedText { return }
        let engine = SegmentationEngine.current()
        if engine == .dictionaryTrie {
            if let trie {
                segments = DictionarySegmenter.segment(text: text, trie: trie)
            } else if let shared = JMdictTrieCache.shared {
                segments = DictionarySegmenter.segment(text: text, trie: shared)
            } else {
                segments = AppleSegmenter.segment(text: text)
            }
        } else {
            segments = AppleSegmenter.segment(text: text)
        }
        lastSegmentedText = text
        if let sel = selected {
            if !segments.contains(where: { $0.range == sel.range }) {
                selected = nil
            }
        }
    }
    
    func invalidateSegmentation() {
        lastSegmentedText = ""
        recomputeSegments()
    }

    func select(at index: String.Index) {
        if let seg = segments.first(where: { $0.range.contains(index) }) {
            selected = seg
        } else {
            selected = nil
        }
    }
}

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
struct TapCaptureLayer: UIViewRepresentable {
    let text: String
    let font: UIFont
    let onTapIndex: (String.Index?) -> Void

    func makeUIView(context: Context) -> TapCaptureView {
        let v = TapCaptureView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.text = text
        v.font = font
        v.onTapIndex = onTapIndex
        return v
    }

    func updateUIView(_ uiView: TapCaptureView, context: Context) {
        uiView.text = text
        uiView.font = font
        uiView.onTapIndex = onTapIndex
        uiView.setNeedsLayout()
        uiView.setNeedsDisplay()
    }
}

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
