import SwiftUI
import Foundation

/// Visualizes the "conceptual shape" of a note by placing one node per sentence.
///
/// - Layout is computed once per open (static).
/// - Distances are derived from cosine similarity of sentence embeddings.
/// - No clustering/edges; distance-only.
struct SemanticConstellationView: View {
    let sentenceRanges: [NSRange]
    let sentenceVectors: [[Float]?]
    let selectedSentenceIndex: Int?
    let onSelectSentence: (_ sentenceRange: NSRange, _ sentenceIndex: Int) -> Void

    @State private var unitPositions: [CGPoint] = []
    @State private var lastLayoutSignature: Int = 0
    @State private var layoutTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let positions = resolvedPositions(count: sentenceRanges.count)

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemBackground))

                // Nodes
                ForEach(Array(sentenceRanges.indices), id: \.self) { i in
                    let pos = mapToView(positions[i], in: size)
                    let isSelected = (i == selectedSentenceIndex)
                    let hasEmbedding = (i < sentenceVectors.count) && (sentenceVectors[i] != nil)

                    Circle()
                        .fill(nodeFillColor(hasEmbedding: hasEmbedding, isSelected: isSelected))
                        .overlay(
                            Circle().stroke(nodeStrokeColor(isSelected: isSelected), lineWidth: isSelected ? 2 : 1)
                        )
                        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        .position(pos)
                        .contentShape(Rectangle().inset(by: -12))
                        .onTapGesture {
                            guard sentenceRanges.indices.contains(i) else { return }
                            onSelectSentence(sentenceRanges[i], i)
                        }
                        .accessibilityLabel("Sentence \(i + 1)")
                }

                // Legend
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(nodeFillColor(hasEmbedding: true, isSelected: false)).frame(width: 10, height: 10)
                        Text("Embedded").font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(nodeFillColor(hasEmbedding: false, isSelected: false)).frame(width: 10, height: 10)
                        Text("No embedding").font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(nodeFillColor(hasEmbedding: true, isSelected: true)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(nodeStrokeColor(isSelected: true), lineWidth: 2))
                        Text("Current sentence").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear {
                computeLayoutIfNeeded(count: sentenceRanges.count)
            }
            .onChange(of: layoutSignature()) { _, _ in
                computeLayoutIfNeeded(count: sentenceRanges.count)
            }
        }
    }

    private func nodeFillColor(hasEmbedding: Bool, isSelected: Bool) -> Color {
        if isSelected {
            return Color(UIColor.systemOrange).opacity(0.9)
        }
        if hasEmbedding {
            return Color(UIColor.systemBlue).opacity(0.85)
        }
        return Color(UIColor.systemGray3).opacity(0.8)
    }

    private func nodeStrokeColor(isSelected: Bool) -> Color {
        isSelected ? Color(UIColor.systemYellow) : Color(UIColor.black).opacity(0.15)
    }

    private func resolvedPositions(count: Int) -> [CGPoint] {
        if unitPositions.count == count {
            return unitPositions
        }
        // Fallback: ring layout until the computed layout arrives.
        guard count > 0 else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(max(1, count))
            let angle = t * 2 * .pi
            out.append(CGPoint(x: cos(angle) * 0.85, y: sin(angle) * 0.85))
        }
        return out
    }

    private func mapToView(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 24
        let w = max(1, size.width - margin * 2)
        let h = max(1, size.height - margin * 2)
        let x = margin + (p.x + 1) * 0.5 * w
        let y = margin + (p.y + 1) * 0.5 * h
        return CGPoint(x: x, y: y)
    }

    private func layoutSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(sentenceRanges.count)
        hasher.combine(sentenceVectors.count)
        if sentenceVectors.isEmpty == false {
            hasher.combine(sentenceVectors[0]?.count ?? 0)
        }
        let nonNil = sentenceVectors.reduce(0) { acc, v in acc + (v == nil ? 0 : 1) }
        hasher.combine(nonNil)
        return hasher.finalize()
    }

    private func computeLayoutIfNeeded(count: Int) {
        let sig = layoutSignature()
        guard sig != lastLayoutSignature else { return }
        lastLayoutSignature = sig

        layoutTask?.cancel()
        guard count > 0 else {
            unitPositions = []
            return
        }

        let vectors = sentenceVectors
        layoutTask = Task(priority: .utility) {
            let positions = SemanticConstellationLayout.computeUnitPositions(vectors: vectors)
            await MainActor.run {
                guard Task.isCancelled == false else { return }
                if positions.count == count {
                    unitPositions = positions
                } else {
                    unitPositions = Array(positions.prefix(count))
                }
            }
        }
    }
}

