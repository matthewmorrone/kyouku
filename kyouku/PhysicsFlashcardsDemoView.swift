import SwiftUI
import UIKit

struct PhysicsFlashcardsDemoView: View {
    var body: some View {
        PhysicsFlashcardsDeckView(
            cards: [
                .init(front: "くれる", back: "Benefactive helper: Vてくれる\n= someone does V for me/us"),
                .init(front: "しまう", back: "Completion/regret: Vてしまう"),
                .init(front: "ように", back: "Purpose/so that: 〜ように"),
                .init(front: "ことがある", back: "Experience/occasion: 〜ことがある")
            ]
        )
        .ignoresSafeArea()
        .background(Color.black.opacity(0.9))
    }
}

struct PhysicsFlashcard: Hashable {
    let front: String
    let back: String
}

struct PhysicsFlashcardsDeckView: UIViewControllerRepresentable {
    let cards: [PhysicsFlashcard]

    func makeUIViewController(context: Context) -> PhysicsFlashcardsDeckViewController {
        let vc = PhysicsFlashcardsDeckViewController(cards: cards)
        return vc
    }

    func updateUIViewController(_ uiViewController: PhysicsFlashcardsDeckViewController, context: Context) {
        uiViewController.setCards(cards)
    }
}

@MainActor
final class PhysicsFlashcardsDeckViewController: UIViewController {
    private var cards: [PhysicsFlashcard]

    private var topCard: PhysicsFlashcardView?
    private var nextCard: PhysicsFlashcardView?

    private var pan: UIPanGestureRecognizer!

    private var interactionMode: InteractionMode = .undecided
    private var panStartCenter: CGPoint = .zero
    private var swipeStartTransform: CGAffineTransform = .identity
    private var flipStartAngle: CGFloat = 0

    private let maxRotationDegrees: CGFloat = 10
    private let dismissDistance: CGFloat = 120
    private let dismissVelocity: CGFloat = 900

    private let liftScale: CGFloat = 1.03
    private let baseShadowOpacity: Float = 0.18
    private let liftShadowOpacity: Float = 0.32

    private enum InteractionMode {
        case undecided
        case swipe
        case flip
    }

    init(cards: [PhysicsFlashcard]) {
        self.cards = cards
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        reloadStack(reset: true)
    }

    func setCards(_ cards: [PhysicsFlashcard]) {
        // Keep state if the list is identical.
        guard cards != self.cards else { return }
        self.cards = cards
        reloadStack(reset: true)
    }

