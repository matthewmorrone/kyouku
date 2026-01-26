import SwiftUI

struct SwipeableFlashcardsMinimalView: View {
    @State private var cards: [Card] = [
        .init(front: "漢字", back: "かんじ"),
        .init(front: "食べる", back: "たべる"),
        .init(front: "勉強", back: "べんきょう")
    ]

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing: Bool = false
    @State private var showBack: Bool = false
    @State private var flipAngleDegrees: Double = 0

    private enum GestureMode {
        case undecided
        case swipe
        case flip
    }
    @State private var gestureMode: GestureMode = .undecided
    @State private var flipStartAngleDegrees: Double = 0

    private let maxRotationDegrees: CGFloat = 10
    private let dismissDistance: CGFloat = 120
    private let dismissPredictedDistance: CGFloat = 180
    private let flipDistance: CGFloat = 110
    private let flipPredictedDistance: CGFloat = 160
    private let flipDragDistance: CGFloat = 220

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            ZStack {
                if cards.count >= 2 {
                    cardView(cards[1])
                        .scaleEffect(0.97 + 0.03 * progress)
                        .offset(y: 14 * (1 - progress))
                        .opacity(0.92 + 0.08 * progress)
                        .allowsHitTesting(false)
                }

                if let top = cards.first {
                    cardView(top)
                        .offset(dragOffset)
                        .rotationEffect(.degrees(rotationDegrees))
                        .scaleEffect(dragOffset == .zero ? 1 : 1.03)
                        .shadow(color: .black.opacity(0.16 + 0.18 * Double(progress)), radius: 16 + 10 * progress, x: 0, y: 10 + 8 * progress)
                        .zIndex(10)
                        .allowsHitTesting(true)
                        .gesture(dragGesture)
                }
            }
            .frame(width: 340, height: 420)
        }
        .onAppear {
            flipAngleDegrees = showBack ? 180 : 0
        }
        .onChange(of: showBack) { _, newValue in
            if gestureMode != .flip {
                flipAngleDegrees = newValue ? 180 : 0
            }
        }
    }

    private var progress: CGFloat {
        min(1, abs(dragOffset.width) / 160)
    }

    private var rotationDegrees: Double {
        let raw = dragOffset.width / 22
        let clamped = max(-maxRotationDegrees, min(maxRotationDegrees, raw))
        return Double(clamped)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Gesture-driven: mutate @State directly, no withAnimation here.
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
                    dragOffset = CGSize(width: 0, height: value.translation.height * 0.08)
                    let delta = (-value.translation.height / flipDragDistance) * 180
                    flipAngleDegrees = flipStartAngleDegrees + Double(delta)
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let predictedDx = value.predictedEndTranslation.width
                let predictedDy = value.predictedEndTranslation.height

                if gestureMode == .flip {
                    let shouldCommit = abs(dy) > flipDistance || abs(predictedDy) > flipPredictedDistance
                    let directionDY = (predictedDy != 0 ? predictedDy : dy)
                    let directionStep: Int = (directionDY < 0) ? 1 : -1

                    let startIndex = Int((flipStartAngleDegrees / 180).rounded())
                    let targetIndex = shouldCommit ? (startIndex + directionStep) : startIndex
                    let target = Double(targetIndex) * 180

                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
                        flipAngleDegrees = target
                        dragOffset = .zero
                    }
                    showBack = (abs(targetIndex) % 2) == 1
                    gestureMode = .undecided
                    return
                }
                gestureMode = .undecided

                let shouldDismiss = abs(dx) > dismissDistance || abs(predictedDx) > dismissPredictedDistance
                guard shouldDismiss, cards.isEmpty == false else {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                        dragOffset = .zero
                    }
                    return
                }

                isDismissing = true
                let dir: CGFloat = (predictedDx != 0 ? (predictedDx > 0) : (dx > 0)) ? 1 : -1

                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.9)) {
                    dragOffset = CGSize(width: dir * 720, height: dragOffset.height * 0.2)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    cards.removeFirst()
                    dragOffset = .zero
                    isDismissing = false
                    showBack = false
                    flipAngleDegrees = 0
                }
            }
    }

    private func cardView(_ card: Card) -> some View {
        let angle = flipAngleDegrees
        let isFrontVisible = cos(angle * .pi / 180) >= 0

        let radians = angle * .pi / 180
        let tilt = abs(sin(radians))
        let highlightOpacity = 0.02 + 0.07 * tilt
        let shadowOpacity = 0.03 + 0.12 * tilt

        return ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(highlightOpacity), Color.clear],
                        startPoint: isFrontVisible ? .top : .bottom,
                        endPoint: .center
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(shadowOpacity)],
                        startPoint: .center,
                        endPoint: isFrontVisible ? .bottom : .top
                    )
                }
                .overlay {
                    Color.black.opacity(0.02 * tilt)
                }

            Text(card.front)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .opacity(isFrontVisible ? 1 : 0)
                .rotation3DEffect(
                    .degrees(angle),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 1 / 500
                )

            Text(card.back)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(isFrontVisible ? 0 : 1)
                .rotation3DEffect(
                    .degrees(angle - 180),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 1 / 500
                )
                .padding(18)
        }
    }

    struct Card: Identifiable, Hashable {
        let id = UUID()
        let front: String
        let back: String
    }
}
