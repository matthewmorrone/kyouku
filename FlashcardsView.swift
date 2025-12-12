import SwiftUI

struct FlashcardsView: View {
    @EnvironmentObject var store: WordStore

    @State private var session: [Word] = []
    @State private var index: Int = 0
    @State private var showBack: Bool = false
    @State private var shuffled: Bool = true

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
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if store.words.isEmpty {
                    emptySavedState
                } else if session.isEmpty {
                    reviewHome
                } else {
                    header
                    Spacer(minLength: 8)
                    card
                        .offset(x: dragOffset.width)
                        .rotationEffect(.degrees(Double(dragOffset.width / 12)))
                        .gesture(DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                let threshold: CGFloat = 80
                                if value.translation.width > threshold {
                                    know()
                                } else if value.translation.width < -threshold {
                                    again()
                                }
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    dragOffset = .zero
                                }
                            }
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                showBack.toggle()
                            }
                        }
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shuffled.toggle()
                        startSession()
                    } label: {
                        Image(systemName: shuffled ? "shuffle" : "shuffle.slash")
                    }
                    .help(shuffled ? "Shuffle On" : "Shuffle Off")
                }
            }
        }
        .onAppear {
            startSession()
        }
        .onChange(of: store.words) { oldValue, newValue in
            startSession()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("\(index + 1) / \(session.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var card: some View {
        let word = session[index]
        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

            VStack(alignment: .center, spacing: 10) {
                if showBack {
                    switch direction {
                    case .kanjiToKana:
                        Text(word.surface).font(.title2).bold()
                        if !word.reading.isEmpty { Text(word.reading).font(.title3).foregroundStyle(.secondary) }
                        if !word.meaning.isEmpty { Text(word.meaning).font(.body).multilineTextAlignment(.center).padding(.top, 6) }
                    case .kanaToEnglish:
                        if !word.meaning.isEmpty { Text(word.meaning).font(.title3).bold() }
                        if !word.reading.isEmpty { Text(word.reading).font(.title2) }
                        if !word.surface.isEmpty { Text(word.surface).font(.body).foregroundStyle(.secondary) }
                    }
                } else {
                    switch direction {
                    case .kanjiToKana:
                        Text(word.surface).font(.largeTitle.weight(.bold))
                    case .kanaToEnglish:
                        if !word.reading.isEmpty { Text(word.reading).font(.largeTitle.weight(.bold)) }
                        else { Text(word.surface).font(.largeTitle.weight(.bold)) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
        .animation(.easeInOut(duration: 0.2), value: showBack)
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
            Button { startSession() } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
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
                    Text("Review from a specific note is not yet wired to notes metadata.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Direction selection
                Picker("Direction", selection: $direction) {
                    ForEach(CardDirection.allCases) { d in
                        Text(d.rawValue).tag(d)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    startSessionFromHome()
                } label: {
                    Label("Start Review", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Logic

    private func startSession() {
        session = store.words
        if shuffled { session.shuffle() }
        index = session.isEmpty ? 0 : 0
        showBack = false
    }

    private func again() {
        guard !session.isEmpty else { return }
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
        ReviewPersistence.markRight(session[index].id)
        session.remove(at: index)
        if session.isEmpty { return }
        if index >= session.count { index = max(0, session.count - 1) }
        showBack = false
    }

    private func startSessionFromHome() {
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
            // Requires Note linkage on Word to filter; currently not available.
            base = store.words
        }
        session = base
        if shuffled { session.shuffle() }
        index = session.isEmpty ? 0 : 0
        showBack = false
    }
}
