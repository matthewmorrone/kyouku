import Foundation

enum KaraokeAlignmentGranularity: String, Codable, Hashable {
    case line
    case phrase
    case token
}

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
    var phraseSegments: [KaraokeAlignmentChildSegment]?
    var tokenSegments: [KaraokeAlignmentChildSegment]?

    init(
        textRange: NSRange,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double,
        phraseSegments: [KaraokeAlignmentChildSegment]? = nil,
        tokenSegments: [KaraokeAlignmentChildSegment]? = nil
    ) {
        self.textRange = UTF16TextRange(textRange)
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(self.startSeconds, endSeconds)
        self.confidence = min(max(confidence, 0), 1)
        self.phraseSegments = phraseSegments
        self.tokenSegments = tokenSegments
    }
}

struct KaraokeAlignmentChildSegment: Codable, Hashable {
    var granularity: KaraokeAlignmentGranularity
    var textRange: UTF16TextRange
    var startSeconds: Double
    var endSeconds: Double
    var confidence: Double

    init(
        granularity: KaraokeAlignmentGranularity,
        textRange: NSRange,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double
    ) {
        self.granularity = granularity
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

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case localeIdentifier
        case audioDurationSeconds
        case strategy
        case version
        case granularities
        case segments
        case diagnostics
    }

    static let currentVersion = 3

    var generatedAt: Date
    var localeIdentifier: String
    var audioDurationSeconds: Double
    var strategy: Strategy
    var version: Int
    var granularities: [KaraokeAlignmentGranularity]
    var segments: [KaraokeAlignmentSegment]
    var diagnostics: [String]?

    init(
        generatedAt: Date,
        localeIdentifier: String,
        audioDurationSeconds: Double,
        strategy: Strategy,
        version: Int = KaraokeAlignment.currentVersion,
        granularities: [KaraokeAlignmentGranularity] = [.line],
        segments: [KaraokeAlignmentSegment],
        diagnostics: [String]? = nil
    ) {
        self.generatedAt = generatedAt
        self.localeIdentifier = localeIdentifier
        self.audioDurationSeconds = audioDurationSeconds
        self.strategy = strategy
        self.version = max(1, version)
        self.granularities = granularities.isEmpty ? [.line] : granularities
        self.segments = segments
        self.diagnostics = diagnostics
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        localeIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        audioDurationSeconds = try container.decode(Double.self, forKey: .audioDurationSeconds)
        strategy = try container.decode(Strategy.self, forKey: .strategy)
        version = max(1, try container.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        granularities = try container.decodeIfPresent([KaraokeAlignmentGranularity].self, forKey: .granularities) ?? [.line]
        if granularities.isEmpty {
            granularities = [.line]
        }
        segments = try container.decode([KaraokeAlignmentSegment].self, forKey: .segments)
        diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics)
    }
}
