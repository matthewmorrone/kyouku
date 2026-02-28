import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WhisperKit)
import WhisperKit
#endif

struct TimedWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

enum WhisperServiceError: LocalizedError {
    case modelLoadFailed(String)
    case audioFormatUnsupported
    case audioConversionFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load Whisper model at path: \(path)"
        case .audioFormatUnsupported:
            return "Audio format is not supported for conversion to 16kHz mono Float32."
        case .audioConversionFailed(let message):
            return "Audio conversion failed: \(message)"
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with error code \(code)."
        }
    }
}

final class WhisperService {
    static let shared = WhisperService()

    private static let sampleRate: Double = 16_000
    private static let ioFrameCapacity: AVAudioFrameCount = 4096

    private init() {}

    func transcribeWords(
        from audioFile: AVAudioFile,
        language: String = "ja",
        canonicalLyrics: String? = nil
    ) async throws -> [TimedWord] {
        try await transcribeWords(from: audioFile.url, language: language, canonicalLyrics: canonicalLyrics)
    }

    func transcribeWords(
        from audioURL: URL,
        language: String = "ja",
        canonicalLyrics: String? = nil
    ) async throws -> [TimedWord] {
#if canImport(WhisperKit)
#if canImport(UIKit)
        let backgroundTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "KyoukuWhisperKitTranscription")
        }
        defer {
            Task { @MainActor in
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
#endif

        return try await Task.detached(priority: .userInitiated) {
            let preparedURL = try await Self.prepareAudioForWhisper(from: audioURL)
            defer { try? FileManager.default.removeItem(at: preparedURL) }

            return try await Self.transcribeWithWhisperKit(
                audioURL: preparedURL,
                language: language,
                canonicalLyrics: canonicalLyrics
            )
        }.value
#else
        _ = audioURL
        _ = language
        _ = canonicalLyrics
        throw WhisperServiceError.modelLoadFailed("WhisperKit module not available in this build")
#endif
    }

    private static func prepareAudioForWhisper(from audioURL: URL) async throws -> URL {
        let samples = try await loadResampledPCM(from: audioURL)
        return try writeTemporaryWav(samples: samples)
    }

    private static func loadResampledPCM(from audioURL: URL) async throws -> [Float] {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            return try convertTo16kMonoFloat32(audioFile: audioFile)
        } catch {
            let primaryError = error
            do {
                return try await loadResampledPCMWithAssetReader(from: audioURL)
            } catch {
                let fallbackError = error
                throw WhisperServiceError.audioConversionFailed(
                    "Primary converter failed: \((primaryError as NSError).localizedDescription). " +
                    "Fallback reader failed: \((fallbackError as NSError).localizedDescription)"
                )
            }
        }
    }

    private static func convertTo16kMonoFloat32(audioFile: AVAudioFile) throws -> [Float] {
        let inputFormat = audioFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperServiceError.audioFormatUnsupported
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WhisperServiceError.audioConversionFailed("Unable to create AVAudioConverter")
        }

        audioFile.framePosition = 0
        var didReachEndOfInput = false
        var converterReadError: Error?
        var outputSamples: [Float] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: ioFrameCapacity) else {
                throw WhisperServiceError.audioConversionFailed("Unable to allocate output buffer")
            }

            var conversionNSError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionNSError) { _, outStatus in
                if didReachEndOfInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: ioFrameCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try audioFile.read(into: inputBuffer, frameCount: ioFrameCapacity)
                } catch {
                    converterReadError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    didReachEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let converterReadError {
                throw WhisperServiceError.audioConversionFailed(converterReadError.localizedDescription)
            }
            if let conversionNSError {
                throw WhisperServiceError.audioConversionFailed(conversionNSError.localizedDescription)
            }

            switch status {
            case .haveData:
                appendSamples(from: outputBuffer, into: &outputSamples)
            case .inputRanDry:
                continue
            case .endOfStream:
                if outputBuffer.frameLength > 0 {
                    appendSamples(from: outputBuffer, into: &outputSamples)
                }
                return outputSamples
            case .error:
                throw WhisperServiceError.audioConversionFailed("AVAudioConverter returned .error")
            @unknown default:
                throw WhisperServiceError.audioConversionFailed("AVAudioConverter returned an unknown status")
            }
        }
    }

    private static func loadResampledPCMWithAssetReader(from audioURL: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw WhisperServiceError.audioConversionFailed("Audio track not found")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw WhisperServiceError.audioConversionFailed("Unable to attach AVAssetReaderTrackOutput")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw WhisperServiceError.audioConversionFailed(
                "AVAssetReader start failed: \((reader.error as NSError?)?.localizedDescription ?? "Unknown error")"
            )
        }

        var samples: [Float] = []
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == noErr, let dataPointer, totalLength > 0 else { continue }

            let floatCount = totalLength / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))
        }

        switch reader.status {
        case .completed:
            return samples
        case .failed:
            throw WhisperServiceError.audioConversionFailed(
                "AVAssetReader failed: \((reader.error as NSError?)?.localizedDescription ?? "Unknown error")"
            )
        case .cancelled:
            throw WhisperServiceError.audioConversionFailed("AVAssetReader cancelled")
        default:
            throw WhisperServiceError.audioConversionFailed("AVAssetReader ended with status \(reader.status.rawValue)")
        }
    }

    private static func appendSamples(from buffer: AVAudioPCMBuffer, into outputSamples: inout [Float]) {
        guard let channelData = buffer.floatChannelData else { return }
        outputSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    private static func writeTemporaryWav(samples: [Float]) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperServiceError.audioFormatUnsupported
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kyouku-whisperkit-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let outFile = try AVAudioFile(
            forWriting: outURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var cursor = 0
        while cursor < samples.count {
            let frameCount = min(Int(ioFrameCapacity), samples.count - cursor)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw WhisperServiceError.audioConversionFailed("Unable to allocate output PCM buffer")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw WhisperServiceError.audioConversionFailed("Missing float channel data for output PCM buffer")
            }

            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress!.advanced(by: cursor), count: frameCount)
            }

            try outFile.write(from: buffer)
            cursor += frameCount
        }

        return outURL
    }

