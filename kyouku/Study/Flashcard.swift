import SwiftUI

struct Flashcard: View {
    let word: Word
    let isTop: Bool
    let direction: FlashcardsView.CardDirection
    let preferredNoteID: UUID?
    @Binding var showBack: Bool
    @Binding var dragOffset: CGSize
    @Binding var isSwipingOut: Bool
    @Binding var swipeDirection: Int
    let onKnow: () -> Void
    let onAgain: () -> Void

    @EnvironmentObject var notes: NotesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        let tilt = abs(sin(radians))
        let perspective: CGFloat = reduceMotion ? 1 / 650 : 1 / 320
        // Add a tiny sideways roll so the flip reads more 3D.
        let roll = (reduceMotion ? 0 : (6 * tilt))
        let frontRoll = roll
        let backRoll = -roll

        ZStack {
            cardFace(flipAngle: angle, face: .front) {
                frontFace
            }
                .opacity(isFrontVisible ? 1 : 0)
                .rotation3DEffect(
                    .degrees(angle),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: perspective
                )
                .rotation3DEffect(
                    .degrees(frontRoll),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: perspective
                )

            cardFace(flipAngle: angle, face: .back) {
                backFace
            }
                .opacity(isFrontVisible ? 0 : 1)
                .rotation3DEffect(
                    .degrees(angle - 180),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: perspective
                )
                .rotation3DEffect(
                    .degrees(backRoll),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: perspective
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

        // Subtle face cue: a small gloss/shade that swaps corners per face.
        let glossStrength = reduceMotion ? 0.0 : (0.03 + 0.10 * tilt)
        let shadeStrength = 0.05 + 0.07 * tilt

        let highlightOpacity = 0.02 + 0.07 * tilt
        let shadowOpacity = 0.03 + 0.12 * tilt

        let highlightFromTop = (face == .front)
        let highlightStart: UnitPoint = highlightFromTop ? .top : .bottom
        let highlightEnd: UnitPoint = .center
        let shadowStart: UnitPoint = .center
        let shadowEnd: UnitPoint = highlightFromTop ? .bottom : .top

        let glossCorner: UnitPoint = (face == .front) ? .topLeading : .topTrailing
        let shadeCorner: UnitPoint = (face == .front) ? .bottomTrailing : .bottomLeading

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
                .overlay {
                    RadialGradient(
                        colors: [Color.white.opacity(glossStrength), Color.clear],
                        center: glossCorner,
                        startRadius: 0,
                        endRadius: 180
                    )
                    .blendMode(.screen)
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.black.opacity(shadeStrength), Color.clear],
                        center: shadeCorner,
                        startRadius: 0,
                        endRadius: 220
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.06 + 0.10 * tilt), lineWidth: 1)
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

        let candidateNoteID = preferredNoteID ?? word.sourceNoteIDs.first
        guard let noteID = candidateNoteID else {
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
        // Avoid spring rebounds here; a committed swipe should feel like a clean
        // transition to the next card.
        let remaining = abs(offX - dragOffset.width)
        // Clamp the perceived velocity so a quick flick doesn't yeet the card off-screen instantly.
        let pointsPerSecond: CGFloat = 1600
        let computedDuration = Double(remaining / pointsPerSecond)
        let duration = reduceMotion ? 0.01 : min(0.50, max(0.28, computedDuration))
        isSwipingOut = true
        swipeDirection = dir
        withAnimation(.easeOut(duration: duration)) {
            dragOffset = CGSize(width: offX, height: dragOffset.height * 0.2)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            completion()
            showBack = false
            dragOffset = .zero

            // Reset without animation so the next card doesn't "bounce".
            isSwipingOut = false
            swipeDirection = 0
        }
    }

}

