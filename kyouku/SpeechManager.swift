import AVFoundation
import Combine
import Foundation

/// A single, shared wrapper around `AVSpeechSynthesizer`.
///
/// - UI-agnostic: no SwiftUI/UIKit dependencies.
/// - Playback only (no audio export).
/// - Optional playback state publishing for SwiftUI.
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    struct VoiceOption: Identifiable, Hashable {
        let identifier: String
        let name: String
        let language: String

        var id: String { identifier }
    }

    /// If set, used when `speak(text:language:)` is called with `language == nil`.
    /// If nil, the system voice/language is used.
    var defaultLanguageCode: String?

    /// If true, a new `speak(...)` call will interrupt current speech.
    var interruptsCurrentSpeech: Bool = true

    /// Preferred speech settings (apply to new utterances).
    /// These are user-tunable and persisted to UserDefaults.
    @Published var preferredRate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet {
            let clamped = Self.clampRate(preferredRate)
            if clamped != preferredRate {
                preferredRate = clamped
                return
            }
            UserDefaults.standard.set(preferredRate, forKey: DefaultsKeys.preferredRate)
        }
    }

    @Published var preferredPitch: Float = 1.0 {
        didSet {
            let clamped = Self.clampPitch(preferredPitch)
            if clamped != preferredPitch {
                preferredPitch = clamped
                return
            }
            UserDefaults.standard.set(preferredPitch, forKey: DefaultsKeys.preferredPitch)
        }
    }

    /// If set, overrides language selection and uses this exact voice identifier.
    @Published var preferredVoiceIdentifier: String? = nil {
        didSet {
            if let preferredVoiceIdentifier {
                UserDefaults.standard.set(preferredVoiceIdentifier, forKey: DefaultsKeys.preferredVoiceIdentifier)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.preferredVoiceIdentifier)
            }
        }
    }

    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var activeSessionID: String? = nil
    @Published private(set) var activeText: String? = nil
    @Published private(set) var activeLanguageCode: String? = nil
    @Published private(set) var currentSpokenRange: NSRange? = nil

    private let synthesizer: AVSpeechSynthesizer

    private enum DefaultsKeys {
        static let preferredRate = "SpeechManager.preferredRate"
        static let preferredPitch = "SpeechManager.preferredPitch"
        static let preferredVoiceIdentifier = "SpeechManager.preferredVoiceIdentifier"
    }

    private override init() {
        synthesizer = AVSpeechSynthesizer()
        let defaults = UserDefaults.standard

        let rawRate: Float
        if defaults.object(forKey: DefaultsKeys.preferredRate) != nil {
            rawRate = defaults.float(forKey: DefaultsKeys.preferredRate)
        } else {
            rawRate = AVSpeechUtteranceDefaultSpeechRate
        }

        let rawPitch: Float
        if defaults.object(forKey: DefaultsKeys.preferredPitch) != nil {
            rawPitch = defaults.float(forKey: DefaultsKeys.preferredPitch)
        } else {
            rawPitch = 1.0
        }

        preferredRate = Self.clampRate(rawRate)
        preferredPitch = Self.clampPitch(rawPitch)
        preferredVoiceIdentifier = defaults.string(forKey: DefaultsKeys.preferredVoiceIdentifier)

        super.init()
        synthesizer.delegate = self
    }

    func speak(text: String, language: String? = nil) {
        startSpeaking(sessionID: nil, text: text, language: language)
    }

    /// Toggles play/pause for a long-form speech session (e.g. reading a full note).
    ///
    /// If this session/text is already active, this pauses or resumes.
    /// Otherwise, it stops any current speech and starts this session.
    func togglePlayPause(sessionID: String, text: String, language: String? = nil) {
        let isEffectivelyEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEffectivelyEmpty == false else { return }

        let selectedLanguage = language ?? defaultLanguageCode ?? Self.inferredLanguageCode(for: text)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if self.activeSessionID == sessionID, self.activeText == text {
                if self.synthesizer.isSpeaking {
                    if self.synthesizer.isPaused {
                        _ = self.synthesizer.continueSpeaking()
                    } else {
                        _ = self.synthesizer.pauseSpeaking(at: .word)
                    }
                    return
                }

                // Session matches but speech ended; restart.
                self.startSpeakingOnMain(sessionID: sessionID, text: text, language: selectedLanguage)
                return
            }

            self.startSpeakingOnMain(sessionID: sessionID, text: text, language: selectedLanguage)
        }
    }

    func stop(sessionID: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let sessionID {
                guard self.activeSessionID == sessionID else { return }
            }
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.resetPublishedStateIfNeeded(sessionID: sessionID)
        }
    }

    /// Clears the currently-published spoken range indicator (if this session is active),
    /// without stopping or pausing speech.
    func resetSpeechIndicator(sessionID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.activeSessionID == sessionID else { return }
            self.currentSpokenRange = nil
        }
    }

    // MARK: - Preferences helpers

    func adjustRate(by delta: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preferredRate = Self.clampRate(self.preferredRate + delta)
        }
    }

    func adjustPitch(by delta: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preferredPitch = Self.clampPitch(self.preferredPitch + delta)
        }
    }

    func resetRateAndPitch() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preferredRate = AVSpeechUtteranceDefaultSpeechRate
            self.preferredPitch = 1.0
        }
    }

    func setPreferredVoiceIdentifier(_ identifier: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preferredVoiceIdentifier = identifier
        }
    }

    func availableVoices(language: String? = nil) -> [VoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let filtered = voices.filter { voice in
            guard let language else { return true }
            return voice.language == language
        }

        return filtered
            .map { voice in
                VoiceOption(identifier: voice.identifier, name: voice.name, language: voice.language)
            }
            .sorted { lhs, rhs in
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
    }

    static func formatRate(_ rate: Float) -> String {
        String(format: "%.2f", rate)
    }

    static func formatPitch(_ pitch: Float) -> String {
        String(format: "%.2f", pitch)
    }

    private static func clampRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func clampPitch(_ pitch: Float) -> Float {
        min(max(pitch, 0.5), 2.0)
    }

    // MARK: - Internals

    private func startSpeaking(sessionID: String?, text: String, language: String?) {
        let isEffectivelyEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEffectivelyEmpty == false else { return }

        let selectedLanguage = language ?? defaultLanguageCode ?? Self.inferredLanguageCode(for: text)

        // `AVSpeechSynthesizer` is safest to drive from the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startSpeakingOnMain(sessionID: sessionID, text: text, language: selectedLanguage)
        }
    }

    private func startSpeakingOnMain(sessionID: String?, text: String, language: String?) {
        if interruptsCurrentSpeech, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Keep the utterance string identical to the caller's `text` so delegate ranges
        // can be used directly as UTF-16 ranges for highlighting.
        let utterance = AVSpeechUtterance(string: text)

        // Respect system Spoken Content settings only when the user hasn't explicitly
        // customized speech settings inside the app.
        let hasCustomVoice = (preferredVoiceIdentifier != nil)
        let hasCustomRate = abs(preferredRate - AVSpeechUtteranceDefaultSpeechRate) > 0.000_1
        let hasCustomPitch = abs(preferredPitch - 1.0) > 0.000_1
        utterance.prefersAssistiveTechnologySettings = !(hasCustomVoice || hasCustomRate || hasCustomPitch)

        if let preferredVoiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            utterance.voice = voice
        } else if let language {
            if let voice = AVSpeechSynthesisVoice(language: language) {
                utterance.voice = voice
            }
        }

        utterance.rate = preferredRate
        utterance.pitchMultiplier = preferredPitch

        activeSessionID = sessionID
        activeText = text
        activeLanguageCode = language
        currentSpokenRange = nil
        // `isSpeaking`/`isPaused` are updated by delegate callbacks.

        synthesizer.speak(utterance)
    }

    private func resetPublishedStateIfNeeded(sessionID: String?) {
        if let sessionID {
            guard activeSessionID == sessionID else { return }
        }
        isSpeaking = false
        isPaused = false
        activeSessionID = nil
        activeText = nil
        activeLanguageCode = nil
        currentSpokenRange = nil
    }

    private static func inferredLanguageCode(for text: String) -> String? {
        // Heuristic: if the text contains Japanese kana/kanji, prefer Japanese TTS.
        // This avoids the system default (often English) reading kana as gibberish.
        if text.unicodeScalars.contains(where: { scalar in
            (0x3040...0x309F).contains(scalar.value) || // Hiragana
            (0x30A0...0x30FF).contains(scalar.value) || // Katakana
            (0x4E00...0x9FFF).contains(scalar.value) || // CJK Unified Ideographs (common kanji)
            (0xFF66...0xFF9D).contains(scalar.value)    // Halfwidth katakana
        }) {
            return "ja-JP"
        }
        return nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
            self.isPaused = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPaused = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPaused = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.resetPublishedStateIfNeeded(sessionID: self.activeSessionID)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.resetPublishedStateIfNeeded(sessionID: self.activeSessionID)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard let activeText = self.activeText, activeText == utterance.speechString else { return }
            if self.currentSpokenRange != characterRange {
                self.currentSpokenRange = characterRange
            }
        }
    }
}
