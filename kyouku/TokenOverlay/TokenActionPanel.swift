import SwiftUI
import UIKit
import Foundation

struct TokenActionPanel: View {
    let selection: TokenSelectionContext
    @ObservedObject var lookup: DictionaryLookupViewModel
    let preferredReading: String?
    let canMergePrevious: Bool
    let canMergeNext: Bool
    let onShowDefinitions: (() -> Void)?
    let onDismiss: () -> Void
    let onSaveWord: (DictionaryEntry) -> Void
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: ((String) -> Void)?
    let isWordSaved: ((DictionaryEntry) -> Bool)?
    let onMergePrevious: () -> Void
    let onMergeNext: () -> Void
    let onSplit: (Int) -> Void
    let onReset: () -> Void
    let isSelectionCustomized: Bool
    let enableDragToDismiss: Bool
    let embedInMaterialBackground: Bool
    let panelContainerHeight: CGFloat?
    let focusSplitMenu: Bool
    let onSplitFocusConsumed: () -> Void
    @State private var highlightedResultIndex = 0
    @State private var highlightedReadingIndex = 0
    @GestureState private var dragOffset: CGFloat = 0
    @State private var isSplitMenuVisible = false
    @State private var leftBucketCount = 0
    @State private var lastPresentedRequestID: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    private let dismissTranslationThreshold: CGFloat = 80
    private let outerPanelCornerRadius: CGFloat = 34

    init(
        selection: TokenSelectionContext,
        lookup: DictionaryLookupViewModel,
        preferredReading: String?,
        canMergePrevious: Bool,
        canMergeNext: Bool,
        onShowDefinitions: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onSaveWord: @escaping (DictionaryEntry) -> Void,
        onApplyReading: @escaping (DictionaryEntry) -> Void,
        onApplyCustomReading: ((String) -> Void)? = nil,
        isWordSaved: ((DictionaryEntry) -> Bool)? = nil,
        onMergePrevious: @escaping () -> Void,
        onMergeNext: @escaping () -> Void,
        onSplit: @escaping (Int) -> Void,
        onReset: @escaping () -> Void,
        isSelectionCustomized: Bool,
        enableDragToDismiss: Bool,
        embedInMaterialBackground: Bool,
        containerHeight: CGFloat? = nil,
        focusSplitMenu: Bool = false,
        onSplitFocusConsumed: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self._lookup = ObservedObject(initialValue: lookup)
        self.preferredReading = preferredReading
        self.canMergePrevious = canMergePrevious
        self.canMergeNext = canMergeNext
        self.onShowDefinitions = onShowDefinitions
        self.onDismiss = onDismiss
        self.onSaveWord = onSaveWord
        self.onApplyReading = onApplyReading
        self.onApplyCustomReading = onApplyCustomReading
        self.isWordSaved = isWordSaved
        self.onMergePrevious = onMergePrevious
        self.onMergeNext = onMergeNext
        self.onSplit = onSplit
        self.onReset = onReset
        self.isSelectionCustomized = isSelectionCustomized
        self.enableDragToDismiss = enableDragToDismiss
        self.embedInMaterialBackground = embedInMaterialBackground
        self.panelContainerHeight = containerHeight
        self.focusSplitMenu = focusSplitMenu
        self.onSplitFocusConsumed = onSplitFocusConsumed
    }

