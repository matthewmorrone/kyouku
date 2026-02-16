import Foundation

struct UTF16TextRange: Codable, Hashable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    init(_ range: NSRange) {
        let safeLocation = range.location == NSNotFound ? 0 : range.location
        self.init(location: safeLocation, length: range.length)
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

struct KaraokeAlignmentSegment: Codable, Hashable {
    var textRange: UTF16TextRange
    var startSeconds: Double
    var endSeconds: Double
    var confidence: Double

    init(textRange: NSRange, startSeconds: Double, endSeconds: Double, confidence: Double) {
        self.textRange = UTF16TextRange(textRange)
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(self.startSeconds, endSeconds)
        self.confidence = min(max(confidence, 0), 1)
    }
}

struct KaraokeAlignment: Codable, Hashable {
    enum Strategy: String, Codable, Hashable {
        case speechOnDevice = "speech_on_device"
        case fallbackInterpolation = "fallback_interpolation"
    }

    var generatedAt: Date
    var localeIdentifier: String
    var audioDurationSeconds: Double
    var strategy: Strategy
    var segments: [KaraokeAlignmentSegment]
}
