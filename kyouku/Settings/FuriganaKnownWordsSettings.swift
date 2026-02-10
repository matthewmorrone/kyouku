import Foundation

enum FuriganaKnownWordsMode: String, CaseIterable, Identifiable {
    case off
    case saved
    case learned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .saved: return "Hide for Saved Words"
        case .learned: return "Hide for Learned Words"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Always show furigana."
        case .saved:
            return "Hides furigana when a word is in your saved Words list."
        case .learned:
            return "Hides furigana only after Flashcards performance meets a threshold."
        }
    }
}

enum FuriganaKnownWordsSettings {
    static let modeKey = "readingKnownWordFuriganaMode"
    static let scoreThresholdKey = "readingKnownWordFuriganaScoreThreshold"
    static let minimumReviewsKey = "readingKnownWordFuriganaMinimumReviews"

    static let defaultModeRawValue = FuriganaKnownWordsMode.off.rawValue
    static let defaultScoreThreshold: Double = 0.85

    static let defaultMinimumReviews: Int = 5
}