    @ViewBuilder
    var body: some View {
        if enableDragToDismiss {
            panelContent
                .simultaneousGesture(dismissGesture)
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        Group {
            if embedInMaterialBackground {
                panelSurface
                    .background(
                        RoundedRectangle(cornerRadius: outerPanelCornerRadius, style: .continuous)
                            .fill(.ultraThickMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: outerPanelCornerRadius, style: .continuous)
                                    .stroke(
                                        (colorScheme == .dark) ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .shadow(
                        color: Color.black.opacity((colorScheme == .dark) ? 0.55 : 0.18),
                        radius: 18,
                        x: 0,
                        y: 8
                    )
            } else {
                panelSurface
            }
        }
        // Apply drag offset to the *entire* panel, including its material background.
        // Applying offset inside `panelSurface` causes the background to feel like a separate
        // panel because `offset` doesn't move layout.
        .offset(y: max(0, dragOffset))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dragOffset)
        // IMPORTANT: ensure the entire panel surface is hit-testable so taps on "empty" areas
        // (padding / background) do not fall through to the underlying paste view, which can
        // clear the selection and dismiss the popup.
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var panelSurface: some View {
        VStack(spacing: 12) {
            // Let entry cards run edge-to-edge; keep padding for action controls.
            dictionaryScrollContainer
                .padding(.horizontal, -20)
                .layoutPriority(0)

            actionRow
                .layoutPriority(1)
            if isSplitMenuVisible {
                SplitMenuView(
                    selectionCharacters: selectionCharacters,
                    leftBucketCount: $leftBucketCount,
                    onCancel: { closeSplitMenu(animated: true) },
                    onApply: { offset in
                        onSplit(offset)
                        closeSplitMenu(animated: true)
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .onAppear {
            lastPresentedRequestID = lookup.presented?.requestID
            resetSplitControls()
            resetHighlightedResult()
            focusSplitMenuIfNeeded(focusSplitMenu)
        }
        .onChange(of: lookup.presented?.requestID) { _, newValue in
            guard newValue != lastPresentedRequestID else { return }
            lastPresentedRequestID = newValue
            resetSplitControls()
            resetHighlightedResult()
        }
        .onChange(of: focusSplitMenu) { _, newValue in
            focusSplitMenuIfNeeded(newValue)
        }
        .contentShape(Rectangle())
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionIconButton(label: "Merge with previous token", systemImage: "arrow.left.to.line.square", enabled: canMergePrevious, action: onMergePrevious)

            actionIconButton(label: "Merge with next token", systemImage: "arrow.right.to.line.square", enabled: canMergeNext, action: onMergeNext)

            // Split controls should not appear for single-character selections.
            if effectiveSelection.range.length > 1 {
                actionIconButton(
                    label: "Adjust split",
                    systemImage: "scissors",
                    enabled: true,
                    isActive: isSplitMenuVisible,
                    action: toggleSplitMenu
                )
            }

            if isSelectionCustomized {
                actionIconButton(label: "Reset overrides", systemImage: "gobackward", enabled: true, action: onReset)
            }
        }
    }

    // private var customizedBadge: some View {
    //     Label("Customized", systemImage: "wand.and.stars")
    //         .font(.caption2)
    //         .padding(.horizontal, 10)
    //         .padding(.vertical, 4)
    //         .background(.ultraThinMaterial, in: Capsule())
    // }

    private func actionIconButton(label: String, systemImage: String, enabled: Bool, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .controlSize(.mini)
        .disabled(enabled == false)
        .tint(.accentColor)
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1.2)
            }
        }
        .accessibilityLabel(label)
    }

    private var selectionCharacters: [Character] {
        Array(effectiveSelection.surface)
    }

    // Render from the stable `presented` snapshot when available.
    // This keeps the panel content stable while a new lookup is `.resolving`.
    private var effectivePresented: DictionaryLookupViewModel.PresentedLookup? {
        lookup.presented
    }

    private var effectiveSelection: TokenSelectionContext {
        effectivePresented?.selection ?? selection
    }

    private var effectiveResults: [DictionaryEntry] {
        effectivePresented?.results ?? lookup.results
    }

    // Stale content activity indicator:
    // When a new lookup starts, `phase` flips to `.resolving(newID)` but `presented` stays
    // on the previous request until the new lookup commits. Keep rendering the old content,
    // but show a subtle indicator so slow lookups still feel responsive.
    private var isShowingStalePresentedWhileResolving: Bool {
        guard let presentedID = lookup.presented?.requestID else { return false }
        if case .resolving(let activeID) = lookup.phase {
            return activeID != presentedID
        }
        return false
    }

    private func toggleSplitMenu() {
        guard selectionCharacters.count > 1 else { return }
        if handleTwoCharacterSplitIfNeeded() {
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if isSplitMenuVisible {
                isSplitMenuVisible = false
            } else {
                leftBucketCount = selectionCharacters.count
                isSplitMenuVisible = true
            }
        }
    }

    private func focusSplitMenuIfNeeded(_ shouldFocus: Bool) {
        guard shouldFocus else { return }
        defer { onSplitFocusConsumed() }
        guard selectionCharacters.count > 1 else { return }
        if handleTwoCharacterSplitIfNeeded() {
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            leftBucketCount = selectionCharacters.count
            isSplitMenuVisible = true
        }
    }

    private func resetSplitControls() {
        leftBucketCount = selectionCharacters.count
        isSplitMenuVisible = false
    }

    private func handleTwoCharacterSplitIfNeeded() -> Bool {
        guard selectionCharacters.count == 2 else { return false }
        let offset = utf16LengthOfFirstCharacter()
        guard offset > 0 else { return false }
        onSplit(offset)
        return true
    }

    private func utf16LengthOfFirstCharacter() -> Int {
        guard let first = selectionCharacters.first else { return 0 }
        return String(first).utf16.count
    }

    private func closeSplitMenu(animated: Bool) {
        let animations = {
            leftBucketCount = selectionCharacters.count
            isSplitMenuVisible = false
        }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85), animations)
        } else {
            animations()
        }
    }

