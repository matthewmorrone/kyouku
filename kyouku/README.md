# Kyouku — Functional Overview & Architecture


please check this diff for anything worth keeping. first thing that comes to mind is centralized logging with easily configurable switches

please review this previous commit for features that were previously implemented but no longer present. word of the day notifications is one feature

## Purpose

Kyouku is an iOS app for light-weight Japanese study. It lets users paste arbitrary text, keep quick notes, perform manual dictionary lookups, and run spaced repetition style drills on saved vocabulary. The experience is intentionally simple: no automatic parsing, no inline annotation toggles, and no background text processors to babysit.

## User-Facing Tabs

### Paste
- Single text editor driven by `PasteView` with optional font sizing via `AppStorage`.
- One-tap clipboard import and a button that sends the current text to `NotesStore` as a new note.

### Notes
- `NotesView` lists every saved note (title = first line, subtitle = timestamp) and supports deletion.
- Notes persist through `NotesStore`, which serializes `Note` structs to `AppDataBackup` for iCloud-friendly storage.

### Dictionary
- Powered by `DictionaryLookupViewModel` + `DictionarySQLiteStore` actor hitting the bundled `dictionary.sqlite3`.
- Users type any surface form, see canonical headwords, kana spellings, and glosses, then save them to `WordsStore`.

### Cards
- `FlashcardsView` cycles through the words saved in `WordsStore`, tracks correct/incorrect taps, and records aggregates with `ReviewPersistence`.

## Data & Persistence

- `NotesStore` — JSON-backed list of `Note` models.
- `WordsStore` — JSON-backed list of `Word` models (`surface`, `kana`, `meaning`, `createdAt`).
- `ReviewPersistence` — stores streaks/counters for the flashcard session summary.
- `DictionarySQLiteStore` — swift actor guaranteeing serialized access to the JMdict-derived `dictionary.sqlite3`, which contains `entries`, `senses`, `kana_forms`, and lookup indexes.

## Architecture Notes

- All tabs share a single `AppRouter` enum and are presented via `ContentView`.
- Environment data flows through `@StateObject` stores placed at the root of each tab.
- No background parsing services or automation loops remain; the user performs every dictionary lookup manually.

## Typical Workflow

1. Paste or type Japanese text in the Paste tab.
2. Tap "New Note" to archive the text.
3. Jump to Dictionary, search for interesting vocabulary, and store entries.
4. Use the Cards tab to quiz against the saved word list.
5. Repeat, optionally trimming saved notes/words as you go.

## To Do
- Noticeable delay for furigana to appear when first loading the app
- Noticeable delay when loading a note
- Extreme left and top furigana are cut off in the paste area
- 瞬き shows with まばた above 瞬
- にじしょく for 虹色: jisho disagrees
- いだ for 抱
- わたしま for 私待: correct, but 私 isn't properly centered

## Ideas
+ add a toggle for highlighting distinct parts of speech
+ add a toggle for distinguishing kanji, hiragana and katakana
