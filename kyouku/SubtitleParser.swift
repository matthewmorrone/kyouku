import Foundation

enum SubtitleParserError: LocalizedError {
    case invalidFormat(String)
    case missingTimestamps
    case textMismatch(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "Invalid subtitle format: \(detail)"
        case .missingTimestamps:
            return "Subtitle file has no timing information"
        case .textMismatch(let detail):
            return "Subtitle text doesn't match lyrics: \(detail)"
        }
    }
}

struct SubtitleEntry {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

enum SubtitleParser {
    /// Parse SRT subtitle file
    static func parseSRT(content: String) throws -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        
        while i < lines.count {
            // Skip empty lines and sequence numbers
            while i < lines.count && (lines[i].trimmingCharacters(in: .whitespaces).isEmpty || lines[i].allSatisfy { $0.isNumber }) {
                i += 1
            }
            
            guard i < lines.count else { break }
            
            // Parse timestamp line: "00:00:10,500 --> 00:00:13,000"
            let timeLine = lines[i].trimmingCharacters(in: .whitespaces)
            if timeLine.contains("-->") {
                let parts = timeLine.components(separatedBy: "-->")
                guard parts.count == 2 else {
                    i += 1
                    continue
                }
                
                let startTime = try parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces))
                let endTime = try parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
                i += 1
                
                // Collect text lines until next empty line or sequence number
                var textLines: [String] = []
                while i < lines.count {
                    let line = lines[i].trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.allSatisfy({ $0.isNumber }) {
                        break
                    }
                    textLines.append(line)
                    i += 1
                }
                
                if !textLines.isEmpty {
                    let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    entries.append(SubtitleEntry(text: text, startSeconds: startTime, endSeconds: endTime))
                }
            } else {
                i += 1
            }
        }
        
        guard !entries.isEmpty else {
            throw SubtitleParserError.missingTimestamps
        }
        
        return entries
    }
    
    /// Parse Whisper JSON transcript format
    static func parseWhisperJSON(content: String) throws -> [SubtitleEntry] {
        guard let data = content.data(using: .utf8) else {
            throw SubtitleParserError.invalidFormat("Not valid UTF-8")
        }
        
        // Try parsing as Whisper output format with segments
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let wordSegments = json["word_segments"] as? [[String: Any]],
               wordSegments.isEmpty == false {
                return try parseWhisperWordSegments(wordSegments)
            }

            if let segments = json["segments"] as? [[String: Any]] {
                return try parseWhisperSegments(segments)
            }
        }
        
        // Try parsing as array of segments directly
        if let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return try parseWhisperSegments(segments)
        }
        
        throw SubtitleParserError.invalidFormat("Expected Whisper JSON with 'segments' array")
    }
    
    private static func parseWhisperSegments(_ segments: [[String: Any]]) throws -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        
        for segment in segments {
            guard let text = segment["text"] as? String,
                  let start = parseNumericValue(segment["start"] ?? segment["start_time"] ?? segment["startSeconds"]),
                  let end = parseNumericValue(segment["end"] ?? segment["end_time"] ?? segment["endSeconds"]) else {
                continue
            }
            
            let cleanText = text.trimmingCharacters(in: .whitespaces)
            if !cleanText.isEmpty {
                entries.append(SubtitleEntry(text: cleanText, startSeconds: start, endSeconds: end))
            }
        }
        
        guard !entries.isEmpty else {
            throw SubtitleParserError.missingTimestamps
        }
        
        return entries
    }

    private static func parseWhisperWordSegments(_ wordSegments: [[String: Any]]) throws -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []

        for segment in wordSegments {
            guard let text = segment["word"] as? String,
                  let start = parseNumericValue(segment["start"] ?? segment["start_time"] ?? segment["startSeconds"]),
                  let end = parseNumericValue(segment["end"] ?? segment["end_time"] ?? segment["endSeconds"]) else {
                continue
            }

            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanText.isEmpty == false {
                entries.append(SubtitleEntry(text: cleanText, startSeconds: start, endSeconds: end))
            }
        }

        guard entries.isEmpty == false else {
            throw SubtitleParserError.missingTimestamps
        }

        return entries
    }

    private static func parseNumericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
    
    /// Parse SRT timestamp format: "00:01:23,456" or "01:23,456" or "01:23.456"
    private static func parseTimestamp(_ timestamp: String) throws -> Double {
        let cleaned = timestamp.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        
        var hours: Double = 0
        var minutes: Double = 0
        var seconds: Double = 0
        
        if parts.count == 3 {
            // HH:MM:SS.mmm
            hours = Double(parts[0]) ?? 0
            minutes = Double(parts[1]) ?? 0
            seconds = Double(parts[2]) ?? 0
        } else if parts.count == 2 {
            // MM:SS.mmm
            minutes = Double(parts[0]) ?? 0
            seconds = Double(parts[1]) ?? 0
        } else if parts.count == 1 {
            // SS.mmm
            seconds = Double(parts[0]) ?? 0
        } else {
            throw SubtitleParserError.invalidFormat("Invalid timestamp: \(timestamp)")
        }
        
        return hours * 3600 + minutes * 60 + seconds
    }
}