#if canImport(WhisperKit)
    private static func transcribeWithWhisperKit(
        audioURL: URL,
        language: String,
        canonicalLyrics: String?
    ) async throws -> [TimedWord] {
        let whisperKit = try await WhisperKit()
        _ = language
        _ = canonicalLyrics

        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        let words = extractTimedWords(from: results.map { $0 as Any })
        guard words.isEmpty == false else {
            throw WhisperServiceError.transcriptionFailed(-1)
        }
        return words
    }
#endif

    private static func extractTimedWords(from results: [Any]) -> [TimedWord] {
        var words: [TimedWord] = []

        for result in results {
            guard let segments = reflectedArray(named: "segments", in: result) else { continue }

            for segment in segments {
                let segmentStart = reflectedDouble(named: ["start", "startTime", "startTimestamp"], in: segment) ?? 0
                let segmentEnd = reflectedDouble(named: ["end", "endTime", "endTimestamp"], in: segment) ?? segmentStart

                if let wordLike = reflectedArray(named: "words", in: segment) ?? reflectedArray(named: "tokens", in: segment),
                   wordLike.isEmpty == false {
                    for candidate in wordLike {
                        guard let text = reflectedString(named: ["word", "text", "token", "content"], in: candidate) else { continue }
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard cleaned.isEmpty == false else { continue }

                        let start = reflectedDouble(named: ["start", "startTime", "startTimestamp", "t0"], in: candidate) ?? segmentStart
                        let end = reflectedDouble(named: ["end", "endTime", "endTimestamp", "t1"], in: candidate) ?? max(start, segmentEnd)
                        guard end >= start else { continue }

                        words.append(TimedWord(text: cleaned, start: start, end: end))
                    }
                    continue
                }

                guard let segmentText = reflectedString(named: ["text", "content"], in: segment) else { continue }
                let tokens = segmentText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                guard tokens.isEmpty == false else { continue }

                let duration = max(0, segmentEnd - segmentStart)
                let step = duration / Double(tokens.count)
                for (index, token) in tokens.enumerated() {
                    let start = segmentStart + (Double(index) * step)
                    let end = index == tokens.count - 1 ? segmentEnd : (segmentStart + (Double(index + 1) * step))
                    words.append(TimedWord(text: token, start: start, end: max(start, end)))
                }
            }
        }

        return words
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
            if let int32Value = child.value as? Int32 {
                return Double(int32Value)
            }
        }
        return nil
    }

    private static func flattenCollection(_ value: Any) -> [Any] {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .collection else { return [] }
        return mirror.children.map(\.value)
    }
}