    private func reloadStack(reset: Bool) {
        topCard?.removeFromSuperview()
        nextCard?.removeFromSuperview()
        topCard = nil
        nextCard = nil

        guard cards.isEmpty == false else { return }

        if cards.count >= 2 {
            let next = makeCardView(card: cards[1])
            nextCard = next
            view.addSubview(next)
        }

        let top = makeCardView(card: cards[0])
        topCard = top
        view.addSubview(top)

        layoutCards()

        applyNextCardProgress(0)
        applyLift(isLifted: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCards()
    }

    private func layoutCards() {
        let inset: CGFloat = 22
        let maxWidth = min(view.bounds.width - inset * 2, 420)
        let maxHeight = min(view.bounds.height * 0.62, 520)
        let frame = CGRect(
            x: (view.bounds.width - maxWidth) / 2,
            y: (view.bounds.height - maxHeight) / 2,
            width: maxWidth,
            height: maxHeight
        )

        topCard?.frame = frame
        nextCard?.frame = frame

        // Keep next under top.
        if let nextCard, let topCard {
            view.sendSubviewToBack(nextCard)
            view.bringSubviewToFront(topCard)
        }

        // If the top card isn't being interacted with, keep it centered.
        if interactionMode == .undecided {
            topCard?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
    }

    private func makeCardView(card: PhysicsFlashcard) -> PhysicsFlashcardView {
        let v = PhysicsFlashcardView(frontText: card.front, backText: card.back)
        v.isUserInteractionEnabled = false
        return v
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let topCard else { return }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            interactionMode = .undecided
            panStartCenter = topCard.center
            swipeStartTransform = CGAffineTransform(scaleX: liftScale, y: liftScale)
            flipStartAngle = topCard.currentFlipAngle
            topCard.stopRunningAnimations()
            topCard.setAffineTransformDirect(swipeStartTransform)
            applyLift(isLifted: true)

        case .changed:
            if interactionMode == .undecided {
                if abs(translation.x) > 12 || abs(translation.y) > 12 {
                    interactionMode = abs(translation.x) >= abs(translation.y) ? .swipe : .flip
                }
            }

            switch interactionMode {
            case .swipe:
                updateSwipe(translation: translation)
            case .flip:
                updateFlip(translation: translation)
            case .undecided:
                break
            }

        case .ended, .cancelled, .failed:
            switch interactionMode {
            case .swipe:
                finishSwipe(translation: translation, velocity: velocity)
            case .flip:
                finishFlip(translation: translation, velocity: velocity)
            case .undecided:
                snapBack()
            }
            interactionMode = .undecided

        default:
            break
        }
    }

    // MARK: Swipe (left/right)

    private func updateSwipe(translation: CGPoint) {
        guard let topCard else { return }

        let dx = translation.x
        let dy = translation.y

        topCard.center = CGPoint(x: panStartCenter.x + dx, y: panStartCenter.y + dy * 0.12)

        let width = max(1, view.bounds.width)
        let progress = min(1, abs(dx) / max(1, dismissDistance))

        let maxRadians = maxRotationDegrees * .pi / 180
        let angle = max(-maxRadians, min(maxRadians, (dx / width) * maxRadians * 1.6))

        let t = swipeStartTransform.rotated(by: angle)

        topCard.setAffineTransformDirect(t)
        topCard.setLiftedShadow(progress: progress)

        applyNextCardProgress(progress)
    }

    private func finishSwipe(translation: CGPoint, velocity: CGPoint) {
        guard topCard != nil else { return }

        let dx = translation.x
        let vx = velocity.x

        let shouldDismiss = abs(dx) > dismissDistance || abs(vx) > dismissVelocity

        if shouldDismiss {
            let direction: CGFloat = (dx + vx * 0.12) >= 0 ? 1 : -1
            dismissTopCard(direction: direction, velocityX: vx)
        } else {
            snapBack()
        }
    }

    private func snapBack() {
        guard let topCard else { return }

        let targetCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let fromCenter = topCard.center
        let delta = CGPoint(x: targetCenter.x - fromCenter.x, y: targetCenter.y - fromCenter.y)

        let spring = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: CGVector(dx: delta.x / 400, dy: delta.y / 400))
        let animator = UIViewPropertyAnimator(duration: 0.55, timingParameters: spring)
        topCard.register(animator)

        animator.addAnimations { [weak self] in
            guard let self else { return }
            topCard.center = targetCenter
            topCard.transform = .identity
            topCard.setLiftedShadow(progress: 0)
            self.applyNextCardProgress(0)
        }

        animator.addCompletion { [weak self] _ in
            self?.applyLift(isLifted: false)
        }

        animator.startAnimation()
    }

    private func dismissTopCard(direction: CGFloat, velocityX: CGFloat) {
        guard let topCard else { return }

        let offX = view.bounds.midX + direction * (view.bounds.width * 0.9)
        let offY = view.bounds.midY + (velocityX.sign == .minus ? -1 : 1) * 40

        let targetCenter = CGPoint(x: offX, y: offY)
        let fromCenter = topCard.center
        let delta = CGPoint(x: targetCenter.x - fromCenter.x, y: targetCenter.y - fromCenter.y)

        let spring = UISpringTimingParameters(dampingRatio: 0.9, initialVelocity: CGVector(dx: delta.x / 600, dy: delta.y / 600))
        let animator = UIViewPropertyAnimator(duration: 0.5, timingParameters: spring)
        topCard.register(animator)

        animator.addAnimations { [weak self] in
            guard let self else { return }
            let maxRadians = self.maxRotationDegrees * .pi / 180
            topCard.center = targetCenter
            topCard.transform = CGAffineTransform(scaleX: self.liftScale, y: self.liftScale).rotated(by: direction * maxRadians)
            topCard.alpha = 0.2
            self.applyNextCardProgress(1)
        }

        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.consumeTopCardAndAdvance()
            self.applyLift(isLifted: false)
        }

