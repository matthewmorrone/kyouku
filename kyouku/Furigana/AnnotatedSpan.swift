import Foundation

struct AnnotatedSpan: Equatable, Hashable {
    let span: TextSpan
    let readingKana: String?
    let lemmaCandidates: [String]
    let partOfSpeech: String?

    init(span: TextSpan, readingKana: String?, lemmaCandidates: [String] = [], partOfSpeech: String? = nil) {
        self.span = span
        self.readingKana = readingKana
        self.lemmaCandidates = lemmaCandidates
        self.partOfSpeech = partOfSpeech
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(span)
        hasher.combine(readingKana ?? "")
        hasher.combine(lemmaCandidates.count)
        for lemma in lemmaCandidates {
            hasher.combine(lemma)
        }
        hasher.combine(partOfSpeech ?? "")
    }
}

