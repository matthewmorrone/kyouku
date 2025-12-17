import Foundation

struct PasteBufferStore {
    private static let fileName = "pastebuffer.txt"

    private static func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func fileURL() -> URL? {
        documentsURL()?.appendingPathComponent(fileName)
    }

    static func load() -> String {
        guard let url = fileURL(), FileManager.default.fileExists(atPath: url.path) else {
            return ""
        }
        do {
            let data = try Data(contentsOf: url)
            // Store as UTF-8 plain text
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    static func save(_ text: String) {
        guard let url = fileURL() else { return }
        do {
            let data = text.data(using: .utf8) ?? Data()
            try data.write(to: url, options: .atomic)
        } catch {
            // Swallow errors for now; this is best-effort persistence
            #if DEBUG
            print("Failed to save paste buffer:", error)
            #endif
        }
    }
}
