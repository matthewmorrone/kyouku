import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class AudioKaraokeManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioKaraokeManager()

    struct TimedRange: Codable, Hashable {
        let start: TimeInterval
        let end: TimeInterval
        let location: Int
        let length: Int

        var range: NSRange {
            NSRange(location: location, length: length)
        }
    }

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isAligning: Bool = false
    @Published private(set) var activeSessionID: String? = nil
    @Published private(set) var currentSpokenRange: NSRange? = nil
    @Published private(set) var lastErrorMessage: String? = nil

    private var player: AVAudioPlayer? = nil
    private var timer: Timer? = nil

    private var alignedText: String? = nil
    private var timedRanges: [TimedRange] = []

    private override init() {
        super.init()
    }

    func stop(sessionID: String? = nil) {
        if let sessionID {
            guard activeSessionID == sessionID else { return }
        }

        timer?.invalidate()
        timer = nil

        player?.stop()
        player = nil

        isPlaying = false
        isPaused = false
        isAligning = false
        activeSessionID = nil
        currentSpokenRange = nil
        lastErrorMessage = nil
        alignedText = nil
        timedRanges = []
    }

    func togglePlayPause(
        sessionID: String,
        audioURL: URL,
        text: String,
        languageCode: String,
        cacheURL: URL
    ) async {
        // If we are already on this session+text, just pause/resume.
        if activeSessionID == sessionID, alignedText == text, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                isPaused = true
                return
            } else {
                player.play()
                isPlaying = true
                isPaused = false
                startTimer()
                return
            }
        }

        // New session: stop whatever is currently active.
        stop()

        activeSessionID = sessionID
        alignedText = text
        currentSpokenRange = nil
        lastErrorMessage = nil

        do {
            try configureAudioSession()
            let alignment = try await loadOrComputeAlignment(
                audioURL: audioURL,
                text: text,
                languageCode: languageCode,
                cacheURL: cacheURL
            )
            timedRanges = alignment

            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.delegate = self
            player.prepareToPlay()
            self.player = player

            player.play()
            isPlaying = true
            isPaused = false
            startTimer()
        } catch {
            lastErrorMessage = String(describing: error)
            stop(sessionID: sessionID)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop(sessionID: activeSessionID)
    }

    // MARK: - Playback timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        guard let text = alignedText else { return }

        let t = player.currentTime
        let range = rangeForTime(t, in: timedRanges, text: text)
        if currentSpokenRange != range {
            currentSpokenRange = range
        }

        if player.isPlaying == false {
            isPlaying = false
            isPaused = true
        }
    }

    private func rangeForTime(_ t: TimeInterval, in ranges: [TimedRange], text: String) -> NSRange? {
        guard ranges.isEmpty == false else { return nil }

        // Find last segment whose start <= t.
        // This is stable even if there are gaps.
        var candidate: TimedRange? = nil
        for r in ranges {
            if r.start <= t {
                candidate = r
            } else {
                break
            }
        }

        guard let chosen = candidate else { return nil }
        guard t <= chosen.end else { return nil }

        let ns = text as NSString
        let range = chosen.range
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard NSMaxRange(range) <= ns.length else { return nil }
        let snippet = ns.substring(with: range)
        guard snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }

        return range
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true, options: [])
    }

    // MARK: - Alignment

    private func loadOrComputeAlignment(
        audioURL: URL,
        text: String,
        languageCode: String,
        cacheURL: URL
    ) async throws -> [TimedRange] {
        if let cached = try? Data(contentsOf: cacheURL) {
            if let decoded = try? JSONDecoder().decode([TimedRange].self, from: cached), decoded.isEmpty == false {
                return decoded
            }
        }

        isAligning = true
        defer { isAligning = false }

        let status = await requestSpeechAuthorizationIfNeeded()
        guard status == .authorized else {
            throw NSError(domain: "AudioKaraoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission not granted"]) 
        }

        let locale = Locale(identifier: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw NSError(domain: "AudioKaraoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "No speech recognizer for locale \(languageCode)"]) 
        }

        let result = try await transcribeAudio(audioURL: audioURL, recognizer: recognizer)
        let aligned = alignSegmentsToText(result.bestTranscription.segments, text: text)

        // Cache (best effort)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(aligned)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Ignore cache write failures
        }

        return aligned
    }

    private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func transcribeAudio(audioURL: URL, recognizer: SFSpeechRecognizer) async throws -> SFSpeechRecognitionResult {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if didResume { return }

                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    didResume = true
                    continuation.resume(returning: result)
                }
            }

            // If the continuation is cancelled, cancel recognition.
            Task { @MainActor in
                if Task.isCancelled {
                    task.cancel()
                }
            }
        }
    }

    private func alignSegmentsToText(_ segments: [SFTranscriptionSegment], text: String) -> [TimedRange] {
        let ns = text as NSString
        let fullLen = ns.length

        var searchLocation = 0
        var out: [TimedRange] = []

        for seg in segments {
            let token = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.isEmpty == false else { continue }

            let remainingLen = max(0, fullLen - searchLocation)
            let forwardRange = NSRange(location: searchLocation, length: remainingLen)
            var found = ns.range(of: token, options: [], range: forwardRange)

            if found.location == NSNotFound {
                found = ns.range(of: token, options: [])
            }

            guard found.location != NSNotFound, found.length > 0 else { continue }

            out.append(
                TimedRange(
                    start: seg.timestamp,
                    end: seg.timestamp + seg.duration,
                    location: found.location,
                    length: found.length
                )
            )

            searchLocation = min(fullLen, found.location + found.length)
        }

        // Ensure monotonic time ordering (Speech usually provides it, but be defensive).
        out.sort { $0.start < $1.start }
        return out
    }
}
