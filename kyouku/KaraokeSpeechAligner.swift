import AVFoundation
import Foundation
import Speech
#if canImport(WhisperKit)
import WhisperKit
#endif

enum KaraokeSpeechAlignerError: LocalizedError {
    case authorizationDenied
    case recognizerUnavailable(String)
    case recognizerNotAvailable
    case onDeviceRecognitionUnavailable
    case audioTooLong(maxAllowedSeconds: Double, actualSeconds: Double)
    case recognitionFailed
    case noRecognitionSegments
    case invalidAudioDuration
    case whisperKitUnavailable
    case allRecognitionBackendsFailed(speechError: String, whisperCppError: String, whisperKitError: String)

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
        case .whisperKitUnavailable:
            return "WhisperKit is not available in this build."
        case .allRecognitionBackendsFailed(let speechError, let whisperCppError, let whisperKitError):
            return "All recognition backends failed. speech=\(speechError); whisperCpp=\(whisperCppError); whisperKit=\(whisperKitError)"
        }
    }
}

enum KaraokeSpeechAligner {
    private enum RecognitionBackend: String {
        case speechOnDevice = "speech_on_device"
        case whisperCpp = "whisper_cpp"
        case whisperKit = "whisperkit"
    }

    private struct RecognitionCandidate {
        let backend: RecognitionBackend
        let recognition: [KaraokeRecognitionSegment]
        let segments: [KaraokeAlignmentSegment]
        let qualityScore: Double
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
        let candidate = try await recognizeAndAlign(
            lyrics: lyrics,
            audioURL: audioURL,
            audioDurationSeconds: audioDuration,
            localeIdentifier: localeIdentifier,
            diagnostics: &diagnostics
        )
        appendDiagnostic(
            "Recognition success backend=\(candidate.backend.rawValue) segments=\(candidate.recognition.count) quality=\(String(format: "%.3f", candidate.qualityScore))",
            to: &diagnostics
        )

        let strategy = strategy(for: candidate.backend)
        let segments = candidate.segments
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