enum SemanticConstellationLayout {
    static func computeUnitPositions(vectors: [[Float]?]) -> [CGPoint] {
        let n = vectors.count
        guard n > 0 else { return [] }
        if n == 1 {
            return [CGPoint(x: 0, y: 0)]
        }

        // Precompute desired distances.
        // For normalized vectors, cosine similarity is the dot product.
        var desired = Array(repeating: Array(repeating: CGFloat(1), count: n), count: n)
        for i in 0..<n {
            desired[i][i] = 0
        }

        for i in 0..<n {
            guard let a = vectors[i] else { continue }
            for j in (i + 1)..<n {
                guard let b = vectors[j] else {
                    desired[i][j] = 1.65
                    desired[j][i] = 1.65
                    continue
                }
                let sim = EmbeddingMath.cosineSimilarity(a: a, b: b)
                // Map similarity [-1, 1] to a distance [0.15, 1.85].
                let t = max(-1, min(1, sim))
                let d = CGFloat(1.0 - ((t + 1) * 0.5)) // 1 -> 0, -1 -> 1
                let scaled = max(0.15, min(1.85, 0.15 + d * 1.7))
                desired[i][j] = scaled
                desired[j][i] = scaled
            }
        }

        // Deterministic init on a slightly jittered circle.
        var rng = SeededRNG(seed: UInt64(n) &* 1469598103934665603)
        var pos: [CGPoint] = []
        pos.reserveCapacity(n)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n)
            let angle = t * 2 * .pi
            let jitter = CGFloat(rng.nextUnitDouble()) * 0.06 - 0.03
            let r: CGFloat = 0.75 + jitter
            pos.append(CGPoint(x: cos(angle) * r, y: sin(angle) * r))
        }

        // Simple force relaxation.
        // Static, approximate layout: a few iterations is enough.
        let steps = min(160, max(60, n * 3))
        let springK: CGFloat = 0.04
        let repulseK: CGFloat = 0.0025
        let centerK: CGFloat = 0.02
        let damping: CGFloat = 0.82

        var vel = Array(repeating: CGPoint(x: 0, y: 0), count: n)

        for _ in 0..<steps {
            var force = Array(repeating: CGPoint(x: 0, y: 0), count: n)

            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = pos[j].x - pos[i].x
                    let dy = pos[j].y - pos[i].y
                    let dist2 = max(0.0004, dx * dx + dy * dy)
                    let dist = dist2.squareRoot()

                    // Repulsion.
                    let rep = repulseK / dist2

                    // Spring toward desired distance.
                    let target = desired[i][j]
                    let spring = springK * (dist - target)

                    let mag = rep + spring
                    let fx = (dx / dist) * mag
                    let fy = (dy / dist) * mag

                    force[i].x += fx
                    force[i].y += fy
                    force[j].x -= fx
                    force[j].y -= fy
                }
            }

            for i in 0..<n {
                // Centering.
                force[i].x += (-pos[i].x) * centerK
                force[i].y += (-pos[i].y) * centerK

                vel[i].x = (vel[i].x + force[i].x) * damping
                vel[i].y = (vel[i].y + force[i].y) * damping

                pos[i].x += vel[i].x
                pos[i].y += vel[i].y
            }
        }

        // Normalize to fit in unit square (-1..1), preserving aspect.
        let minX = pos.map { $0.x }.min() ?? 0
        let maxX = pos.map { $0.x }.max() ?? 0
        let minY = pos.map { $0.y }.min() ?? 0
        let maxY = pos.map { $0.y }.max() ?? 0
        let spanX = max(0.001, maxX - minX)
        let spanY = max(0.001, maxY - minY)
        let span = max(spanX, spanY)

        // Center around 0.
        let midX = (minX + maxX) * 0.5
        let midY = (minY + maxY) * 0.5

        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for p in pos {
            let x = (p.x - midX) / (span * 0.5)
            let y = (p.y - midY) / (span * 0.5)
            out.append(CGPoint(x: max(-1, min(1, x)), y: max(-1, min(1, y))))
        }
        return out
    }

    private struct SeededRNG {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            // LCG
            state = state &* 6364136223846793005 &+ 1
            return state
        }

        mutating func nextUnitDouble() -> Double {
            let x = next() >> 11
            return Double(x) / Double(1 << 53)
        }
    }
}

struct SemanticConstellationSheet: View {
    let sentenceRanges: [NSRange]
    let sentenceVectors: [[Float]?]
    let selectedSentenceIndex: Int?
    let onSelectSentence: (_ sentenceRange: NSRange, _ sentenceIndex: Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if sentenceRanges.isEmpty {
                    ContentUnavailableView(
                        "No sentences",
                        systemImage: "circle.dotted",
                        description: Text("Add text to see a constellation.")
                    )
                } else {
                    SemanticConstellationView(
                        sentenceRanges: sentenceRanges,
                        sentenceVectors: sentenceVectors,
                        selectedSentenceIndex: selectedSentenceIndex,
                        onSelectSentence: onSelectSentence
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Constellation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
