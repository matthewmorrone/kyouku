import Foundation

/// A tiny helper that can be called very early (e.g., from the App struct's init)
/// to ensure the JMdict-backed Trie is constructed and cached before any UI renders.
/// If you don't have a central App entry point available, calling `ensureReady()`
/// from the first screen's onAppear (as we do in PasteView) will still make startup
/// behavior consistent for the rest of the session.
enum TrieBootstrapper {
    private static var didStart = false

    static func ensureReady() {
        guard !didStart else { return }
        didStart = true
        Task {
            let trie = await TrieProvider.shared.getTrie() ?? CustomTrieProvider.makeTrie()
            await MainActor.run {
                TrieCache.shared = trie
            }
        }
    }
}
