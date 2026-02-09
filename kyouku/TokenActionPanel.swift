import SwiftUI
import UIKit
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

    private var dictionaryScrollMaxHeight: CGFloat? {
        let allowance = panelHeightLimit - estimatedChromeHeight
        return allowance > 0 ? allowance : nil
    }

    private var estimatedChromeHeight: CGFloat {
        var height: CGFloat = 12 // spacing
        height += actionRowHeight
        if isSplitMenuVisible {
            height += splitMenuHeight
        }
        return height + 24 // padding + misc
    }

    private var panelHeightLimit: CGFloat {
        let provided = panelContainerHeight ?? 0
        let basis = provided > 0.5 ? provided : currentScreenHeight()
        // Expand to fit content (no scrolling in the popup), but leave a little
        // space above so the user retains context and can still drag-dismiss.
        let reservedTopSpace: CGFloat = 80
        let maxAllowed = max(240, basis - reservedTopSpace)
        // Prevent the panel from becoming comically tall on large screens.
        return min(maxAllowed, 900)
    }

    private func currentScreenHeight() -> CGFloat {
        if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
            return screen.bounds.height
        }
        return 480 // sensible fallback
    }

    private var actionRowHeight: CGFloat {
        48
    }

    private var splitMenuHeight: CGFloat {
        190
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

private final class CustomReadingEntryViewController: UIViewController, UITextFieldDelegate {
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

private struct CustomReadingAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let surface: String
    @Binding var text: String
    let preferredLanguagePrefixes: [String]
    let onCancel: () -> Void
    let onApply: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else {
            if let alert = context.coordinator.alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            context.coordinator.alert = nil
            context.coordinator.entryController = nil
            return
        }

        if let alert = context.coordinator.alert {
            context.coordinator.entryController?.apply(
                surface: surface,
                text: text,
                preferredLanguagePrefixes: preferredLanguagePrefixes,
                onTextChanged: { newValue in
                    text = newValue
                }
            )
            _ = alert
            return
        }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let entry = CustomReadingEntryViewController()
        entry.apply(
            surface: surface,
            text: text,
            preferredLanguagePrefixes: preferredLanguagePrefixes,
            onTextChanged: { newValue in
                text = newValue
            }
        )
        alert.setValue(entry, forKey: "contentViewController")

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            onCancel()
            isPresented = false
        })
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { _ in
            onApply()
            isPresented = false
        })

        context.coordinator.alert = alert
        context.coordinator.entryController = entry
        uiViewController.present(alert, animated: true) {
            DispatchQueue.main.async {
                entry.focusAndSelectAll()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var alert: UIAlertController? = nil
        var entryController: CustomReadingEntryViewController? = nil
    }
}

private struct SplitMenuView: View {
    let selectionCharacters: [Character]
    @Binding var leftBucketCount: Int
    let onCancel: () -> Void
    let onApply: (Int) -> Void

    private var canSplit: Bool {
        selectionCharacters.count > 1 && leftBucketCount > 0 && leftBucketCount < selectionCharacters.count
    }

    private var leftText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let count = max(0, min(leftBucketCount, selectionCharacters.count))
        return String(selectionCharacters.prefix(count))
    }

    private var rightText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let suffixCount = max(0, selectionCharacters.count - leftBucketCount)
        guard suffixCount > 0 else { return "" }
        return String(selectionCharacters.suffix(suffixCount))
    }

    private var leftUTF16Length: Int {
        guard canSplit else { return 0 }
        let prefixString = String(selectionCharacters.prefix(leftBucketCount))
        return prefixString.utf16.count
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                bucketButton(text: leftText, alignment: .trailing, isEnabled: leftBucketCount < selectionCharacters.count) {
                    moveCharacterRightToLeft()
                }

                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)

                bucketButton(text: rightText, alignment: .leading, isEnabled: leftBucketCount > 0) {
                    moveCharacterLeftToRight()
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)

                Button("Apply") {
                    guard canSplit else { return }
                    onApply(leftUTF16Length)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(canSplit == false)
            }
            .font(.caption)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func bucketButton(text: String, alignment: Alignment, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.isEmpty ? "" : text)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: alignment)
                .frame(height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isEnabled ? Color.appAccent : Color.appTextSecondary.opacity(0.5), lineWidth: 1.5)
        )
    }

    private func moveCharacterLeftToRight() {
        guard leftBucketCount > 0 else { return }
        leftBucketCount -= 1
    }

    private func moveCharacterRightToLeft() {
        guard leftBucketCount < selectionCharacters.count else { return }
        leftBucketCount += 1
    }
}

