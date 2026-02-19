import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import whisper

struct TimedWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

enum WhisperServiceError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case audioFormatUnsupported
    case audioConversionFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelName):
            return "Whisper model not found in bundle: \(modelName)"
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

    private let modelFileName = "ggml-base"
    private let modelFileExtension = "bin"

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
        let modelPath = try resolveModelPath()

#if canImport(UIKit)
        let backgroundTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "KaraokeWhisperTranscription")
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
            let samples = try Self.loadResampledPCM(from: audioURL)
            return try Self.transcribe(
                samples: samples,
                modelPath: modelPath,
                language: language,
                canonicalLyrics: canonicalLyrics
            )
        }.value
    }

    private func resolveModelPath() throws -> String {
        guard let modelPath = Bundle.main.path(forResource: modelFileName, ofType: modelFileExtension) else {
            throw WhisperServiceError.modelNotFound("\(modelFileName).\(modelFileExtension)")
        }

        return modelPath
    }

    private static func loadResampledPCM(from audioURL: URL) throws -> [Float] {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            return try convertTo16kMonoFloat32(audioFile: audioFile)
        } catch {
            let primaryError = error
            do {
                return try loadResampledPCMWithAssetReader(from: audioURL)
            } catch {
                let fallbackError = error
                let firstMessage = (primaryError as NSError).localizedDescription
                let secondMessage = (fallbackError as NSError).localizedDescription
                throw WhisperServiceError.audioConversionFailed(
                    "Primary converter failed: \(firstMessage). Fallback reader failed: \(secondMessage)"
                )
            }
        }
    }

    private static func convertTo16kMonoFloat32(audioFile: AVAudioFile) throws -> [Float] {
        let inputFormat = audioFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WHISPER_SAMPLE_RATE),
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperServiceError.audioFormatUnsupported
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WhisperServiceError.audioConversionFailed("Unable to create AVAudioConverter")
        }

        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity: AVAudioFrameCount = 4096

        audioFile.framePosition = 0

        var didReachEndOfInput = false
        var converterReadError: Error?
        var outputSamples: [Float] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                throw WhisperServiceError.audioConversionFailed("Unable to allocate output buffer")
            }

            var conversionNSError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionNSError) { _, outStatus in
                if didReachEndOfInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try audioFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
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

    private static func loadResampledPCMWithAssetReader(from audioURL: URL) throws -> [Float] {
        let asset = AVURLAsset(url: audioURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw WhisperServiceError.audioConversionFailed("Audio track not found")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(WHISPER_SAMPLE_RATE),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw WhisperServiceError.audioConversionFailed("Unable to attach AVAssetReaderTrackOutput")
        }
        reader.add(output)

        guard reader.startReading() else {
            let message = (reader.error as NSError?)?.localizedDescription ?? "Unknown AVAssetReader start error"
            throw WhisperServiceError.audioConversionFailed("AVAssetReader start failed: \(message)")
        }

        var samples: [Float] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let blockStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard blockStatus == noErr, let dataPointer, totalLength > 0 else {
                continue
            }

            let floatCount = totalLength / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))
        }

        switch reader.status {
        case .completed:
            return samples
        case .failed:
            let message = (reader.error as NSError?)?.localizedDescription ?? "Unknown AVAssetReader failure"
            throw WhisperServiceError.audioConversionFailed("AVAssetReader failed: \(message)")
        case .cancelled:
            throw WhisperServiceError.audioConversionFailed("AVAssetReader cancelled")
        default:
            throw WhisperServiceError.audioConversionFailed("AVAssetReader ended with status \(reader.status.rawValue)")
        }
    }

    private static func appendSamples(from buffer: AVAudioPCMBuffer, into outputSamples: inout [Float]) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        outputSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    private static func transcribe(
        samples: [Float],
        modelPath: String,
        language: String,
        canonicalLyrics: String?
    ) throws -> [TimedWord] {
        guard samples.isEmpty == false else {
            return []
        }

        let contextParameters = whisper_context_default_params()
        guard let context = whisper_init_from_file_with_params(modelPath, contextParameters) else {
            throw WhisperServiceError.modelLoadFailed(modelPath)
        }

        defer { whisper_free(context) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.no_timestamps = false
        params.token_timestamps = true
        params.split_on_word = true
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        let sampleRate = Int(WHISPER_SAMPLE_RATE)
        let chunkDurationSeconds = 10
        let chunkSampleCount = max(sampleRate, sampleRate * chunkDurationSeconds)

        if samples.count <= chunkSampleCount {
            let transcriptionStatus = withOptionalCString(language) { languageCString in
                withOptionalCString(canonicalLyrics) { promptCString in
                    var configuredParams = params
                    configuredParams.language = languageCString
                    configuredParams.initial_prompt = promptCString

                    return samples.withUnsafeBufferPointer { bufferPointer -> Int32 in
                        guard let baseAddress = bufferPointer.baseAddress else {
                            return -1
                        }
                        return whisper_full(context, configuredParams, baseAddress, Int32(bufferPointer.count))
                    }
                }
            }

            guard transcriptionStatus == 0 else {
                throw WhisperServiceError.transcriptionFailed(transcriptionStatus)
            }
            return extractTimedWords(from: context)
        }

        var words: [TimedWord] = []
        words.reserveCapacity(max(32, samples.count / (sampleRate * 2)))
        let totalChunks = Int(ceil(Double(samples.count) / Double(chunkSampleCount)))

        var chunkStart = 0
        var chunkIndex = 0
        while chunkStart < samples.count {
            try Task.checkCancellation()
            chunkIndex += 1
            whisperLog("Transcribing chunk \(chunkIndex)/\(totalChunks)")

            let chunkEnd = min(samples.count, chunkStart + chunkSampleCount)
            let chunkSamples = Array(samples[chunkStart..<chunkEnd])
            let chunkStartTime = Date()

            let chunkStatus = withOptionalCString(language) { languageCString in
                let promptForChunk = chunkIndex == 1 ? canonicalLyrics : nil
                return withOptionalCString(promptForChunk) { promptCString in
                    var configuredParams = params
                    configuredParams.language = languageCString
                    configuredParams.initial_prompt = promptCString

                    return chunkSamples.withUnsafeBufferPointer { bufferPointer -> Int32 in
                        guard let baseAddress = bufferPointer.baseAddress else {
                            return -1
                        }
                        return whisper_full(context, configuredParams, baseAddress, Int32(bufferPointer.count))
                    }
                }
            }

            guard chunkStatus == 0 else {
                throw WhisperServiceError.transcriptionFailed(chunkStatus)
            }

            let chunkElapsed = Date().timeIntervalSince(chunkStartTime)
            whisperLog("Chunk \(chunkIndex)/\(totalChunks) finished in \(String(format: "%.2f", chunkElapsed))s")

            let offsetSeconds = Double(chunkStart) / Double(sampleRate)
            let chunkWords = extractTimedWords(from: context, timeOffset: offsetSeconds)
            words.append(contentsOf: chunkWords)

            if chunkWords.isEmpty == false {
                let preview = chunkWords.suffix(8).map { $0.text }.joined()
                whisperLog("Chunk \(chunkIndex)/\(totalChunks) words=\(chunkWords.count) preview=\(preview)")
            }

            chunkStart = chunkEnd
        }

        whisperLog("Chunk transcription complete chunks=\(totalChunks) words=\(words.count)")

        return words
    }

    private static func whisperLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        CustomLogger.shared.raw("[Karaoke][Whisper] \(timestamp) \(message)")
    }

    private static func extractTimedWords(from context: OpaquePointer?, timeOffset: Double = 0) -> [TimedWord] {
        guard let context else { return [] }

        let segmentCount = whisper_full_n_segments(context)
        guard segmentCount > 0 else { return [] }

        var words: [TimedWord] = []
        words.reserveCapacity(Int(segmentCount) * 4)

        for segmentIndex in 0..<segmentCount {
            let tokenCount = whisper_full_n_tokens(context, segmentIndex)
            guard tokenCount > 0 else { continue }

            for tokenIndex in 0..<tokenCount {
                let tokenData = whisper_full_get_token_data(context, segmentIndex, tokenIndex)
                guard tokenData.t0 >= 0, tokenData.t1 >= tokenData.t0 else { continue }

                guard let tokenCString = whisper_full_get_token_text(context, segmentIndex, tokenIndex) else {
                    continue
                }

                let rawToken = String(cString: tokenCString)
                let cleanedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleanedToken.isEmpty == false else { continue }
                guard isWhisperSpecialToken(cleanedToken) == false else { continue }

                let start = (Double(tokenData.t0) * 0.01) + timeOffset
                let end = (Double(tokenData.t1) * 0.01) + timeOffset

                words.append(TimedWord(text: cleanedToken, start: start, end: end))
            }
        }

        return words
    }

    private static func isWhisperSpecialToken(_ token: String) -> Bool {
        if token.hasPrefix("<|") {
            return true
        }

        if token.hasPrefix("[_"), token.hasSuffix("_]") {
            return true
        }

        return false
    }

    private static func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else {
            return body(nil)
        }

        return value.withCString { pointer in
            body(pointer)
        }
    }
}
