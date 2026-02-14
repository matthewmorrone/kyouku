# Copilot extended context (kyouku)

## Big picture
- SwiftUI tab app. Entry points: `kyouku/KyoukuApp.swift` + `kyouku/ContentView.swift` with routing via `AppRouter` (`kyouku/AppRouter.swift`).
- App state is owned at the root as `@StateObject` stores and injected via `@EnvironmentObject`: `NotesStore`, `WordsStore`, `ReadingOverridesStore`, `TokenBoundariesStore`.

## Furigana + token pipeline (performance-sensitive)
- Orchestrator: `FuriganaPipelineService.render(...)` (`kyouku/FuriganaPipelineService.swift`). It skips work unless spans are needed.
- `PasteView` intentionally keeps span consumers “on” (`tokenSpansAlwaysOn = true`) so selection/merge/split stays functional even when furigana is hidden (`kyouku/PasteView.swift`).
- Stage 1 segmentation: `SegmentationService` actor over an in-memory JMdict trie (`kyouku/SegmentationService.swift`, `kyouku/LexiconProvider.swift`, `kyouku/LexiconTrie.swift`). Avoid touching SQLite after trie bootstrap.
- Stage 2 reading attachment: `SpanReadingAttacher` (MeCab/IPADic via `Mecab_Swift` + `IPADic`) + dictionary-based overrides (`kyouku/SpanReadingAttacher.swift`, `kyouku/ReadingOverridePolicy.swift`).
- Ruby projection/rendering: `FuriganaAttributedTextBuilder` + `FuriganaRubyProjector` + `RubyText` using `NSAttributedString.Key.rubyAnnotation`
  (`kyouku/FuriganaAttributedTextBuilder.swift`, `kyouku/FuriganaRubyProjector.swift`, `kyouku/RubyText.swift`).

## Text layout + spacing invariants (ruby/headword)
- IMPORTANT (non-negotiable):
  - Headwords and ruby must always be aligned.
  - Segments must never be split across visual lines (avoid duplicating ruby/headword across wraps).
  - With headword padding enabled, headwords and ruby must not overflow across the left/right inset guides.
- All ranges are **source UTF-16 `NSRange`**; any display-only padding must not invalidate source indexing.
- Headword padding (when enabled) is implemented via **display-only** width spacers (U+FFFC) so ruby/headword alignment stays stable.
  - Do not treat U+FFFC as real source text; prefer “ink ranges” (visible glyph bounds) for geometry.
- Ruby readings must stay anchored to the **ink-only** headword bounds (not whitespace/punctuation/spacers).
- Punctuation/symbols are hard boundaries for “word identity”:
  - Do not propagate ruby attributes onto trailing punctuation.
  - Avoid merging/expanding headword spans across punctuation/symbol-only glyphs.
- `TokenOverlayTextView` renders ruby as persistent **content-space** overlay layers; debug overlays should also be content-space.

## Dictionary + persistence
- Dictionary lookups: `DictionaryLookupViewModel.load(...)` → `DictionarySQLiteStore.shared.lookup(...)` (actor)
  (`kyouku/DictionaryLookupViewModel.swift`, `kyouku/DictionaryEntry.swift`).
- Bundled DB must be `dictionary.sqlite3` in the app bundle (`DictionarySQLiteError.resourceNotFound`).
- On-device user data (JSON in Documents):
  - `notes.json` (`NotesStore`)
  - `words.json` (`WordsStore`)
  - `reading-overrides.json` (`ReadingOverridesStore`)
  - `token-spans.json` (`TokenBoundariesStore`)
- Import/export uses `AppDataBackup` and is separate from per-store files.

## Token selection UI
- Token selection state lives in `TokenSelectionController`.
- Action surface is `TokenActionPanel`.
- If modifying sizing or geometry, read `docs/TokenActionPanelGeometry.md` first.

## Dev workflows + diagnostics

### Build policy
- Run **build-only verification** after completing a batch of code changes.
- Do NOT run builds for read-only or investigative work.
- For a batch of edits, run `xcodebuild` once at the end.
- Iterate only if the build fails.

### Constraints
- Build only (no tests).
- No install or launch flows.
- Builds are for surfacing compiler errors and warnings.

### Human workflows
- Primary workflow is Xcode.
- VS Code tasks wrap scripts:
  - Simulator: `scripts/sim-run.sh`
  - Device: `scripts/device-run.sh`

### Logging
- Diagnostics toggled via `UserDefaults` / env vars (`DiagnosticsLogging.*`).
- `RUBY_TRACE=1` enables furigana ruby trace logging.

### Tests
- XCTest lives in `kyoukuTests/`:
  - `SpanReadingAttacherTests`
  - `FuriganaPipelineServiceTests`
  - `TextRangeTests`

## Updating the dictionary DB
- `scripts/generate_db.py` builds `dictionary.sqlite3` from `jmdict-eng-*.json`.
- Bundled DB path: `kyouku/Resources/dictionary.sqlite3`.

## Release goals
- Canonical checklist lives in `docs/ReleaseGoals.md`.
- Align backlog items with goal status before finalizing work.