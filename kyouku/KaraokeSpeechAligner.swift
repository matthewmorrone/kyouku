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
    case allRecognitionBackendsFailed(speechError: String, whisperError: String)

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
        case .allRecognitionBackendsFailed(let speechError, let whisperError):
            return "All recognition backends failed. speech=\(speechError); whisper=\(whisperError)"
        }
    }
}

enum KaraokeSpeechAligner {
    private enum RecognitionBackend: String {
        case speechOnDevice = "speech_on_device"
        case whisperCpp = "whisper_cpp"
    }

    static let maxAudioDurationSeconds: Double = 8 * 60

    static func align(
        lyrics: String,
        audioURL: URL,
        localeIdentifier: String = "ja-JP"
    ) async throws -> KaraokeAlignment {
        var diagnostics: [String] = []
        appendDiagnostic("Start align locale=\(localeIdentifier) url=\(audioURL.lastPathComponent)", to: &diagnostics)

        let audioDuration = try await loadAudioDurationSeconds(from: audioURL)
        appendDiagnostic("Audio duration=\(String(format: "%.2f", audioDuration))s", to: &diagnostics)

        if audioDuration > maxAudioDurationSeconds {
            appendDiagnostic(
                "Reject audio: too long max=\(Int(maxAudioDurationSeconds))s actual=\(String(format: "%.2f", audioDuration))s",
                level: .error,
                to: &diagnostics
            )
            throw KaraokeSpeechAlignerError.audioTooLong(
                maxAllowedSeconds: maxAudioDurationSeconds,
                actualSeconds: audioDuration
            )
        }
        var strategy: KaraokeAlignment.Strategy = .speechOnDevice
        let recognition: [KaraokeRecognitionSegment]

        do {
            let recognitionResult = try await recognizeSegments(
                lyrics: lyrics,
                audioURL: audioURL,
                localeIdentifier: localeIdentifier
            )
            recognition = recognitionResult.segments
            appendDiagnostic(
                "Recognition success backend=\(recognitionResult.backend.rawValue) segments=\(recognition.count)",
                to: &diagnostics
            )
        } catch {
            // Keep the pipeline resilient: if recognition fails, still return line-level timing.
            strategy = .fallbackInterpolation
            recognition = []
            appendDiagnostic(
                "Recognition failed: \(diagnosticDescription(for: error))",
                level: .error,
                to: &diagnostics
            )
        }

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: audioDuration
        )
        appendDiagnostic(
            "Line mapping complete strategy=\(strategy.rawValue) lineSegments=\(segments.count)",
            to: &diagnostics
        )

        return KaraokeAlignment(
            generatedAt: Date(),
            localeIdentifier: localeIdentifier,
            audioDurationSeconds: audioDuration,
            strategy: strategy,
            version: KaraokeAlignment.currentVersion,
            granularities: [.line, .phrase, .token],
            segments: segments,
            diagnostics: diagnostics
        )
    }

    private static func diagnosticDescription(for error: Error) -> String {
        if let alignerError = error as? KaraokeSpeechAlignerError {
            return "\(alignerError) (\(alignerError.localizedDescription))"
        }

        let nsError = error as NSError
        return "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
    }

    private static func appendDiagnostic(
        _ message: String,
        level: CustomLogger.Level = .info,
        to diagnostics: inout [String]
    ) {
        diagnostics.append(message)
        CustomLogger.shared.pipeline(context: "Karaoke", stage: "Align", message, level: level)
        CustomLogger.shared.raw("[Karaoke][Align] \(message)")
        KaraokeDiagnosticsStore.append("[Karaoke][Align] \(message)")
    }

    private static func recognizeSegments(
        lyrics: String,
        audioURL: URL,
        localeIdentifier: String
    ) async throws -> (segments: [KaraokeRecognitionSegment], backend: RecognitionBackend) {
        do {
            let segments = try await recognizeSegmentsWithSpeech(
                audioURL: audioURL,
                localeIdentifier: localeIdentifier
            )
            return (segments: segments, backend: .speechOnDevice)
        } catch {
            let speechErrorMessage = diagnosticDescription(for: error)
            let whisperLanguage = whisperLanguageCode(from: localeIdentifier)
            let timedWords: [TimedWord]
            do {
                timedWords = try await WhisperService.shared.transcribeWords(
                    from: audioURL,
                    language: whisperLanguage,
                    canonicalLyrics: lyrics
                )
            } catch {
                let whisperErrorMessage = diagnosticDescription(for: error)
                throw KaraokeSpeechAlignerError.allRecognitionBackendsFailed(
                    speechError: speechErrorMessage,
                    whisperError: whisperErrorMessage
                )
            }

            let mapped = timedWords.compactMap { word -> KaraokeRecognitionSegment? in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { return nil }
                guard word.end > word.start else { return nil }

                return KaraokeRecognitionSegment(
                    text: text,
                    startSeconds: word.start,
                    endSeconds: word.end,
                    confidence: 0.7
                )
            }

            guard mapped.isEmpty == false else {
                throw KaraokeSpeechAlignerError.noRecognitionSegments
            }

            return (segments: mapped, backend: .whisperCpp)
        }
    }

    private static func whisperLanguageCode(from localeIdentifier: String) -> String {
        let locale = Locale(identifier: localeIdentifier)
        if #available(iOS 16.0, *) {
            if let languageCode = locale.language.languageCode?.identifier,
               languageCode.isEmpty == false {
                return languageCode
            }
        }

        if let languageCode = localeIdentifier.split(separator: "-").first,
           languageCode.isEmpty == false {
            return String(languageCode).lowercased()
        }

        return "ja"
    }

    private static func recognizeSegmentsWithSpeech(
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
