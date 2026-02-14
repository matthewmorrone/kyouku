import AVFoundation
import Foundation
import Speech

enum KaraokeSpeechAlignerError: LocalizedError {
    case authorizationDenied
    case recognizerUnavailable(String)
    case recognizerNotAvailable
    case onDeviceRecognitionUnavailable
    case audioTooLong(maxAllowedSeconds: Double, actualSeconds: Double)
    case recognitionFailed
    case noRecognitionSegments
    case invalidAudioDuration

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition permission is not granted."
        case .recognizerUnavailable(let localeIdentifier):
            return "No speech recognizer is available for locale \(localeIdentifier)."
        case .recognizerNotAvailable:
            return "Speech recognizer is temporarily unavailable."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is unavailable on this device."
        case .audioTooLong(let maxAllowedSeconds, let actualSeconds):
            let maxMinutes = Int(maxAllowedSeconds / 60.0)
            let actualMinutes = Int(actualSeconds / 60.0)
            let actualRemainderSeconds = Int(actualSeconds.rounded()) % 60
            return "Audio is too long (\(actualMinutes):\(String(format: "%02d", actualRemainderSeconds))). Maximum allowed is \(maxMinutes):00."
        case .recognitionFailed:
            return "Speech recognition did not return a final transcription."
        case .noRecognitionSegments:
            return "Speech recognition returned no timestamped segments."
        case .invalidAudioDuration:
            return "Audio duration could not be determined."
        }
    }
}

enum KaraokeSpeechAligner {
    static let maxAudioDurationSeconds: Double = 8 * 60

    static func align(
        lyrics: String,
        audioURL: URL,
        localeIdentifier: String = "ja-JP"
    ) async throws -> KaraokeAlignment {
        let audioDuration = try await loadAudioDurationSeconds(from: audioURL)
        if audioDuration > maxAudioDurationSeconds {
            throw KaraokeSpeechAlignerError.audioTooLong(
                maxAllowedSeconds: maxAudioDurationSeconds,
                actualSeconds: audioDuration
            )
        }
        var strategy: KaraokeAlignment.Strategy = .speechOnDevice
        let recognition: [KaraokeRecognitionSegment]

        do {
            recognition = try await recognizeSegments(audioURL: audioURL, localeIdentifier: localeIdentifier)
        } catch {
            // Keep the pipeline resilient: if recognition fails, still return line-level timing.
            strategy = .fallbackInterpolation
            recognition = []
        }

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: audioDuration
        )

        return KaraokeAlignment(
            generatedAt: Date(),
            localeIdentifier: localeIdentifier,
            audioDurationSeconds: audioDuration,
            strategy: strategy,
            segments: segments
        )
    }

    private static func recognizeSegments(
        audioURL: URL,
        localeIdentifier: String
    ) async throws -> [KaraokeRecognitionSegment] {
        try await ensureSpeechAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw KaraokeSpeechAlignerError.recognizerUnavailable(localeIdentifier)
        }
        guard recognizer.isAvailable else {
            throw KaraokeSpeechAlignerError.recognizerNotAvailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw KaraokeSpeechAlignerError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var task: SFSpeechRecognitionTask?

            func finish(_ result: Result<[KaraokeRecognitionSegment], Error>) {
                guard didResume == false else { return }
                didResume = true
                continuation.resume(with: result)
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    task = nil
                    finish(.failure(error))
                    return
                }

                guard let result else { return }
                guard result.isFinal else { return }

                let mapped = result.bestTranscription.segments.compactMap { segment -> KaraokeRecognitionSegment? in
                    let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.isEmpty == false else { return nil }

                    return KaraokeRecognitionSegment(
                        text: text,
                        startSeconds: segment.timestamp,
                        durationSeconds: segment.duration,
                        confidence: Double(segment.confidence)
                    )
                }

                task?.cancel()
                task = nil

                guard mapped.isEmpty == false else {
                    finish(.failure(KaraokeSpeechAlignerError.noRecognitionSegments))
                    return
                }

                finish(.success(mapped))
            }
        }
    }

    private static func ensureSpeechAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let newStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus)
                }
            }
            guard newStatus == .authorized else {
                throw KaraokeSpeechAlignerError.authorizationDenied
            }
        case .denied, .restricted:
            throw KaraokeSpeechAlignerError.authorizationDenied
        @unknown default:
            throw KaraokeSpeechAlignerError.authorizationDenied
        }
    }

    private static func loadAudioDurationSeconds(from audioURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw KaraokeSpeechAlignerError.invalidAudioDuration
        }
        return seconds
    }
}
