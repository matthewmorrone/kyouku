import Foundation
#if canImport(Translate)
import Translate
#endif

enum TranslationFallback {
    static func translate(surface: String, reading: String) async -> String? {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = primary.isEmpty ? secondary : primary
        guard text.isEmpty == false else { return nil }
#if canImport(Translate)
        guard #available(iOS 17.0, *) else { return nil }
        return await TranslationFallbackActor.shared.translate(text: text)
#else
        return nil
#endif
    }
}

#if canImport(Translate)
@available(iOS 17.0, *)
actor TranslationFallbackActor {
    static let shared = TranslationFallbackActor()
    private var session: TranslationSession?

    private func ensureSession() throws -> TranslationSession {
        if let session {
            return session
        }
        let config = TranslationSession.Configuration(source: .japanese, target: .english)
        let session = try TranslationSession(configuration: config)
        self.session = session
        return session
    }

    func translate(text: String) async -> String? {
        do {
            let session = try ensureSession()
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            return nil
        }
    }
}
#endif
