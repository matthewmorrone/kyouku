# Backlog

## Known bugs
- [ ] Spacing on the left edge for ruby persistent overhang
- [ ] Distribute spacing better for multikanji ruby headwords 
- [ ] when combining or splitting words, dictionary popup shows no result until refreshed

## Dictionary issues
- [x] wouldn't it make more sense if example sentences were grouped by meaning/sense used?
- [x] in the example sentences, the corresponding English word should be highlighted too
- [x] leverage embeddings in deciding whether to include example sentences, shouldn’t just be by string matching 
- [x] lots of redundancy on word detail view
- [ ] deduplicate example sentences
- [ ] custom reading popup should be prefilled and set to japanese keyboard
- [ ] provide meaning of verbs in the form they surface in 

## Performance / UX issues
- [ ] Make saving to the words list more responsive 
- [ ] Clicking the star button doesn’t always trigger bookmarking, but the bookmark button always does
- [ ] typing freely in english in the paste area is super laggy

## Ideas
- [ ] Add advanced dictionary filters/sorting to search UI
    (JLPT/POS/frequency/commonness toggles, etc.)
    Why easy: search/view model is already centralized and mode-driven, so adding more query options is mostly incremental UI + query plumbing.

- [ ] Add a dedicated kanji-discovery tab/screen shell
    (navigation surface first, feature depth later)
    Why relatively easy: app already uses a clean tab router, so adding a new tab is structurally straightforward even before full kanji features are complete.

- [ ] Improve search UX from manual-first toward more instant parsing behavior
    Why medium: README explicitly describes manual lookup as intentional, so this requires product-direction changes plus interaction design updates, not just a small patch.

- [ ] Upgrade study mode to real SRS scheduling
    (due dates/intervals/ease/FSRS-like logic)
    Why medium-hard: persistence layer currently tracks counts/accuracy and “wrong” status, but no schedule engine, so you’d need schema + algorithm + UI changes.

- [ ] Add full kanji metadata support
(radicals, readings metadata, etc.)
    Why hard: docs indicate this data is not yet a committed runtime dataset, so there’s ingestion + schema + attribution + UI work.

- [ ] Add handwriting input for kanji lookup
    Why hard: explicitly still a backlog idea and typically requires custom recognition integration or a robust third-party pipeline + UX tuning.

- [ ] Add native human audio pronunciation dataset support
(beyond TTS)
    Why hardest: currently pronunciation is TTS call path; moving to lexical recordings means sourcing/licensing large audio datasets, indexing, storage, and fallback logic.
- [x] add option to change displayed font for Japanese
- [x] add a toggle for distinguishing kanji, hiragana and katakana (maybe with font?)
- [x] add a toggle for highlighting distinct parts of speech
- [ ] quiz on next and previous words/lines
- [ ] Romaji 
- [ ] List conjugations
- [ ] Spaced repetition for flashcards
- [ ] Auto clipboard paste/search
- [x] Check if OCR is built in to iOS
- [ ] Kanji data
- [ ] Handwriting input and kanji stroke order 
- [ ] kanji of the day feature with pretty images
- [ ] Implement the action plan in `docs/KaraokeAlignmentImprovements.md`
docs/KaraokeAlignmentImprovements.md for Higher-quality, more granular karaoke alignment improvements