        animator.startAnimation()
    }

    private func consumeTopCardAndAdvance() {
        guard cards.isEmpty == false else { return }

        // Remove first.
        cards.removeFirst()

        // Promote next to top.
        topCard?.removeFromSuperview()
        topCard = nextCard
        nextCard = nil

        if cards.count >= 2 {
            let newNext = makeCardView(card: cards[1])
            nextCard = newNext
            view.insertSubview(newNext, belowSubview: topCard ?? view)
        }

        if let topCard {
            topCard.alpha = 1
            topCard.transform = .identity
            topCard.resetFlip()
            topCard.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }

        layoutCards()
        applyNextCardProgress(0)
    }

    private func applyNextCardProgress(_ progress: CGFloat) {
        guard let nextCard else { return }
        let p = max(0, min(1, progress))

        // Next card “pre-animates in” as top card leaves.
        let scale = 0.97 + 0.03 * p
        let y = 12 * (1 - p)
        nextCard.transform = CGAffineTransform(translationX: 0, y: y).scaledBy(x: scale, y: scale)
        nextCard.alpha = 0.92 + 0.08 * p
        nextCard.setLiftedShadow(progress: 0)
    }

    private func applyLift(isLifted: Bool) {
        guard let topCard else { return }
        topCard.layer.shadowOpacity = isLifted ? liftShadowOpacity : baseShadowOpacity
    }

    // MARK: Flip (up/down)

    private func updateFlip(translation: CGPoint) {
        guard let topCard else { return }

        // Vertical swipe drives flip angle.
        let dy = translation.y
        let delta = (-dy / 220) * .pi
        let angle = max(0, min(.pi, flipStartAngle + delta))

        topCard.setFlipAngleDirect(angle)

        // Keep a subtle position cue.
        topCard.center = CGPoint(x: panStartCenter.x, y: panStartCenter.y + translation.y * 0.08)
        topCard.setLiftedShadow(progress: min(1, abs(delta) / .pi))
    }

    private func finishFlip(translation: CGPoint, velocity: CGPoint) {
        guard let topCard else { return }

        let vy = velocity.y
        let current = topCard.currentFlipAngle

        let shouldFlipForward = (vy < -650) || (translation.y < -120)
        let shouldFlipBack = (vy > 650) || (translation.y > 120)

        let target: CGFloat
        if shouldFlipForward {
            target = .pi
        } else if shouldFlipBack {
            target = 0
        } else {
            target = (abs(current) > (.pi / 2)) ? .pi : 0
        }

        let spring = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: CGVector(dx: 0, dy: -vy / 1200))
        let animator = UIViewPropertyAnimator(duration: 0.62, timingParameters: spring)
        topCard.register(animator)

        animator.addAnimations { [weak self] in
            guard let self else { return }
            topCard.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            topCard.transform = .identity
            topCard.setFlipAngleAnimated(target)
            topCard.setLiftedShadow(progress: 0)
        }

        animator.addCompletion { [weak self] _ in
            self?.applyLift(isLifted: false)
        }

        animator.startAnimation()
    }
}

final class PhysicsFlashcardView: UIView {
    private let container = UIView()
    private let clipped = UIView()
    private let frontFace = UIView()
    private let backFace = UIView()

    private var runningAnimators: [UIViewPropertyAnimator] = []

    private let frontLabel = UILabel()
    private let backLabel = UILabel()

    fileprivate var currentFlipAngle: CGFloat = 0

    init(frontText: String, backText: String) {
        super.init(frame: .zero)

        isOpaque = false

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 10)

        addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        container.addSubview(clipped)
        clipped.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clipped.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            clipped.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clipped.topAnchor.constraint(equalTo: container.topAnchor),
            clipped.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        clipped.layer.cornerRadius = 22
        clipped.layer.cornerCurve = .continuous
        clipped.layer.masksToBounds = true
        clipped.backgroundColor = UIColor.secondarySystemBackground

