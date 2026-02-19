import Foundation

enum KaraokeDiagnosticsStore {
    private static let queue = DispatchQueue(label: "kyouku.karaoke.diagnostics")
    private static var recentLines: [String] = []
    private static let maxRecentLines = 400

    static func append(_ line: String) {
        queue.async {
            let stamped = "\(timestamp()) \(line)"
            recentLines.append(stamped)
            if recentLines.count > maxRecentLines {
                recentLines.removeFirst(recentLines.count - maxRecentLines)
            }
            appendToFile(stamped)
        }
    }

    static func snapshot(maxLines: Int = 200) -> [String] {
        queue.sync {
            Array(recentLines.suffix(max(1, maxLines)))
        }
    }

    static func persistedTail(maxLines: Int = 300) -> [String] {
        queue.sync {
            guard let url = logFileURL(),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }

            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            return Array(lines.suffix(max(1, maxLines)))
        }
    }

    private static func appendToFile(_ line: String) {
        guard let url = logFileURL() else { return }
        let payload = "\(line)\n"

        if FileManager.default.fileExists(atPath: url.path) == false {
            try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            if let data = payload.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            return
        }
    }

    private static func logFileURL() -> URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("karaoke-diagnostics.log", isDirectory: false)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