    private static func strategy(for backend: RecognitionBackend) -> KaraokeAlignment.Strategy {
        switch backend {
        case .speechOnDevice:
            return .speechOnDevice
        case .whisperCpp:
            return .whisperCpp
        case .whisperKit:
            return .whisperKit
        }
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

    private static func recognizeAndAlign(
        lyrics: String,
        audioURL: URL,
        audioDurationSeconds: Double,
        localeIdentifier: String,
        diagnostics: inout [String]
    ) async throws -> RecognitionCandidate {
        var candidates: [RecognitionCandidate] = []
        var speechFailureMessage: String?
        var whisperCppFailureMessage: String?
        var whisperKitFailureMessage: String?

        do {
            let segments = try await recognizeSegmentsWithSpeech(
                audioURL: audioURL,
                localeIdentifier: localeIdentifier
            )
            let mappedSegments = KaraokeLineTimingMapper.lineSegments(
                for: lyrics,
                recognition: segments,
                audioDurationSeconds: audioDurationSeconds
            )
            let score = alignmentQualityScore(mappedSegments)
            candidates.append(
                RecognitionCandidate(
                    backend: .speechOnDevice,
                    recognition: segments,
                    segments: mappedSegments,
                    qualityScore: score
                )
            )
            appendDiagnostic("Speech candidate quality=\(String(format: "%.3f", score))", to: &diagnostics)

            if score >= 0.58 {
                appendDiagnostic("Speech candidate accepted without Whisper retry", to: &diagnostics)
                return candidates[0]
            }
            appendDiagnostic("Speech candidate weak; attempting Whisper retry", to: &diagnostics)
        } catch {
            let message = diagnosticDescription(for: error)
            speechFailureMessage = message
            appendDiagnostic("Speech backend failed: \(message)", level: .error, to: &diagnostics)
        }

        do {
            let whisperLanguage = whisperLanguageCode(from: localeIdentifier)
            let timedWords = try await WhisperService.shared.transcribeWords(
                from: audioURL,
                language: whisperLanguage,
                canonicalLyrics: lyrics
            )
            let mappedRecognition = timedWords.compactMap { word -> KaraokeRecognitionSegment? in
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

            guard mappedRecognition.isEmpty == false else {
                throw KaraokeSpeechAlignerError.noRecognitionSegments
            }

            let mappedSegments = KaraokeLineTimingMapper.lineSegments(
                for: lyrics,
                recognition: mappedRecognition,
                audioDurationSeconds: audioDurationSeconds
            )
            let score = alignmentQualityScore(mappedSegments)
            candidates.append(
                RecognitionCandidate(
                    backend: .whisperCpp,
                    recognition: mappedRecognition,
                    segments: mappedSegments,
                    qualityScore: score
                )
            )
            appendDiagnostic("Whisper candidate quality=\(String(format: "%.3f", score))", to: &diagnostics)
        } catch {
            let message = diagnosticDescription(for: error)
            whisperCppFailureMessage = message
            appendDiagnostic("Whisper.cpp backend failed: \(message)", level: .error, to: &diagnostics)
        }

        do {
            let segments = try await recognizeSegmentsWithWhisperKit(
                audioURL: audioURL,
                localeIdentifier: localeIdentifier,
                canonicalLyrics: lyrics
            )

            let mappedSegments = KaraokeLineTimingMapper.lineSegments(
                for: lyrics,
                recognition: segments,
                audioDurationSeconds: audioDurationSeconds
            )
            let score = alignmentQualityScore(mappedSegments)
            candidates.append(
                RecognitionCandidate(
                    backend: .whisperKit,
                    recognition: segments,
                    segments: mappedSegments,
                    qualityScore: score
                )
            )
            appendDiagnostic("WhisperKit candidate quality=\(String(format: "%.3f", score))", to: &diagnostics)
        } catch {
            let message = diagnosticDescription(for: error)
            whisperKitFailureMessage = message
            appendDiagnostic("WhisperKit backend failed: \(message)", level: .error, to: &diagnostics)
        }

        guard let best = candidates.max(by: { lhs, rhs in lhs.qualityScore < rhs.qualityScore }) else {
            throw KaraokeSpeechAlignerError.allRecognitionBackendsFailed(
                speechError: speechFailureMessage ?? "unavailable",
                whisperCppError: whisperCppFailureMessage ?? "unavailable",
                whisperKitError: whisperKitFailureMessage ?? "unavailable"
            )
        }

        appendDiagnostic(
            "Selected backend=\(best.backend.rawValue) quality=\(String(format: "%.3f", best.qualityScore)) among=\(candidates.count) candidates",
            to: &diagnostics
        )
        return best
    }

    private static func recognizeSegmentsWithWhisperKit(
        audioURL: URL,
        localeIdentifier: String,
        canonicalLyrics: String
    ) async throws -> [KaraokeRecognitionSegment] {
#if canImport(WhisperKit)
        let whisperKit = try await WhisperKit()
        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        guard results.isEmpty == false else {
            throw KaraokeSpeechAlignerError.noRecognitionSegments
        }

        var mapped: [KaraokeRecognitionSegment] = []
        let language = whisperLanguageCode(from: localeIdentifier)
        _ = language
        _ = canonicalLyrics

        for result in results {
            if let segmentValues = reflectedArray(named: "segments", in: result) {
                mapped.reserveCapacity(mapped.count + segmentValues.count)
                for segmentValue in segmentValues {
                    guard let text = reflectedString(named: ["text", "content"], in: segmentValue),
                          text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        continue
                    }

                    let start = reflectedDouble(named: ["start", "startTime", "startTimestamp"], in: segmentValue) ?? 0
                    let end = reflectedDouble(named: ["end", "endTime", "endTimestamp"], in: segmentValue) ?? start
                    let confidence = reflectedDouble(named: ["confidence", "avgLogProb", "avgLogprob"], in: segmentValue) ?? 0.7

                    mapped.append(
                        KaraokeRecognitionSegment(
                            text: text,
                            startSeconds: start,
                            endSeconds: max(start, end),
                            confidence: confidence
                        )
                    )
                }
            }
        }

        guard mapped.isEmpty == false else {
            throw KaraokeSpeechAlignerError.noRecognitionSegments
        }

        return mapped
#else
        throw KaraokeSpeechAlignerError.whisperKitUnavailable
#endif
    }

    private static func reflectedArray(named label: String, in value: Any) -> [Any]? {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard child.label == label else { continue }
            return flattenCollection(child.value)
        }
        return nil
    }

    private static func reflectedString(named labels: [String], in value: Any) -> String? {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard let label = child.label, labels.contains(label) else { continue }
            if let stringValue = child.value as? String {
                return stringValue
            }
        }
        return nil
    }

    private static func reflectedDouble(named labels: [String], in value: Any) -> Double? {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            guard let label = child.label, labels.contains(label) else { continue }
            if let doubleValue = child.value as? Double {
                return doubleValue
            }
            if let floatValue = child.value as? Float {
                return Double(floatValue)
            }
            if let intValue = child.value as? Int {
                return Double(intValue)
            }
        }
        return nil
    }

    private static func flattenCollection(_ value: Any) -> [Any] {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .collection else { return [] }
        return mirror.children.map(\.value)
    }

    private static func alignmentQualityScore(_ lineSegments: [KaraokeAlignmentSegment]) -> Double {
        guard lineSegments.isEmpty == false else { return 0 }

        let lineCount = Double(lineSegments.count)
        let averageConfidence = lineSegments.reduce(0.0) { partial, segment in
            partial + segment.confidence
        } / lineCount
        let anchoredLineRatio = Double(
            lineSegments.filter { $0.confidence >= 0.22 }.count
        ) / lineCount
        let tokenCoverageRatio = Double(
            lineSegments.filter { segment in
                guard let tokenSegments = segment.tokenSegments else { return false }
                return tokenSegments.isEmpty == false
            }.count
        ) / lineCount

        return (averageConfidence * 0.65) + (anchoredLineRatio * 0.2) + (tokenCoverageRatio * 0.15)
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