    private func resetHighlightedResult() {
        if let preferred = preferredResultIndex() {
            highlightedResultIndex = preferred
        } else if let preferredLemma = lemmaPreferredResultIndex() {
            highlightedResultIndex = preferredLemma
        } else {
            highlightedResultIndex = 0
        }
    }

    private func preferredResultIndex() -> Int? {
        guard let raw = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else { return nil }
        return effectiveResults.firstIndex { entry in
            let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate == raw
        }
    }

    private func lemmaPreferredResultIndex() -> Int? {
        let lemmas = effectiveSelection.annotatedSpan.lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard lemmas.isEmpty == false else { return nil }

        return effectiveResults.firstIndex { entry in
            let kanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return lemmas.contains(kanji) || (kana.isEmpty == false && lemmas.contains(kana))
        }
    }

    @ViewBuilder
    private var dictionaryScrollContainer: some View {
        let measuredResults = LookupResultsView(
            lookup: lookup,
            selection: effectiveSelection,
            preferredReading: preferredReading,
            highlightedResultIndex: $highlightedResultIndex,
            highlightedReadingIndex: $highlightedReadingIndex,
            onApplyReading: onApplyReading,
            onApplyCustomReading: onApplyCustomReading,
            onSaveWord: onSaveWord,
            isWordSaved: isWordSaved,
            onShowDefinitions: onShowDefinitions
        )
            .frame(maxWidth: .infinity, alignment: .leading)

        // NOTE:
        // We intentionally avoid `ViewThatFits` + `frame(maxHeight:)` here.
        // In this panel's layout context (bottom-anchored overlay), those constraints can
        // cause the dictionary section to expand vertically, creating a large empty gap
        // before the action row. Shrink-wrap to intrinsic height so the card and buttons
        // remain visually attached.
        measuredResults
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isShowingStalePresentedWhileResolving ? 0.7 : 1)
            .overlay(alignment: .topTrailing) {
                if isShowingStalePresentedWhileResolving {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(.trailing, 8)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragOffset) { value, state, _ in
                let height = value.translation.height
                let width = value.translation.width
                guard height > 0 else {
                    state = 0
                    return
                }
                guard abs(height) > abs(width) else {
                    state = 0
                    return
                }
                state = height
            }
            .onEnded { value in
                let translationH = value.translation.height
                let translationW = value.translation.width
                let predictedH = value.predictedEndTranslation.height
                let predictedW = value.predictedEndTranslation.width

                guard translationH > 0 else { return }
                guard abs(translationH) > abs(translationW) else { return }
                guard translationH > dismissTranslationThreshold || (predictedH > dismissTranslationThreshold && abs(predictedH) > abs(predictedW)) else {
                    return
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    onDismiss()
                }
            }
    }
}

