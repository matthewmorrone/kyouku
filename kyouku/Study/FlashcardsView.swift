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

    // Progress UI: keep a stable denominator for the session.
    @State private var sessionTotalCount: Int = 0
    @State private var reviewedCount: Int = 0

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
        case kanjiToKana = "漢字 → かな"
        case kanaToEnglish = "かな → English"
        var id: String { rawValue }
    }

    @State private var scope: ReviewScope = .all
    @State private var direction: CardDirection = .kanjiToKana
    @State private var mostRecentCount: Int = 20
    @State private var selectedNoteID: UUID? = nil

    var body: some View {
        NavigationStack {
            Group {
                if store.words.isEmpty {
                    emptySavedState
                } else if session.isEmpty {
                    if sessionSource.isEmpty {
                        reviewHome
                    } else {
                        sessionCompleteState
                    }
                } else {
                    VStack(spacing: 16) {
                        header
                        Spacer(minLength: 8)
                        cardStack
                        Spacer(minLength: 8)
                        controls
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                /*ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                        Text("Flashcards")
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Flashcards")
                }*/
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
                if session.isEmpty == false || sessionSource.isEmpty == false {
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
            Text("\(progressNumerator) / \(sessionTotalCount)")
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
                Flashcard(
                    word: session[idx],
                    isTop: isTop,
                    direction: direction,
                    preferredNoteID: (scope == .fromNote ? selectedNoteID : nil),
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
            .tint(Color(UIColor.systemRed))

            Spacer()

            Button {
                guard session.isEmpty == false else { return }
                editingWord = EditingWord(id: session[index].id)
            } label: {
                HStack { Image(systemName: "pencil"); Text("Edit") }
            }
            .buttonStyle(.bordered)
            .tint(Color(UIColor.label))

            Spacer()

            Button { know() } label: {
                HStack { Image(systemName: "checkmark.circle.fill"); Text("Know") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(UIColor.systemGreen))
        }
    }

    private var progressNumerator: Int {
        guard sessionTotalCount > 0 else { return 0 }
        // Display the next "card number" (1-indexed), not the mutable session.count.
        return reviewedCount + 1
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
        Form {
            Section {
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
            } header: {
                Label("Flashcards", systemImage: "rectangle.on.rectangle.angled")
            }

            Section {
                Picker("Direction", selection: $direction) {
                    ForEach(CardDirection.allCases) { d in
                        Text(d.rawValue).tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }/* header: {
                Text("Direction")
            }*/

            Section {
                let matchingCount = wordsMatchingSelection().count

                Button {
                    shuffled.toggle()
                } label: {
                    Label(shuffled ? "Shuffle On" : "Shuffle Off", systemImage: shuffled ? "shuffle" : "shuffle.slash")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cards in selection")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(matchingCount)")
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(matchingCount == 0 ? .red : Color.appTextPrimary)

                    if matchingCount == 0 {
                        Text("No cards match this selection")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)

                Button {
                    startSessionFromHome()
                } label: {
                    Label("Start Flashcards", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matchingCount == 0)
            }
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
        reviewedCount = 0

        session = sessionSource
        if shuffled { session.shuffle() }
        sessionTotalCount = session.count
        index = 0
        showBack = false
        dragOffset = .zero
    }

    private func again() {
        guard !session.isEmpty else { return }
        sessionAgain += 1
        reviewedCount += 1
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
        reviewedCount += 1
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
        sessionTotalCount = 0
        reviewedCount = 0
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
                base = base.filter { $0.sourceNoteIDs.contains(id) }
            }
        }
        return base
    }
}