private struct LookupResultsView: View {
    @ObservedObject var lookup: DictionaryLookupViewModel
    let selection: TokenSelectionContext
    let preferredReading: String?
    @Binding var highlightedResultIndex: Int
    @Binding var highlightedReadingIndex: Int
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: ((String) -> Void)?
    let onSaveWord: (DictionaryEntry) -> Void
    let isWordSaved: ((DictionaryEntry) -> Bool)?
    let onShowDefinitions: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    @State private var isCustomReadingPromptPresented = false
    @State private var customReadingText = ""

    @State private var highlightedEntryDetail: DictionaryEntryDetail? = nil
    @State private var highlightedEntryDetailTask: Task<Void, Never>? = nil

    private enum PagingMode {
        case none
        case results(current: Int, total: Int)
        case readings(current: Int, total: Int)
    }

    private struct PagingState {
        let entry: DictionaryEntry
        let mode: PagingMode

        var hasPaging: Bool {
            switch mode {
            case .none: return false
            case .results, .readings: return true
            }
        }

        var positionText: String {
            switch mode {
            case .none:
                return ""
            case .results(let current, let total):
                return "\(current)/\(total)"
            case .readings(let current, let total):
                return "\(current)/\(total)"
            }
        }
    }

    // Stable snapshot the UI should render, scoped to the current selection.
    // Without scoping, the inline panel can briefly show stale results (or "No matches")
    // while a new selection is resolving.
    private var presentedForSelection: DictionaryLookupViewModel.PresentedLookup? {
        guard let snapshot = lookup.presented, snapshot.requestID == selection.id else { return nil }
        return snapshot
    }

    private var isResolvingSelection: Bool {
        if case .resolving(let requestID) = lookup.phase {
            return requestID == selection.id
        }
        return false
    }

    private var effectiveSelection: TokenSelectionContext { presentedForSelection?.selection ?? selection }

    private var effectiveResults: [DictionaryEntry] { presentedForSelection?.results ?? [] }

    private var effectiveError: String? { presentedForSelection?.errorMessage }