// MARK: - Custom reading alert (UIKit-backed)

private final class PreferredLanguageUITextField: UITextField {
    var preferredLanguagePrefixes: [String] = []

    override var textInputMode: UITextInputMode? {
        guard preferredLanguagePrefixes.isEmpty == false else {
            return super.textInputMode
        }

        for mode in UITextInputMode.activeInputModes {
            guard let primary = mode.primaryLanguage else { continue }
            if preferredLanguagePrefixes.contains(where: { primary.hasPrefix($0) }) {
                return mode
            }
        }

        return super.textInputMode
    }
}

final class CustomReadingEntryViewController: UIViewController, UITextFieldDelegate {
    private let surfaceLabel = UILabel()
    private let textField = PreferredLanguageUITextField(frame: .zero)
    private var onTextChanged: ((String) -> Void)? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.preservesSuperviewLayoutMargins = true
        view.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        surfaceLabel.font = UIFont.systemFont(ofSize: 13)
        surfaceLabel.textColor = .secondaryLabel
        surfaceLabel.numberOfLines = 2

        textField.delegate = self
        textField.borderStyle = .roundedRect
        textField.clearButtonMode = .always
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.autocapitalizationType = .none
        textField.returnKeyType = .done
        textField.enablesReturnKeyAutomatically = false
        textField.addTarget(self, action: #selector(textDidChange(_:)), for: .editingChanged)

        let stack = UIStackView(arrangedSubviews: [surfaceLabel, textField])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])
    }

    func apply(surface: String, text: String, preferredLanguagePrefixes: [String], onTextChanged: @escaping (String) -> Void) {
        surfaceLabel.text = surface
        if textField.text != text {
            textField.text = text
        }
        textField.preferredLanguagePrefixes = preferredLanguagePrefixes
        self.onTextChanged = onTextChanged
    }

    func focusAndSelectAll() {
        textField.becomeFirstResponder()
        guard let current = textField.text, current.isEmpty == false else { return }
        let beginning = textField.beginningOfDocument
        let end = textField.endOfDocument
        if let range = textField.textRange(from: beginning, to: end) {
            textField.selectedTextRange = range
        }
    }

    @objc private func textDidChange(_ sender: UITextField) {
        onTextChanged?(sender.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}

#Preview {
    TokenActionPanel(
        selection: TokenSelectionContext(
            tokenIndex: 0,
            range: NSRange(location: 0, length: 2),
            surface: "京都",
            semanticSpan: SemanticSpan(range: NSRange(location: 0, length: 2), surface: "京都", sourceSpanIndices: 0..<1, readingKana: "きょうと"),
            sourceSpanIndices: 0..<1,
            annotatedSpan: AnnotatedSpan(span: TextSpan(range: NSRange(location: 0, length: 2), surface: "京都"), readingKana: "きょうと")
        ),
        lookup: DictionaryLookupViewModel(),
        preferredReading: nil,
        canMergePrevious: false,
        canMergeNext: true,
        onDismiss: {},
        onSaveWord: { _ in },
        onApplyReading: { _ in },
        onMergePrevious: {},
        onMergeNext: {},
        onSplit: { _ in },
        onReset: {},
        isSelectionCustomized: true,
        enableDragToDismiss: true,
        embedInMaterialBackground: true,
        focusSplitMenu: false,
        onSplitFocusConsumed: {}
    )
    .padding()
    .background(Color.black.opacity(0.05))
}

