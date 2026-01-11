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
            .navigationTitle("Flashcards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        }
    }
    
    private var header: some View {
        HStack {
            Text("\(index + 1) / \(session.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                Label("\(sessionAgain)", systemImage: "arrow.uturn.left.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("\(sessionCorrect)", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Text("Review")
                    .font(.title2).bold()

                // Scope selection
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

                // Direction selection
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
                    Label("Start Review", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matchingCount == 0)
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

            cardContent
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: 320)
        }
        .opacity(isTop && isSwipingOut ? 0 : 1)
        .overlay(actionOverlays)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: dragOffset)
        .animation(.easeInOut(duration: 0.2), value: showBack)
        .gesture(dragGesture)
        .onTapGesture { toggleFace() }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .center, spacing: 10) {
            if showBack && isTop {
                backFace
            } else {
                frontFace
            }
        }
    }

    @ViewBuilder
    private var frontFace: some View {
        let displaySurface = displaySurfaceForCard(word)
        let displayKana = displayKanaForCard(word, displaySurface: displaySurface)
        switch direction {
        case .kanjiToKana:
            Text(displaySurface).font(.largeTitle.weight(.bold))
        case .kanaToEnglish:
            Text((displayKana?.isEmpty == false) ? (displayKana ?? displaySurface) : displaySurface)
                .font(.largeTitle.weight(.bold))
        }
    }

    @ViewBuilder
    private var backFace: some View {
        let displaySurface = displaySurfaceForCard(word)
        let displayKana = displayKanaForCard(word, displaySurface: displaySurface)
        switch direction {
        case .kanjiToKana:
            Text(displaySurface).font(.title2).bold()
            if let kana = displayKana, kana.isEmpty == false, kana != displaySurface {
                Text(kana).font(.title3).foregroundStyle(.secondary)
            }
            if !word.meaning.isEmpty {
                Text(word.meaning)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        case .kanaToEnglish:
            if !word.meaning.isEmpty {
                Text(word.meaning).font(.title3).bold()
            }
            if let kana = displayKana, kana.isEmpty == false {
                Text(kana).font(.title2)
            } else if displaySurface.isEmpty == false {
                Text(displaySurface).font(.title2)
            }

            // Only show an additional surface line if it's kana-only.
            let rawSurface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawSurface.isEmpty == false,
               rawSurface != displaySurface,
               isKanaOnlySurface(rawSurface) {
                Text(rawSurface)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
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
                dragOffset = value.translation
            }
            .onEnded { value in
                guard isTop else { return }
                handleDragEnd(value.translation.width)
            }
    }

    private func handleDragEnd(_ dx: CGFloat) {
        let tiny: CGFloat = 1
        if dx > tiny {
            swipeOut(direction: 1) {
                onKnow()
            }
        } else if dx < -tiny {
            swipeOut(direction: -1) {
                onAgain()
            }
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                dragOffset = .zero
            }
        }
    }

    private func swipeOut(direction dir: Int, completion: @escaping () -> Void) {
        withAnimation(.none) { dragOffset = .zero }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isSwipingOut = true
            swipeDirection = dir
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            completion()
            showBack = false
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                isSwipingOut = false
                swipeDirection = 0
            }
        }
    }

    private func toggleFace() {
        guard isTop else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            showBack.toggle()
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

