import Foundation

enum PasteRenderTimingTrace {
    private static let lock = NSLock()
    private static var activeTraceID: Int = 0
    private static var startedAt: CFAbsoluteTime = 0
    private static var activeNoteID: String = "-"
    private static var active: Bool = false

    static func begin(noteID: UUID?, textLength: Int, reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        activeTraceID &+= 1
        let traceID = activeTraceID
        startedAt = now
        activeNoteID = noteID?.uuidString ?? "-"
        active = true
        lock.unlock()

        // CustomLogger.shared.pipeline(
        //     context: "PasteTiming",
        //     stage: "BEGIN",
        //     "trace=\(traceID) note=\(activeNoteID) textLen=\(textLength) reason=\(reason)"
        // )
    }

    static func checkpoint(_ stage: String, _ details: String = "") {
        // let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        // let traceID = activeTraceID
        // let noteID = activeNoteID
        // let elapsedMS = (now - startedAt) * 1000
        lock.unlock()

        // let elapsed = String(format: "%.1f", elapsedMS)
        if details.isEmpty {
            // CustomLogger.shared.pipeline(context: "PasteTiming", stage: stage, "trace=\(traceID) note=\(noteID) +\(elapsed)ms")
        } else {
            // CustomLogger.shared.pipeline(context: "PasteTiming", stage: stage,"trace=\(traceID) note=\(noteID) +\(elapsed)ms \(details)")
        }
    }

    static func end(_ details: String = "") {
        checkpoint("END", details)
        lock.lock()
        active = false
        lock.unlock()
    }
}