        // Faces
        clipped.addSubview(frontFace)
        clipped.addSubview(backFace)
        frontFace.frame = clipped.bounds
        backFace.frame = clipped.bounds
        frontFace.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backFace.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        frontFace.backgroundColor = UIColor.secondarySystemBackground
        backFace.backgroundColor = UIColor.tertiarySystemBackground

        frontFace.layer.isDoubleSided = false
        backFace.layer.isDoubleSided = false

        // Content
        frontLabel.text = frontText
        frontLabel.font = .systemFont(ofSize: 46, weight: .semibold)
        frontLabel.textAlignment = .center
        frontLabel.numberOfLines = 2

        backLabel.text = backText
        backLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        backLabel.textAlignment = .left
        backLabel.numberOfLines = 0

        let frontWrap = makeCenteredStack([frontLabel])
        frontFace.addSubview(frontWrap)
        frontWrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            frontWrap.leadingAnchor.constraint(equalTo: frontFace.leadingAnchor, constant: 22),
            frontWrap.trailingAnchor.constraint(equalTo: frontFace.trailingAnchor, constant: -22),
            frontWrap.centerYAnchor.constraint(equalTo: frontFace.centerYAnchor)
        ])

        let backWrap = makeCenteredStack([backLabel])
        backFace.addSubview(backWrap)
        backWrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backWrap.leadingAnchor.constraint(equalTo: backFace.leadingAnchor, constant: 22),
            backWrap.trailingAnchor.constraint(equalTo: backFace.trailingAnchor, constant: -22),
            backWrap.centerYAnchor.constraint(equalTo: backFace.centerYAnchor)
        ])

        // Initial orientation.
        resetFlip()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
    }

    func register(_ animator: UIViewPropertyAnimator) {
        runningAnimators.append(animator)
    }

    func stopRunningAnimations() {
        for a in runningAnimators {
            a.stopAnimation(true)
        }
        runningAnimators.removeAll()
        layer.removeAllAnimations()
        container.layer.removeAllAnimations()
        clipped.layer.removeAllAnimations()
        frontFace.layer.removeAllAnimations()
        backFace.layer.removeAllAnimations()
    }

    func resetFlip() {
        currentFlipAngle = 0
        applyFlip(angle: 0, animated: false)
    }

    func setLiftedShadow(progress: CGFloat) {
        let p = max(0, min(1, progress))
        layer.shadowRadius = 18 + 10 * p
        layer.shadowOffset = CGSize(width: 0, height: 10 + 6 * p)
    }

    func setAffineTransformDirect(_ t: CGAffineTransform) {
        UIView.performWithoutAnimation {
            transform = t
        }
    }

    func setFlipAngleDirect(_ angle: CGFloat) {
        currentFlipAngle = normalizedFlipAngle(angle)
        applyFlip(angle: currentFlipAngle, animated: false)
    }

    func setFlipAngleAnimated(_ angle: CGFloat) {
        currentFlipAngle = normalizedFlipAngle(angle)
        applyFlip(angle: currentFlipAngle, animated: true)
    }

    private func normalizedFlipAngle(_ angle: CGFloat) -> CGFloat {
        // Clamp to [0, π] but allow negative during interactive dragging for feel.
        if angle <= 0 { return 0 }
        if angle >= .pi { return .pi }
        return angle
    }

    private func applyFlip(angle: CGFloat, animated: Bool) {
        let m34: CGFloat = -1 / 500

        func t3d(_ radians: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t.m34 = m34
            return CATransform3DRotate(t, radians, 1, 0, 0)
        }

        // Front goes 0 → π
        // Back goes -π → 0
        let frontAngle = angle
        let backAngle = angle - .pi

        let frontHidden = angle > (.pi / 2)
        let backHidden = angle < (.pi / 2)

        let apply = {
            self.frontFace.isHidden = frontHidden
            self.backFace.isHidden = backHidden
            self.frontFace.layer.transform = t3d(frontAngle)
            self.backFace.layer.transform = t3d(backAngle)
        }

        if animated {
            apply()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
        }
    }

    private func makeCenteredStack(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.alignment = .fill
        s.distribution = .fill
        s.spacing = 12
        return s
    }
}
