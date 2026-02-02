import SwiftUI

struct FlashcardsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var notes: NotesStore

    @State private var session: [Word] = []
    @State private var sessionSource: [Word] = []
    @State private var index: Int = 0
    @State private var showBack: Bool = false
    @State private var shuffled: Bool = true

    @State private var dragOffset: CGSize = .zero
    @State private var isSwipingOut: Bool = false
    @State private var swipeDirection: Int = 0

    @State private var sessionCorrect: Int = 0
    @State private var sessionAgain: Int = 0

    @State private var showEndSessionConfirm: Bool = false

    private struct EditingWord: Identifiable {
        let id: Word.ID
    }

    @State private var editingWord: EditingWord? = nil

    enum ReviewScope: String, CaseIterable, Identifiable {
        case all = "All"
        case mostRecent = "Most Recent"
        case markedWrong = "Marked Wrong"
        case fromNote = "From Note"
        var id: String { rawValue }
    }

    enum CardDirection: String, CaseIterable, Identifiable {
        case kanjiToKana = "Kanji → Kana"
        case kanaToEnglish = "Kana → English"
        var id: String { rawValue }
    }

    @State private var scope: ReviewScope = .all
    @State private var direction: CardDirection = .kanjiToKana
    @State private var mostRecentCount: Int = 20
    @State private var selectedNoteID: UUID? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if store.words.isEmpty {
                    emptySavedState
                } else if session.isEmpty {
                    if sessionSource.isEmpty {
                        reviewHome
                    } else {
                        sessionCompleteState
                    }
                } else {
                    header
                    Spacer(minLength: 8)
                    cardStack
                    Spacer(minLength: 8)
                    controls
                }
            }
            .padding()
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.isEmpty == false {
                        Button {
                            showEndSessionConfirm = true
                        } label: {
                            Label("End", systemImage: "xmark.circle")
                        }
                        .help("End Session")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startSession()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart")
                    .disabled(sessionSource.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shuffled.toggle()
                        if !sessionSource.isEmpty {
                            startSession()
                        }
                    } label: {
                        Image(systemName: shuffled ? "shuffle" : "shuffle.slash")
                    }
                    .help(shuffled ? "Shuffle On" : "Shuffle Off")
                }
            }
            .alert("End session?", isPresented: $showEndSessionConfirm) {
                Button("End Session", role: .destructive) {
                    endSessionEarly()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop the current review session.")
            }
            .sheet(item: $editingWord) { item in
                WordEditView(wordID: item.id)
            }
        }
        .appThemedRoot()
        // Hide the Cards tab page dots while actively reviewing flashcards.
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: session.isEmpty == false)
    }
    
    private var header: some View {
        HStack {
            Text("\(index + 1) / \(session.count)")
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
            HStack(spacing: 12) {
                Label("\(sessionAgain)", systemImage: "arrow.uturn.left.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                Label("\(sessionCorrect)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    private var cardStack: some View {
        let count = session.count
        let topIndex = index
        let end = min(topIndex + 3, count)
        return ZStack {
            ForEach(Array((topIndex..<end)).reversed(), id: \.self) { idx in
                let isTop = (idx == topIndex)
                FlashcardCard(
                    word: session[idx],
                    isTop: isTop,
                    direction: direction,
                    showBack: $showBack,
                    dragOffset: $dragOffset,
                    isSwipingOut: $isSwipingOut,
                    swipeDirection: $swipeDirection,
                    onKnow: { know() },
                    onAgain: { again() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { again() } label: {
                HStack { Image(systemName: "arrow.uturn.left.circle"); Text("Again") }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                guard session.isEmpty == false else { return }
                editingWord = EditingWord(id: session[index].id)
            } label: {
                HStack { Image(systemName: "pencil"); Text("Edit") }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button { know() } label: {
                HStack { Image(systemName: "checkmark.circle.fill"); Text("Know") }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptySavedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book")
                .font(.largeTitle)
            Text("No saved words")
                .font(.headline)
            Text("Add words from Paste or Notes to start reviewing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionCompleteState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
            Text("Session complete")
                .font(.headline)

            // Session summary
            HStack(spacing: 16) {
                Label("\(sessionCorrect) correct", systemImage: "checkmark.circle.fill")
                Label("\(sessionAgain) again", systemImage: "arrow.uturn.left.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            // Lifetime accuracy
            if let acc = ReviewPersistence.lifetimeAccuracy() {
                let pct = Int((acc * 100).rounded())
                Text("Lifetime accuracy: \(pct)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Lifetime accuracy: —")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                startSession()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(sessionSource.isEmpty)

            Button {
                session = []
                sessionSource = []
            } label: {
                Label("Choose Different Cards", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Flashcards", systemImage: "rectangle.on.rectangle.angled")
                        .font(.headline)

                    Picker("Scope", selection: $scope) {
                        ForEach(ReviewScope.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scope == .mostRecent {
                        Stepper("Most recent: \u{200E}\(mostRecentCount)", value: $mostRecentCount, in: 5...200, step: 5)
                    } else if scope == .fromNote {
                        NotePicker(selectedNoteID: $selectedNoteID)
                    }

                    Picker("Direction", selection: $direction) {
                        ForEach(CardDirection.allCases) { d in
                            Text(d.rawValue).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)

                    let matchingCount = wordsMatchingSelection().count
                    Text(matchingCount == 0 ? "No cards match this selection" : "Cards in selection: \(matchingCount)")
                        .font(.footnote)
                        .foregroundStyle(matchingCount == 0 ? .red : .secondary)

                    Button {
                        startSessionFromHome()
                    } label: {
                        Label("Start Flashcards", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(matchingCount == 0)
                }
                .padding(12)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
            }
            .padding()
        }
    }

    // MARK: - Logic

    private func startSession() {
        guard !sessionSource.isEmpty else {
            session = []
            index = 0
            showBack = false
            dragOffset = .zero
            return
        }

        sessionCorrect = 0
        sessionAgain = 0

        session = sessionSource
        if shuffled { session.shuffle() }
        index = 0
        showBack = false
        dragOffset = .zero
    }

    private func again() {
        guard !session.isEmpty else { return }
        sessionAgain += 1
        ReviewPersistence.incrementAgain()
        let w = session[index]
        ReviewPersistence.recordAgain(for: w.id)
        ReviewPersistence.markWrong(w.id)
        // Move current card to the end of the session
        session.remove(at: index)
        session.append(w)
        // If we removed the last index, wrap around
        if index >= session.count { index = session.count - 1 }
        showBack = false
    }

    private func know() {
        guard !session.isEmpty else { return }
        sessionCorrect += 1
        ReviewPersistence.incrementCorrect()
        ReviewPersistence.recordCorrect(for: session[index].id)
        ReviewPersistence.markRight(session[index].id)
        session.remove(at: index)
        if session.isEmpty { return }
        if index >= session.count { index = max(0, session.count - 1) }
        showBack = false
    }

    private func startSessionFromHome() {
        let base = wordsMatchingSelection()
        sessionSource = base
        startSession()
    }

    private func endSessionEarly() {
        session = []
        sessionSource = []
        index = 0
        showBack = false
        dragOffset = .zero
        isSwipingOut = false
        swipeDirection = 0
        sessionCorrect = 0
        sessionAgain = 0
    }

    private func wordsMatchingSelection() -> [Word] {
        var base = store.words
        switch scope {
        case .all:
            break
        case .mostRecent:
            base = Array(base.sorted(by: { $0.createdAt > $1.createdAt }).prefix(mostRecentCount))
        case .markedWrong:
            let wrong = ReviewPersistence.allWrong()
            base = base.filter { wrong.contains($0.id) }
        case .fromNote:
            if let id = selectedNoteID {
                base = base.filter { $0.sourceNoteID == id }
            }
        }
        return base
    }
}

private struct FlashcardCard: View {
    let word: Word
    let isTop: Bool
    let direction: FlashcardsView.CardDirection
    @Binding var showBack: Bool
    @Binding var dragOffset: CGSize
    @Binding var isSwipingOut: Bool
    @Binding var swipeDirection: Int
    let onKnow: () -> Void
    let onAgain: () -> Void

    @EnvironmentObject var notes: NotesStore

    private enum GestureMode {
        case undecided
        case swipe
        case flip
    }

    @State private var gestureMode: GestureMode = .undecided
    @State private var flipAngleDegrees: Double = 0
    @State private var flipStartAngleDegrees: Double = 0

    private enum CardFaceKind {
        case front
        case back
    }

    private let maxRotationDegrees: CGFloat = 10
    private let dismissDistance: CGFloat = 120
    private let dismissPredictedDistance: CGFloat = 180
    private let flipDistance: CGFloat = 110
    private let flipPredictedDistance: CGFloat = 160

    private let flipDragDistance: CGFloat = 220

    var body: some View {
        cardContent
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
        .contentShape(Rectangle())
        .offset(x: isTop ? dragOffset.width : 0, y: isTop ? dragOffset.height : 0)
        .rotationEffect(.degrees(isTop ? currentRotationDegrees : 0))
        .scaleEffect(isTop && dragOffset != .zero ? 1.03 : 1)
        .shadow(
            color: Color.black.opacity(isTop ? currentShadowOpacity : 0.08),
            radius: isTop ? (8 + 10 * dragProgress) : 8,
            x: 0,
            y: isTop ? (4 + 10 * dragProgress) : 4
        )
        .overlay(actionOverlays)
        .zIndex(isTop ? 10 : 0)
        .allowsHitTesting(isTop)
        .gesture(dragGesture)
        .onAppear {
            if isTop {
                flipAngleDegrees = showBack ? 180 : 0
            }
        }
        .onChange(of: isTop) { _, newValue in
            if newValue {
                flipAngleDegrees = showBack ? 180 : 0
            }
        }
        .onChange(of: showBack) { _, newValue in
            guard isTop else { return }
            guard gestureMode != .flip else { return }
            flipAngleDegrees = newValue ? 180 : 0
        }
    }

    private var dragProgress: CGFloat {
        guard isTop else { return 0 }
        return min(1, abs(dragOffset.width) / 140)
    }

    private var currentRotationDegrees: Double {
        guard isTop else { return 0 }
        let raw = (dragOffset.width / 22) // ~10° around 220pt
        let clamped = max(-maxRotationDegrees, min(maxRotationDegrees, raw))
        return Double(clamped)
    }

    private var currentShadowOpacity: Double {
        0.14 + Double(0.18 * dragProgress)
    }

    @ViewBuilder
    private var cardContent: some View {
        let angle = isTop ? flipAngleDegrees : 0
        let radians = angle * .pi / 180
        let isFrontVisible = cos(radians) >= 0

        ZStack {
            cardFace(flipAngle: angle, face: .front) {
                frontFace
            }
                .opacity(isFrontVisible ? 1 : 0)
                .rotation3DEffect(
                    .degrees(angle),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 1 / 500
                )

            cardFace(flipAngle: angle, face: .back) {
                backFace
            }
                .opacity(isFrontVisible ? 0 : 1)
                .rotation3DEffect(
                    .degrees(angle - 180),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 1 / 500
                )
        }
    }

    private func cardFace<Content: View>(
        flipAngle: Double,
        face: CardFaceKind,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let radians = flipAngle * .pi / 180
        let tilt = abs(sin(radians))

        let highlightOpacity = 0.02 + 0.07 * tilt
        let shadowOpacity = 0.03 + 0.12 * tilt

        let highlightFromTop = (face == .front)
        let highlightStart: UnitPoint = highlightFromTop ? .top : .bottom
        let highlightEnd: UnitPoint = .center
        let shadowStart: UnitPoint = .center
        let shadowEnd: UnitPoint = highlightFromTop ? .bottom : .top

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(highlightOpacity), Color.clear],
                        startPoint: highlightStart,
                        endPoint: highlightEnd
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(shadowOpacity)],
                        startPoint: shadowStart,
                        endPoint: shadowEnd
                    )
                }
                .overlay {
                    Color.black.opacity(0.02 * tilt)
                }

            content()
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: 320)
        }
    }

    @ViewBuilder
    private var frontFace: some View {
        let displaySurface = displaySurfaceForCard(word)
        let displayKana = displayKanaForCard(word, displaySurface: displaySurface)
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)

            switch direction {
            case .kanjiToKana:
                Text(displaySurface)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
            case .kanaToEnglish:
                Text((displayKana?.isEmpty == false) ? (displayKana ?? displaySurface) : displaySurface)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var backFace: some View {
        let displaySurface = displaySurfaceForCard(word)
        let displayKana = displayKanaForCard(word, displaySurface: displaySurface)
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)

            switch direction {
            case .kanjiToKana:
                // Kanji → Kana: back shows kana only.
                if let kana = displayKana, kana.isEmpty == false {
                    Text(kana)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                } else if isKanaOnlySurface(displaySurface) {
                    Text(displaySurface)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                } else {
                    Text("—")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

            case .kanaToEnglish:
                // Kana → English: back shows English meaning only.
                if word.meaning.isEmpty == false {
                    Text(word.meaning)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                } else {
                    Text("—")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func displaySurfaceForCard(_ word: Word) -> String {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = word.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (kana?.isEmpty == false) ? kana : nil

        guard let noteID = word.sourceNoteID else {
            return surface
        }
        guard let noteText = notes.notes.first(where: { $0.id == noteID })?.text, noteText.isEmpty == false else {
            return surface
        }

        // Prefer the form that actually appears in the source note.
        if surface.isEmpty == false, noteText.contains(surface) {
            return surface
        }
        if let normalizedKana, noteContains(noteText, candidate: normalizedKana) {
            return normalizedKana
        }
        return surface
    }

    private func displayKanaForCard(_ word: Word, displaySurface: String) -> String? {
        if let kana = word.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false {
            return kana
        }
        // If the saved/displayed surface is kana-only, treat it as the kana line.
        if isKanaOnlySurface(displaySurface) {
            return displaySurface
        }
        return nil
    }

    private func noteContains(_ noteText: String, candidate: String) -> Bool {
        if noteText.contains(candidate) { return true }
        // Kana-folded containment so hiragana/katakana differences don't matter.
        let foldedNote = kanaFoldToHiragana(noteText)
        let foldedCandidate = kanaFoldToHiragana(candidate)
        return foldedNote.contains(foldedCandidate)
    }

    private func kanaFoldToHiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private func isKanaOnlySurface(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            // Hiragana
            if (0x3040...0x309F).contains(scalar.value) { return true }
            // Katakana
            if (0x30A0...0x30FF).contains(scalar.value) { return true }
            // Prolonged sound mark
            if scalar.value == 0x30FC { return true }
            // Half-width katakana
            if (0xFF66...0xFF9F).contains(scalar.value) { return true }
            return false
        }
    }

    @ViewBuilder
    private var actionOverlays: some View {
        if isTop {
            Group {
                Text("Again")
                    .font(.headline)
                    .padding(8)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(8)
                    .opacity(max(0, min(1, -dragOffset.width / 100)))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Text("Know")
                    .font(.headline)
                    .padding(8)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(8)
                    .opacity(max(0, min(1, dragOffset.width / 100)))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isTop else { return }
                // Gesture-driven motion must be immediate: no withAnimation here.

                if gestureMode == .undecided {
                    let t = value.translation
                    if abs(t.width) > 12 || abs(t.height) > 12 {
                        gestureMode = abs(t.width) >= abs(t.height) ? .swipe : .flip
                        if gestureMode == .flip {
                            flipStartAngleDegrees = flipAngleDegrees
                        }
                    }
                }

                switch gestureMode {
                case .swipe, .undecided:
                    dragOffset = value.translation
                case .flip:
                    // Keep only a subtle lift movement during flip.
                    dragOffset = CGSize(width: 0, height: value.translation.height * 0.08)
                    let delta = (-value.translation.height / flipDragDistance) * 180
                    flipAngleDegrees = flipStartAngleDegrees + Double(delta)
                }
            }
            .onEnded { value in
                guard isTop else { return }
                switch gestureMode {
                case .flip:
                    finishFlip(translation: value.translation, predicted: value.predictedEndTranslation)
                case .swipe, .undecided:
                    handleDragEnd(translation: value.translation, predicted: value.predictedEndTranslation)
                }
                gestureMode = .undecided
            }
    }

    private func handleDragEnd(translation: CGSize, predicted: CGSize) {
        let dx = translation.width
        let predictedDx = predicted.width

        let shouldDismiss = abs(dx) > dismissDistance || abs(predictedDx) > dismissPredictedDistance
        guard shouldDismiss else {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                dragOffset = .zero
            }
            return
        }

        let dir: Int = (predictedDx != 0 ? (predictedDx > 0) : (dx > 0)) ? 1 : -1
        swipeOut(direction: dir) {
            if dir > 0 {
                onKnow()
            } else {
                onAgain()
            }
        }
    }

    private func finishFlip(translation: CGSize, predicted: CGSize) {
        let dy = translation.height
        let predictedDy = predicted.height

        let shouldCommit = abs(dy) > flipDistance || abs(predictedDy) > flipPredictedDistance
        let directionDY = (predictedDy != 0 ? predictedDy : dy)
        let directionStep: Int = (directionDY < 0) ? 1 : -1  // Up advances, down reverses.

        // Anchor decisions to the starting, settled face so we never "double count"
        // a near-180° drag and accidentally land back on the same side.
        let startIndex = Int((flipStartAngleDegrees / 180).rounded())
        let targetIndex = shouldCommit ? (startIndex + directionStep) : startIndex

        let targetAngle = Double(targetIndex) * 180

        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            flipAngleDegrees = targetAngle
            dragOffset = .zero
        }
        showBack = (abs(targetIndex) % 2) == 1
    }

    private func swipeOut(direction dir: Int, completion: @escaping () -> Void) {
        let offX: CGFloat = CGFloat(dir) * 720
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.9)) {
            isSwipingOut = true
            swipeDirection = dir
            dragOffset = CGSize(width: offX, height: dragOffset.height * 0.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            completion()
            showBack = false
            dragOffset = .zero
            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86)) {
                isSwipingOut = false
                swipeDirection = 0
            }
        }
    }

}

private struct NotePicker: View {
    @EnvironmentObject var notes: NotesStore
    @Binding var selectedNoteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.notes.isEmpty {
                Text("No notes available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Note", selection: $selectedNoteID) {
                    Text("Any Note").tag(UUID?.none)
                    ForEach(notes.notes) { note in
                        Text(note.title?.isEmpty == false ? note.title! : "Untitled").tag(UUID?.some(note.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