    private var pagingState: PagingState? {
        guard let highlighted = highlightedEntry else { return nil }

        let resultsCount = effectiveResults.count
        let resultPaging = resultsCount > 1
        if resultPaging {
            let current = min(max(0, highlighted.index), max(0, resultsCount - 1)) + 1
            return PagingState(
                entry: highlighted.entry,
                mode: .results(current: current, total: resultsCount)
            )
        }

        let variants = readingVariants(for: highlighted.entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else {
            return PagingState(entry: highlighted.entry, mode: .none)
        }

        let safe = min(max(0, highlightedReadingIndex), max(0, variants.count - 1))
        let activeKana = variants.indices.contains(safe) ? variants[safe] : highlighted.entry.kana
        let effectiveEntry = entryWithKanaVariant(highlighted.entry, kana: activeKana)
        return PagingState(
            entry: effectiveEntry,
            mode: .readings(current: safe + 1, total: variants.count)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isResolvingSelection {
                statusCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up \(effectiveSelection.surface)…")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                    }
                }
            } else if let error = effectiveError, error.isEmpty == false {
                statusCard {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
            } else if effectiveResults.isEmpty {
                statusCard {
                    Text("No matches for \(effectiveSelection.surface). Try editing the selection or typing a different term in the Dictionary tab.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
            } else if let state = pagingState {
                let slotWidth: CGFloat = 18
                let slotVerticalPadding: CGFloat = 48

                let prevDisabled: Bool = {
                    switch state.mode {
                    case .none:
                        return true
                    case .results:
                        return highlightedResultIndex <= 0
                    case .readings:
                        return highlightedReadingIndex <= 0
                    }
                }()

                let nextDisabled: Bool = {
                    switch state.mode {
                    case .none:
                        return true
                    case .results(_, let total):
                        return highlightedResultIndex >= max(0, total - 1)
                    case .readings(_, let total):
                        return highlightedReadingIndex >= max(0, total - 1)
                    }
                }()

                let prevLabel: String = {
                    switch state.mode {
                    case .readings: return "Previous reading"
                    default: return "Previous result"
                    }
                }()

                let nextLabel: String = {
                    switch state.mode {
                    case .readings: return "Next reading"
                    default: return "Next result"
                    }
                }()

                VStack(alignment: .leading, spacing: 12) {
                    dictionaryCard(entry: state.entry, positionText: state.positionText)
                        // Always reserve left/right space so single-result cards match the
                        // multi-result layout, but without drawing arrows.
                        .padding(.horizontal, slotWidth)
                        .simultaneousGesture(horizontalSwipeGesture)
                        // IMPORTANT: use overlays so the large hit-target padding does NOT
                        // inflate the measured panel size.
                        .overlay(alignment: .leading) {
                            if state.hasPaging {
                                pagerChevronOverlay(
                                    systemImage: "chevron.left",
                                    isDisabled: prevDisabled,
                                    verticalPadding: slotVerticalPadding,
                                    accessibilityLabel: prevLabel,
                                    action: {
                                        switch state.mode {
                                        case .results:
                                            goToPreviousResult()
                                        case .readings:
                                            goToPreviousReading()
                                        case .none:
                                            break
                                        }
                                    }
                                )
                                .frame(width: slotWidth)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if state.hasPaging {
                                pagerChevronOverlay(
                                    systemImage: "chevron.right",
                                    isDisabled: nextDisabled,
                                    verticalPadding: slotVerticalPadding,
                                    accessibilityLabel: nextLabel,
                                    action: {
                                        switch state.mode {
                                        case .results:
                                            goToNextResult()
                                        case .readings:
                                            goToNextReading()
                                        case .none:
                                            break
                                        }
                                    }
                                )
                                .frame(width: slotWidth)
                            }
                        }

                    // Purely additive, read-only semantic exploration.
                    // This can be compute-heavy; keep it opt-in for responsiveness.
                    if ProcessInfo.processInfo.environment["SEMANTIC_EXPLORER"] == "1" {
                        SemanticNeighborhoodExplorerView(lookup: lookup, topN: 30)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }
        .onChange(of: highlightedResultIndex) { _, _ in
            highlightedReadingIndex = 0
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }
        .onChange(of: lookup.presented?.requestID) { _, _ in
            highlightedReadingIndex = 0
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }

        .background(
            CustomReadingAlertPresenter(
                isPresented: $isCustomReadingPromptPresented,
                title: "Custom reading",
                surface: effectiveSelection.surface,
                text: $customReadingText,
                preferredLanguagePrefixes: ["ja"],
                onCancel: {
                    customReadingText = ""
                },
                onApply: {
                    let trimmed = customReadingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    customReadingText = ""
                    guard trimmed.isEmpty == false else { return }
                    onApplyCustomReading?(trimmed)
                }
            )
        )
    }

    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        // Match the result-card layout so status states feel like they belong to the inner panel.
        // Also reserve the left/right pager slots so single-result + status states align.
        let slotWidth: CGFloat = 18

        return content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DictionaryCardBackground(colorScheme: colorScheme))
            .padding(.horizontal, slotWidth)
    }

    private func pagerChevronOverlay(
        systemImage: String,
        isDisabled: Bool,
        verticalPadding: CGFloat,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 18)
                .padding(.vertical, verticalPadding)
        }
        .buttonStyle(.plain)
        .foregroundColor(isDisabled ? Color.secondary.opacity(0.4) : .accentColor)
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -30 {
                    if effectiveResults.count > 1 {
                        goToNextResult()
                    } else {
                        goToNextReading()
                    }
                } else if value.translation.width > 30 {
                    if effectiveResults.count > 1 {
                        goToPreviousResult()
                    } else {
                        goToPreviousReading()
                    }
                }
            }
    }

    private func goToPreviousResult() {
        guard highlightedResultIndex > 0 else { return }
        highlightedResultIndex -= 1
    }

    private func goToNextResult() {
        guard highlightedResultIndex < max(0, effectiveResults.count - 1) else { return }
        highlightedResultIndex += 1
        highlightedReadingIndex = 0
        resetReadingIndexIfNeeded()
    }

    private func goToPreviousReading() {
        guard let entry = highlightedEntry?.entry else { return }
        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else { return }
        guard highlightedReadingIndex > 0 else { return }
        highlightedReadingIndex -= 1
    }

    private func goToNextReading() {
        guard let entry = highlightedEntry?.entry else { return }
        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else { return }
        guard highlightedReadingIndex < variants.count - 1 else { return }
        highlightedReadingIndex += 1
    }

    private func resetReadingIndexIfNeeded() {
        guard effectiveResults.count <= 1 else {
            highlightedReadingIndex = 0
            return
        }
        guard let entry = highlightedEntry?.entry else {
            highlightedReadingIndex = 0
            return
        }

        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else {
            highlightedReadingIndex = 0
            return
        }

        let preferred = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preferred.isEmpty == false {
            if let idx = variants.firstIndex(of: preferred) {
                highlightedReadingIndex = idx
                return
            }

            // Reading overrides for mixed kanji+kana tokens are persisted as the *kanji portion*
            // of the surface reading (e.g. 抱かれ -> store "いだ" so ruby can render 抱(いだ)かれ).
            // When reopening the popup, map that persisted stem back onto the lemma-level
            // dictionary variants so the same variant is highlighted.
            let tokenSurface = effectiveSelection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let lemmaSurface = (entry.kanji.isEmpty == false ? entry.kanji : (entry.kana ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if tokenSurface.isEmpty == false, lemmaSurface.isEmpty == false {
                for (idx, variant) in variants.enumerated() {
                    let projected = projectedOverrideKana(tokenSurface: tokenSurface, lemmaSurface: lemmaSurface, lemmaReading: variant)
                    if projected == preferred {
                        highlightedReadingIndex = idx
                        return
                    }
                }
            }
        }

        let tokenReading = (effectiveSelection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenReading.isEmpty == false, let idx = variants.firstIndex(of: tokenReading) {
            highlightedReadingIndex = idx
            return
        }

        let entryKana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if entryKana.isEmpty == false, let idx = variants.firstIndex(of: entryKana) {
            highlightedReadingIndex = idx
            return
        }

        highlightedReadingIndex = 0
    }

    private var highlightedEntry: (entry: DictionaryEntry, index: Int)? {
        guard effectiveResults.isEmpty == false else { return nil }
        let safeIndex = min(highlightedResultIndex, effectiveResults.count - 1)
        return (effectiveResults[safeIndex], safeIndex)
    }

    private var matchingHighlightedEntryDetail: DictionaryEntryDetail? {
        guard let entry = highlightedEntry?.entry else { return nil }
        guard let detail = highlightedEntryDetail, detail.entryID == entry.entryID else { return nil }
        return detail
    }

    private func readingVariants(for entry: DictionaryEntry, detail: DictionaryEntryDetail?) -> [String] {
        var variants: [String] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            if variants.contains(trimmed) == false {
                variants.append(trimmed)
            }
        }

        if let detail {
            for form in detail.kanaForms {
                add(form.text)
            }
        }
        if let kana = entry.kana {
            add(kana)
        }
        return variants
    }

    private func entryWithKanaVariant(_ entry: DictionaryEntry, kana: String?) -> DictionaryEntry {
        let trimmed = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryEntry(
            entryID: entry.entryID,
            kanji: entry.kanji,
            kana: (trimmed?.isEmpty == false) ? trimmed : nil,
            gloss: entry.gloss,
            isCommon: entry.isCommon
        )
    }

    private func refreshHighlightedEntryDetail() {
        highlightedEntryDetailTask?.cancel()
        highlightedEntryDetail = nil

        // Defer detail fetch while the lookup for this selection is in-flight.
        // The panel shows a loading state during `.resolving`, so fetching details would
        // be wasted work and can race against a soon-to-arrive result set.
        if isResolvingSelection { return }

        guard let entry = highlightedEntry?.entry else { return }
        let entryID = entry.entryID

        highlightedEntryDetailTask = Task {
            let details: [DictionaryEntryDetail] = (try? await Task.detached(priority: .userInitiated) {
                try await DictionarySQLiteStore.shared.fetchEntryDetails(for: [entryID])
            }.value) ?? []
            if Task.isCancelled { return }

            await MainActor.run {
                highlightedEntryDetail = details.first
                resetReadingIndexIfNeeded()
            }
        }
    }

    private func dictionaryCard(entry: DictionaryEntry, positionText: String) -> some View {
        let isSaved = isWordSaved?(entry) ?? false
        let activeReading = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entryReading = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenSurfaceForMatch = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let lemmaSurfaceForMatch = (entry.kanji.isEmpty == false ? entry.kanji : (entry.kana ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let projectedActive = projectedOverrideKana(tokenSurface: tokenSurfaceForMatch, lemmaSurface: lemmaSurfaceForMatch, lemmaReading: (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let isActiveDictionaryReading = activeReading.isEmpty == false && entryReading.isEmpty == false && (activeReading == entryReading || (projectedActive.isEmpty == false && activeReading == projectedActive))
        let isActiveCustomReading = activeReading.isEmpty == false && isActiveDictionaryReading == false

        let tokenSurface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenReading = (selection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenPOS = (selection.annotatedSpan.partOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenLemma = (selection.annotatedSpan.lemmaCandidates.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let surfaceHasKanji = tokenSurface.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let shouldShowApplyReadingButton = surfaceHasKanji

        // Treat the dictionary headword as the canonical lemma.
        // NOTE: For some nouns, MeCab may provide a kana-only lemma (e.g. 一人 -> ひとり).
        // In those cases we still want lemmaSurface to be the dictionary kanji headword so
        // alternate dictionary readings (ひとり / いちにん) can be paged and displayed.
        let lemmaSurface: String = {
            if surfaceHasKanji {
                if entry.kanji.isEmpty == false {
                    return entry.kanji
                }
                if let kana = entry.kana, kana.isEmpty == false {
                    return kana
                }
                // If the token lemma contains kanji, it can still be a useful fallback.
                if tokenLemma.isEmpty == false, tokenLemma.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                    return tokenLemma
                }
                return tokenSurface
            }

            // If the selected surface is kana-only, prefer kana lemma (avoid showing kanji).
            if let kana = entry.kana, kana.isEmpty == false {
                return kana
            }
            return tokenSurface
        }()

        // Use the dictionary-provided reading for the lemma when available.
        let lemmaReading: String = {
            // For kana-only surfaces, we intentionally avoid presenting a kanji lemma,
            // so a separate lemma reading is not useful.
            guard surfaceHasKanji else { return "" }
            // Only show a lemma reading when it corresponds to the displayed lemma surface.
            guard entry.kanji.isEmpty == false else { return "" }
            guard lemmaSurface == entry.kanji else { return "" }
            return (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        func trailingKanaRun(in surface: String) -> String {
            guard surface.isEmpty == false else { return "" }
            let allScalars = Array(surface.unicodeScalars)
            guard allScalars.isEmpty == false else { return "" }

            var trailing: [UnicodeScalar] = []
            for scalar in allScalars.reversed() {
                let isKana = (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
                if isKana {
                    trailing.append(scalar)
                } else {
                    break
                }
            }

            // If the surface is entirely kana, there is no okurigana segment to append.
            guard trailing.isEmpty == false, trailing.count < allScalars.count else { return "" }
            return String(String.UnicodeScalarView(trailing.reversed()))
        }

        func readingIncludingOkurigana(surface: String, reading: String) -> String {
            let okurigana = trailingKanaRun(in: surface)
            guard okurigana.isEmpty == false else { return reading }
            guard reading.isEmpty == false else { return okurigana }
            return reading.hasSuffix(okurigana) ? reading : (reading + okurigana)
        }

        // Surface reading should preview how THIS dictionary entry's reading would apply
        // to the selected surface form.
        //
        // If we instead always show the current token reading when surface != lemma,
        // we can end up with mixed pairs like:
        //   抱かれ(いだかれ)
        //   抱く(だく)
        // which is confusing when paging alternate readings.
        let dictionaryReading = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        func conjugatedSurfaceReading(from lemmaReading: String, lemmaSurface: String, tokenSurface: String) -> String {
            guard lemmaReading.isEmpty == false else { return "" }
            let tokenSuffix = trailingKanaRun(in: tokenSurface)
            let lemmaSuffix = trailingKanaRun(in: lemmaSurface)
            guard tokenSuffix.isEmpty == false, lemmaSuffix.isEmpty == false else { return lemmaReading }
            guard lemmaReading.hasSuffix(lemmaSuffix) else { return lemmaReading }
            let stem = String(lemmaReading.dropLast(lemmaSuffix.count))
            return stem + tokenSuffix
        }

        let surfaceReadingBase: String = {
            if tokenSurface != lemmaSurface {
                // Prefer entry-derived preview when the token looks inflected.
                if dictionaryReading.isEmpty == false {
                    return conjugatedSurfaceReading(from: dictionaryReading, lemmaSurface: lemmaSurface, tokenSurface: tokenSurface)
                }
                return tokenReading
            }

            // Lemma-like surface: show the dictionary reading when available.
            if dictionaryReading.isEmpty == false { return dictionaryReading }
            return tokenReading
        }()
        let surfaceReading = readingIncludingOkurigana(surface: tokenSurface, reading: surfaceReadingBase)

        let showSurfaceReading = surfaceReading.isEmpty == false && surfaceReading != tokenSurface
        let showLemmaLine = lemmaSurface.isEmpty == false && lemmaSurface != tokenSurface
        let showLemmaReading = lemmaReading.isEmpty == false && lemmaReading != lemmaSurface

        let detail = (highlightedEntryDetail?.entryID == entry.entryID) ? highlightedEntryDetail : nil

        return VStack(alignment: .leading, spacing: 6) {
            // Surface (reading in parentheses)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tokenSurface.isEmpty ? "—" : tokenSurface)
                    .font(.headline)
                if showSurfaceReading {
                     Text("(\(surfaceReading))")
                         .font(.subheadline)

                    if onApplyCustomReading != nil {
                        inlineIconButton(
                            systemImage: isActiveCustomReading ? "pencil.circle.fill" : "pencil.circle",
                            tint: isActiveCustomReading ? .accentColor : .secondary,
                            accessibilityLabel: isActiveCustomReading ? "Active custom reading" : "Apply custom reading"
                        ) {
                            // Prefill with the current active reading and fully select it.
                            // This makes it easy to type a correction immediately.
                            let currentReading: String = {
                                if activeReading.isEmpty == false { return activeReading }
                                if surfaceReading.isEmpty == false { return surfaceReading }
                                return tokenReading
                            }()
                            customReadingText = currentReading
                            isCustomReadingPromptPresented = true
                        }
                    }
                }
            }

            // Lemma (reading in parentheses)
            if showLemmaLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lemmaSurface)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                     if showLemmaReading {
                         Text("(\(lemmaReading))")
                             .font(.subheadline)
                             .foregroundStyle(.secondary)
                     }
                }
            }

            // POS line above definition
            if tokenPOS.isEmpty == false {
                Text(tokenPOS)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if let detail, detail.senses.isEmpty == false {
                ExpandableSensesPreview(entryID: entry.entryID, senses: detail.senses)
            } else if entry.gloss.isEmpty == false {
                ExpandableGlossPreview(entryID: entry.entryID, gloss: entry.gloss)
            }

            HStack(spacing: 12) {
                iconActionButton(
                    systemImage: "speaker.wave.2",
                    tint: .secondary,
                    accessibilityLabel: "Speak"
                ) {
                    let speechText = showSurfaceReading ? surfaceReading : tokenSurface
                    SpeechManager.shared.speak(text: speechText, language: "ja-JP")
                }

                if shouldShowApplyReadingButton {
                    iconActionButton(
                        systemImage: isActiveDictionaryReading ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: isActiveDictionaryReading ? .accentColor : .secondary,
                        accessibilityLabel: isActiveDictionaryReading ? "Active dictionary reading" : "Apply dictionary reading"
                    ) {
                        onApplyReading(entry)
                    }
                    .disabled(canUseReading(entry) == false)
                }

                if let onShowDefinitions {
                    iconActionButton(
                        systemImage: "book",
                        tint: .secondary,
                        accessibilityLabel: "Show details"
                    ) {
                        onShowDefinitions()
                    }
                }

                iconActionButton(
                    systemImage: isSaved ? "bookmark.fill" : "bookmark",
                    tint: isSaved ? .accentColor : .secondary,
                    accessibilityLabel: isSaved ? "Saved to words list" : "Save to words list"
                ) {
                    onSaveWord(entry)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DictionaryCardBackground(colorScheme: colorScheme))
        .overlay(alignment: .topTrailing) {
            if positionText.isEmpty == false {
                Text(positionText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    private struct DictionaryCardBackground: View {
        let colorScheme: ColorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            let material: Material = (colorScheme == .dark) ? .regularMaterial : .thinMaterial
            let tint: Color = (colorScheme == .dark) ? Color.black.opacity(0.32) : Color.black.opacity(0.12)
            let border: Color = (colorScheme == .dark) ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
            let shadowOpacity: Double = (colorScheme == .dark) ? 0.30 : 0.10

            ZStack {
                shape.fill(material)
                shape.fill(tint).blendMode(.multiply)
                shape.stroke(border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 10, x: 0, y: 4)
        }
    }

    private struct ExpandableSensesPreview: View {
        let entryID: Int64
        let senses: [DictionaryEntrySense]

        @State private var isExpanded: Bool = false

        private let collapsedLimit: Int = 3

        private var visibleSenses: ArraySlice<DictionaryEntrySense> {
            if isExpanded { return senses[...] }
            return senses.prefix(collapsedLimit)
        }

        private var hiddenCount: Int {
            max(0, senses.count - collapsedLimit)
        }

        private func formattedTagsLine(from tags: [String]) -> String? {
            guard tags.isEmpty == false else { return nil }
            return tags.joined(separator: " · ")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleSenses.enumerated()), id: \.element.id) { index, sense in
                        let senseNumber = index + 1
                        if let posLine = formattedTagsLine(from: sense.partsOfSpeech), posLine.isEmpty == false {
                            Text(posLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .italic()
                        }

                        let glossText = sense.glosses
                            .sorted(by: { $0.orderIndex < $1.orderIndex })
                            .prefix(3)
                            .map { $0.text }
                            .joined(separator: "; ")

                        if glossText.isEmpty == false {
                            Text("\(senseNumber). \(glossText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                if hiddenCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Show fewer definitions" : "Show more definitions")
                }
            }
            // Reset per entry so paging between results doesn't keep prior expanded state.
            .id(entryID)
        }
    }

    private struct ExpandableGlossPreview: View {
        let entryID: Int64
        let gloss: String

        @State private var isExpanded: Bool = false

        private let collapsedLimit: Int = 3

        private var pieces: [String] {
            gloss
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        }

        private var hiddenCount: Int {
            max(0, pieces.count - collapsedLimit)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                let shown = isExpanded ? pieces : Array(pieces.prefix(collapsedLimit))
                if shown.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { idx, text in
                            Text("\(idx + 1). \(text)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                if hiddenCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Show fewer definitions" : "Show more definitions")
                }
            }
            .id(entryID)
        }
    }

    private func iconActionButton(systemImage: String, tint: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityLabel(accessibilityLabel)
    }

    private func inlineIconButton(systemImage: String, tint: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .frame(width: 18, height: 18)
                .padding(.leading, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .accessibilityLabel(accessibilityLabel)
    }

    private func canUseReading(_ entry: DictionaryEntry) -> Bool {
        let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty == false
    }

    private func formattedTagsLine(from tags: [String]) -> String? {
        guard tags.isEmpty == false else { return nil }
        return tags.joined(separator: " · ")
    }

    private func formattedSenseMetadata(for sense: DictionaryEntrySense) -> String? {
        var components: [String] = []
        components.append(contentsOf: sense.miscellaneous)
        components.append(contentsOf: sense.fields)
        components.append(contentsOf: sense.dialects)
        guard components.isEmpty == false else { return nil }
        return components.joined(separator: " · ")
    }

    private func isKanaOnlySurface(_ surface: String) -> Bool {
        guard surface.isEmpty == false else { return false }
        return surface.unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    /// Project a lemma-level reading (dictionary kana variant) into the persisted override form.
    /// This mirrors the storage logic in PasteView.applyDictionaryReading(_:).
    private func projectedOverrideKana(tokenSurface: String, lemmaSurface: String, lemmaReading: String) -> String {
        let baseReading = lemmaReading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseReading.isEmpty == false else { return "" }

        func trailingKanaRun(in surface: String) -> String {
            guard surface.isEmpty == false else { return "" }
            let allScalars = Array(surface.unicodeScalars)
            guard allScalars.isEmpty == false else { return "" }
            var trailing: [UnicodeScalar] = []
            for scalar in allScalars.reversed() {
                let isKana = (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
                if isKana {
                    trailing.append(scalar)
                } else {
                    break
                }
            }
            guard trailing.isEmpty == false, trailing.count < allScalars.count else { return "" }
            return String(String.UnicodeScalarView(trailing.reversed()))
        }

        let tokenSuffix = trailingKanaRun(in: tokenSurface)
        let lemmaSuffix = trailingKanaRun(in: lemmaSurface)

        let surfaceReading: String = {
            guard tokenSuffix.isEmpty == false else { return baseReading }
            guard lemmaSuffix.isEmpty == false else { return baseReading }
            guard baseReading.hasSuffix(lemmaSuffix) else { return baseReading }
            let stem = String(baseReading.dropLast(lemmaSuffix.count))
            return stem + tokenSuffix
        }()

        if tokenSuffix.isEmpty == false,
           surfaceReading.hasSuffix(tokenSuffix),
           isKanaOnlySurface(tokenSurface) == false,
           tokenSurface.utf16.count > tokenSuffix.utf16.count {
            return String(surfaceReading.dropLast(tokenSuffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return surfaceReading.trimmingCharacters(in: .whitespacesAndNewlines)
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

