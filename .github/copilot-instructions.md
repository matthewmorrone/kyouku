# Copilot instructions (kyouku)

## Big picture
- SwiftUI tab app. Entry points: `kyouku/KyoukuApp.swift` + `kyouku/ContentView.swift` with routing via `AppRouter` (`kyouku/AppRouter.swift`).
- App state is owned at the root as `@StateObject` stores and injected via `@EnvironmentObject`: `NotesStore`, `WordsStore`, `ReadingOverridesStore`, `TokenBoundariesStore`.

## Furigana + token pipeline (performance-sensitive)
- Orchestrator: `FuriganaPipelineService.render(...)` (`kyouku/FuriganaPipelineService.swift`). It skips work unless spans are needed.
- `PasteView` intentionally keeps span consumers “on” (`tokenSpansAlwaysOn = true`) so selection/merge/split stays functional even when furigana is hidden (`kyouku/PasteView.swift`).
- Stage 1 segmentation: `SegmentationService` actor over an in-memory JMdict trie (`kyouku/SegmentationService.swift`, `kyouku/LexiconProvider.swift`, `kyouku/LexiconTrie.swift`). Avoid touching SQLite after trie bootstrap.
- Stage 2 reading attachment: `SpanReadingAttacher` (MeCab/IPADic via `Mecab_Swift` + `IPADic`) + dictionary-based overrides (`kyouku/SpanReadingAttacher.swift`, `kyouku/ReadingOverridePolicy.swift`).
- Ruby projection/rendering: `FuriganaAttributedTextBuilder` + `FuriganaRubyProjector` + `RubyText` using `NSAttributedString.Key.rubyAnnotation` (`kyouku/FuriganaAttributedTextBuilder.swift`, `kyouku/FuriganaRubyProjector.swift`, `kyouku/RubyText.swift`).

## Dictionary + persistence
- Dictionary lookups: `DictionaryLookupViewModel.load(...)` → `DictionarySQLiteStore.shared.lookup(...)` (actor) (`kyouku/DictionaryLookupViewModel.swift`, `kyouku/DictionaryEntry.swift`).
- Bundled DB must be `dictionary.sqlite3` in the app bundle (`DictionarySQLiteError.resourceNotFound`).
- On-device user data is JSON in Documents:
  - notes: `notes.json` (`kyouku/NotesStore.swift`)
  - saved words: `words.json` (`kyouku/WordsStore.swift`)
  - reading overrides: `reading-overrides.json` (`kyouku/ReadingOverridesStore.swift`)
  - custom token spans: `token-spans.json` (`kyouku/TokenBoundariesStore.swift`)
- Import/export uses `AppDataBackup` (Settings flow) and is separate from the per-store files (`kyouku/AppDataBackup.swift`, `kyouku/SettingsView.swift`).

## Text/range conventions (critical)
- Ranges are `NSRange` in UTF-16 code units. Prefer `NSString` and `rangeOfComposedCharacterSequence(at:)`; do not index by `String.count`.

## Token selection UI
- Token selection state lives in `TokenSelectionController`; the action surface is `TokenActionPanel` (`kyouku/TokenSelectionController.swift`, `kyouku/TokenActionPanel.swift`).
- If you touch panel sizing/geometry, read `docs/TokenActionPanelGeometry.md` first.

## Dev workflows + diagnostics
- Primary workflow: build/run in Xcode. VS Code tasks wrap scripts:
  - Simulator: `bash scripts/sim-run.sh` (env: `SIM_NAME`, `SCHEME`, `CONF`, `DERIVED_DATA_PATH`, `RUBY_TRACE=1`).
  - Device: `bash scripts/device-run.sh` (env: `DEVICE_UDID`/`DEVICE_NAME`, `SCHEME`, `CONF`, `DERIVED_DATA_PATH`).
- Logging toggles: `DiagnosticsLogging` areas via `UserDefaults`/env vars like `DiagnosticsLogging.furigana=1` (`kyouku/Logging.swift`). `RUBY_TRACE=1` enables `DiagnosticsLogging.furiganaRubyTrace=1` in the simulator script.
- Tests are XCTest in `kyoukuTests/` (notably `SpanReadingAttacherTests`, `FuriganaPipelineServiceTests`, `TextRangeTests`).

## Updating the dictionary DB
- `generate-db.py` builds `kyouku/dictionary.sqlite3` from `jmdict-eng-3.6.1.json`; ensure Xcode bundles the updated DB.
