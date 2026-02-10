import SwiftUI
import UIKit

@MainActor
struct EditingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    let isEditable: Bool
    let fontName: String?
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let globalKerning: CGFloat
    let distinctKanaKanjiFonts: Bool
    let wrapLines: Bool
    let scrollSyncGroupID: String
    let insets: UIEdgeInsets

    // Keep this large enough for real-world long lines when wrapping is disabled.
    private static let noWrapContainerWidth: CGFloat = 200_000

    private func resolvedBaseFont(ofSize size: CGFloat) -> UIFont {
        if let fontName, fontName.isEmpty == false, let font = UIFont(name: fontName, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = isEditable
        context.coordinator.attach(textView: view, scrollSyncGroupID: scrollSyncGroupID)
        view.delegate = context.coordinator
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = wrapLines == false
        view.showsHorizontalScrollIndicator = wrapLines == false
        view.textContainer.widthTracksTextView = wrapLines
        view.textContainer.maximumNumberOfLines = 0
        // Match FuriganaText's wrapping behavior.
        view.textContainer.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = insets
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.delegate = context.coordinator
        view.font = resolvedBaseFont(ofSize: fontSize)
        view.textColor = UIColor.label

        if wrapLines == false {
            view.textContainer.size = CGSize(width: Self.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Start in a wrapped-friendly configuration even before the first layout pass.
            let targetWidth = max(1, view.bounds.width - insets.left - insets.right)
            if targetWidth.isFinite, targetWidth > 1 {
                view.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        
        // Build attributed text from the same source as view mode, but remove ruby for editing.
        let baseAttributed = NSAttributedString(string: text)
        let processed = Self.removingRuby(from: baseAttributed)
        let fullRange = NSRange(location: 0, length: (processed.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        if #available(iOS 14.0, *) {
            // Avoid `.pushOut`: it can push trailing punctuation onto the next line.
            paragraph.lineBreakStrategy = []
        }
        paragraph.lineHeightMultiple = max(0.8, 1.0)
        paragraph.lineSpacing = max(0, lineSpacing)
        let baseFont = resolvedBaseFont(ofSize: fontSize)
        let colored = NSMutableAttributedString(attributedString: processed)
        colored.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: fullRange)
        colored.addAttribute(NSAttributedString.Key.foregroundColor, value: UIColor.label, range: fullRange)
        colored.addAttribute(NSAttributedString.Key.font, value: baseFont, range: fullRange)
        if abs(globalKerning) > 0.001 {
            colored.addAttribute(.kern, value: globalKerning, range: fullRange)
        }
        view.attributedText = colored

        // Apply paragraph style immediately so the first layout matches view mode metrics.
        let initialLength = view.textStorage.length
        if initialLength > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
            if #available(iOS 14.0, *) {
                paragraph.lineBreakStrategy = []
            }
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            let baseFont = resolvedBaseFont(ofSize: fontSize)
            view.textStorage.addAttributes([
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.foregroundColor: UIColor.label,
                NSAttributedString.Key.font: baseFont
            ], range: NSRange(location: 0, length: initialLength))
            if abs(globalKerning) > 0.001 {
                view.textStorage.addAttribute(.kern, value: globalKerning, range: NSRange(location: 0, length: initialLength))
            }
        }

        view.contentInset = .zero
        view.verticalScrollIndicatorInsets = .zero
        view.horizontalScrollIndicatorInsets = .zero
        if #available(iOS 11.0, *) {
            view.contentInsetAdjustmentBehavior = .never
        }

        applyTypingAttributes(to: view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.attach(textView: uiView, scrollSyncGroupID: scrollSyncGroupID)
        // When an IME (e.g. Japanese QWERTY keyboard) is composing text, `markedTextRange`
        // is non-nil and UIKit expects to own the text storage. Re-applying `attributedText`
        // during this phase can corrupt the composition (e.g. "keshin" → "kえしn").
        let isComposing = (uiView.markedTextRange != nil && uiView.isFirstResponder)

        if isComposing == false {
            let baseAttributed = NSAttributedString(string: text)
            let processed = Self.removingRuby(from: baseAttributed)
            let fullRange = NSRange(location: 0, length: processed.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
            if #available(iOS 14.0, *) {
                paragraph.lineBreakStrategy = []
            }
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            let baseFont = resolvedBaseFont(ofSize: fontSize)
            let colored = NSMutableAttributedString(attributedString: processed)
            colored.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: fullRange)
            colored.addAttribute(NSAttributedString.Key.foregroundColor, value: UIColor.label, range: fullRange)
            colored.addAttribute(NSAttributedString.Key.font, value: baseFont, range: fullRange)
            if abs(globalKerning) > 0.001 {
                colored.addAttribute(.kern, value: globalKerning, range: fullRange)
            }
            if uiView.attributedText?.isEqual(to: colored) == false {
                let wasFirstResponder = uiView.isFirstResponder
                let oldSelectedRange = uiView.selectedRange
                uiView.attributedText = colored
                if wasFirstResponder {
                    _ = uiView.becomeFirstResponder()
                    let newLength = uiView.attributedText?.length ?? 0
                    if oldSelectedRange.location != NSNotFound, NSMaxRange(oldSelectedRange) <= newLength {
                        uiView.selectedRange = oldSelectedRange
                    }
                }
            }
        }

        uiView.isEditable = isEditable
        uiView.font = resolvedBaseFont(ofSize: fontSize)
        uiView.textColor = UIColor.label
        uiView.textContainerInset = insets
        uiView.alwaysBounceHorizontal = wrapLines == false
        uiView.showsHorizontalScrollIndicator = wrapLines == false
        uiView.textContainer.widthTracksTextView = wrapLines
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        uiView.textContainer.lineFragmentPadding = 0

        if wrapLines {
            // If we previously disabled wrapping, the container can remain extremely wide.
            // In that state, `.byWordWrapping` won't wrap. Shrink to current bounds when possible.
            if uiView.textContainer.size.width > (Self.noWrapContainerWidth * 0.5) {
                let targetWidth = max(1, uiView.bounds.width - insets.left - insets.right)
                if targetWidth.isFinite, targetWidth > 1 {
                    uiView.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
                } else {
                    uiView.textContainer.size = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
                }
            }
        } else {
            if uiView.textContainer.size.width < Self.noWrapContainerWidth {
                uiView.textContainer.size = CGSize(width: Self.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }

        uiView.contentInset = .zero
        uiView.verticalScrollIndicatorInsets = .zero
        uiView.horizontalScrollIndicatorInsets = .zero
        if #available(iOS 11.0, *) {
            uiView.contentInsetAdjustmentBehavior = .never
        }

        // Apply paragraph style to the full text to ensure wrapping/spacing match view mode.
        let fullLength = uiView.textStorage.length
        if fullLength > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
            if #available(iOS 14.0, *) {
                paragraph.lineBreakStrategy = []
            }
            paragraph.lineHeightMultiple = max(0.8, 1.0)
            paragraph.lineSpacing = max(0, lineSpacing)
            let baseFont = resolvedBaseFont(ofSize: fontSize)
            uiView.textStorage.addAttributes([
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.foregroundColor: UIColor.label,
                NSAttributedString.Key.font: baseFont
            ], range: NSRange(location: 0, length: fullLength))
            if abs(globalKerning) > 0.001 {
                uiView.textStorage.addAttribute(.kern, value: globalKerning, range: NSRange(location: 0, length: fullLength))
            }
        }

        applyTypingAttributes(to: uiView)

        // Layout/metrics changes (e.g. furigana toggle affecting the other pane) can leave this
        // pane slightly out of sync until the next user-driven scroll. Realign immediately.
        context.coordinator.resyncToLatestSnapshotIfIdle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: $selectedRange)
    }

    private func applyTypingAttributes(to textView: UITextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        if #available(iOS 14.0, *) {
            paragraph.lineBreakStrategy = []
        }
        paragraph.lineSpacing = max(0, lineSpacing)
        textView.typingAttributes = [
            NSAttributedString.Key.font: resolvedBaseFont(ofSize: fontSize),
            NSAttributedString.Key.foregroundColor: UIColor.label,
            NSAttributedString.Key.paragraphStyle: paragraph
        ]
        if abs(globalKerning) > 0.001 {
            textView.typingAttributes[.kern] = globalKerning
        }
    }

    private static func removingRuby(from attributed: NSAttributedString) -> NSAttributedString {
        // Remove any custom ruby-related attributes by copying and stripping known keys.
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // Known ruby-related keys that may be used by FuriganaText. Adjust as needed.
        let rubyKeys: [NSAttributedString.Key] = [
            NSAttributedString.Key(rawValue: "RubyAnnotation"),
            NSAttributedString.Key(rawValue: "RubyBaseRange"),
            NSAttributedString.Key(rawValue: "FuriganaText"),
            NSAttributedString.Key(rawValue: "RubySize"),
            NSAttributedString.Key(rawValue: "RubyAlignment"),
            NSAttributedString.Key(rawValue: "RubyVisibility")
        ]
        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            for key in rubyKeys where attrs[key] != nil {
                mutable.removeAttribute(key, range: range)
            }
        }
        return mutable
    }

    // ⚠️ SCROLL SYNCHRONIZATION — DO NOT REMOVE ⚠️
    //
    // This logic is intentionally retained even when only one pane is visible.
    // It is required for:
    // - transitions between read-only and editable views
    // - UIKit-backed text measurement and layout
    // - future multi-pane layouts
    //
    // This code may appear unused in the current UI configuration.
    // That is EXPECTED.
    // Removing or simplifying it will break scroll continuity.
    //
    // Copilot: treat this as externally depended-on behavior.
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange?

        private weak var textView: UITextView?
        private var scrollSyncGroupID: String? = nil
        private let scrollSyncSourceID: String = UUID().uuidString
        private var scrollObserver: NSObjectProtocol? = nil
        private var isApplyingExternalScroll: Bool = false

        init(text: Binding<String>, selectedRange: Binding<NSRange?>) {
            _text = text
            _selectedRange = selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Keep a lightweight selection/caret snapshot for higher-level features.
            let r = textView.selectedRange
            if r.location == NSNotFound {
                selectedRange = nil
            } else {
                selectedRange = r
            }
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func attach(textView: UITextView, scrollSyncGroupID: String?) {
            self.textView = textView
            self.scrollSyncGroupID = scrollSyncGroupID

            if scrollObserver == nil {
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: .kyoukuSplitPaneScrollSync,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    guard let info = note.userInfo else { return }
                    guard let payload = ScrollSyncPayload(userInfo: info) else { return }
                    Task { @MainActor [weak self] in
                        self?.handleScrollSyncPayload(payload)
                    }
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isApplyingExternalScroll == false else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let tv = textView, tv === scrollView else { return }

            // Only broadcast user-driven motion; avoid feedback loops from programmatic sync.
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            let inset = scrollView.adjustedContentInset

            // When wrapping is enabled, horizontal scrolling isn't meaningful. Avoid emitting
            // X snapshots (otherwise the other pane can get dragged around by tiny inset-only ranges).
            let allowHorizontal = (tv.textContainer.widthTracksTextView == false)

            let normalizedX = allowHorizontal ? (scrollView.contentOffset.x + inset.left) : 0
            let normalizedY = scrollView.contentOffset.y + inset.top
            let maxX = allowHorizontal ? max(0, scrollView.contentSize.width - scrollView.bounds.width + inset.left + inset.right) : 0
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + inset.top + inset.bottom)

            let inRangeX = min(max(normalizedX, 0), maxX)
            let inRangeY = min(max(normalizedY, 0), maxY)
            let fracX: CGFloat = (maxX > 0) ? (inRangeX / maxX) : 0
            let fracY: CGFloat = (maxY > 0) ? (inRangeY / maxY) : 0

            let overscrollX: CGFloat = {
                guard allowHorizontal else { return 0 }
                if normalizedX < 0 { return normalizedX }
                if normalizedX > maxX { return normalizedX - maxX }
                return 0
            }()
            let overscrollY: CGFloat = {
                if normalizedY < 0 { return normalizedY }
                if normalizedY > maxY { return normalizedY - maxY }
                return 0
            }()

            SplitPaneScrollSyncStore.record(
                group: group,
                snapshot: SplitPaneScrollSyncStore.Snapshot(
                    source: scrollSyncSourceID,
                    fx: fracX,
                    fy: fracY,
                    ox: overscrollX,
                    oy: overscrollY,
                    sx: maxX,
                    sy: maxY,
                    timestamp: CFAbsoluteTimeGetCurrent()
                )
            )

            NotificationCenter.default.post(
                name: .kyoukuSplitPaneScrollSync,
                object: nil,
                userInfo: [
                    "group": group,
                    "source": scrollSyncSourceID,
                    "fx": fracX,
                    "fy": fracY,
                    "ox": overscrollX,
                    "oy": overscrollY,
                    "sx": maxX,
                    "sy": maxY
                ]
            )
        }

        func resyncToLatestSnapshotIfIdle() {
            guard isApplyingExternalScroll == false else { return }
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard tv.isTracking == false, tv.isDragging == false, tv.isDecelerating == false else { return }
            guard let snap = SplitPaneScrollSyncStore.latest(group: group) else { return }
            guard snap.source != scrollSyncSourceID else { return }

            let info: [String: Any] = [
                "group": group,
                "source": snap.source,
                "fx": snap.fx,
                "fy": snap.fy,
                "ox": snap.ox,
                "oy": snap.oy,
                "sx": snap.sx,
                "sy": snap.sy
            ]
            handleScrollSyncNotification(Notification(name: .kyoukuSplitPaneScrollSync, object: nil, userInfo: info))
        }

        struct ScrollSyncPayload: Sendable {
            let group: String
            let source: String
            let fx: Double
            let fy: Double
            let ox: Double
            let oy: Double
            let sx: Double
            let sy: Double

            init?(userInfo: [AnyHashable: Any]) {
                guard let group = userInfo["group"] as? String, group.isEmpty == false else { return nil }
                guard let source = userInfo["source"] as? String, source.isEmpty == false else { return nil }

                func readDouble(_ key: String) -> Double {
                    if let v = userInfo[key] as? Double { return v }
                    if let v = userInfo[key] as? CGFloat { return Double(v) }
                    if let v = userInfo[key] as? NSNumber { return v.doubleValue }
                    return 0
                }

                self.group = group
                self.source = source
                self.fx = readDouble("fx")
                self.fy = readDouble("fy")
                self.ox = readDouble("ox")
                self.oy = readDouble("oy")
                self.sx = readDouble("sx")
                self.sy = readDouble("sy")
            }
        }

        private func handleScrollSyncNotification(_ note: Notification) {
            guard textView != nil else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let info = note.userInfo else { return }
            guard let payload = ScrollSyncPayload(userInfo: info) else { return }
            handleScrollSyncPayload(payload)
        }

        private func handleScrollSyncPayload(_ payload: ScrollSyncPayload) {
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard payload.group == group else { return }
            guard payload.source != scrollSyncSourceID else { return }

            let fx = CGFloat(payload.fx)
            let fy = CGFloat(payload.fy)
            let ox = CGFloat(payload.ox)
            let oy = CGFloat(payload.oy)
            let sx = CGFloat(payload.sx)
            let sy = CGFloat(payload.sy)

            tv.layoutIfNeeded()

            let inset = tv.adjustedContentInset
            let maxX = max(0, tv.contentSize.width - tv.bounds.width + inset.left + inset.right)
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + inset.top + inset.bottom)

            let clampedFX: CGFloat = min(max(fx, 0), 1)
            let clampedFY: CGFloat = min(max(fy, 0), 1)
            let currentNormalizedX = tv.contentOffset.x + inset.left
            let currentNormalizedY = tv.contentOffset.y + inset.top

            let shouldSyncX = (sx > 0) && (maxX > 0)
            let shouldSyncY = (sy > 0) && (maxY > 0)

            let effectiveFX: CGFloat = shouldSyncX ? clampedFX : 0
            let effectiveFY: CGFloat = shouldSyncY ? clampedFY : 0

            let desiredNormalized = CGPoint(
                x: shouldSyncX ? ((maxX * effectiveFX) + ox) : currentNormalizedX,
                y: shouldSyncY ? ((maxY * effectiveFY) + oy) : currentNormalizedY
            )

            let desired = CGPoint(
                x: desiredNormalized.x - inset.left,
                y: desiredNormalized.y - inset.top
            )

            // Clamp to an extended range so "bounce" overscroll stays synchronized.
            let minX = -inset.left
            let maxOffsetX = max(minX, tv.contentSize.width - tv.bounds.width + inset.right)
            let minY = -inset.top
            let maxOffsetY = max(minY, tv.contentSize.height - tv.bounds.height + inset.bottom)
            let allowX = max(60, tv.bounds.width * 0.25)
            let allowY = max(60, tv.bounds.height * 0.25)
            let clamped = CGPoint(
                x: min(max(desired.x, minX - allowX), maxOffsetX + allowX),
                y: min(max(desired.y, minY - allowY), maxOffsetY + allowY)
            )

            isApplyingExternalScroll = true
            if abs(tv.contentOffset.x - clamped.x) > 0.5 || abs(tv.contentOffset.y - clamped.y) > 0.5 {
                tv.setContentOffset(clamped, animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalScroll = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
