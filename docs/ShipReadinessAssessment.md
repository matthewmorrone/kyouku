# Ship Readiness Assessment (External Release)

This version is based on **code inspection only** (not backlog claims). It focuses on what is currently observable in source.

## Overall verdict

The app has strong functionality, but there are still several externally visible polish/release-hardening gaps before broad release.

## Code-observed findings (specific)

### 1) Debug/diagnostic controls are exposed in the main Settings UI (P0)
- `SettingsView` includes a visible `Section("Debug")` in the primary Settings form.
- That section exposes end-user toggles such as:
  - "Disable dictionary popup"
  - "Drag words to move them"
  - "View metrics"
  - "Pixel ruler overlay"
  - plus rendering instrumentation toggles for boundaries/bisectors/line bands.
- For external users, this adds noise and makes the product feel unfinished.

### 2) Backup import appears destructive without pre-confirmation/preflight (P0)
- In `handleBackupImport`, successful import immediately calls:
  - `wordsStore.replaceAll(with: backup.words)`
  - `notesStore.replaceAll(with: backup.notes)`
  - `readingOverrides.replaceAll(with: backup.readingOverrides)`
- A summary is shown *after* replacement, but there is no explicit pre-import confirmation step describing destructive impact before data replacement.
- This is a trust/polish risk for real users.

### 3) No visible UI test target for end-to-end app flows (P0)
- The Xcode project file shows native targets for app + unit tests (`kyouku`, `kyoukuTests`).
- Repository test files are XCTest unit tests (logic/pipeline focused), and there are no visible UI test files (e.g., `XCUIApplication`-driven flows).
- For external shipping quality, key journeys should have at least smoke-level UI automation.

### 4) Settings information architecture is dense for first-time users (P1)
- `SettingsView` currently presents many advanced controls in a single primary form hierarchy.
- Typography/ruby tuning, diagnostics, notification config, and backup controls are all adjacent in the same top-level structure.
- This likely increases cognitive load for new users and weakens first-impression polish.

### 5) Dictionary detail rendering is feature-rich but visually heavy (P1)
- `WordDefinitionsViewFullEntries` composes many stacked sections (`Entry`, `Forms`, `Pitch Accent`, `Senses`) with dense metadata.
- Without stronger progressive disclosure/default collapsing, this can feel “expert-mode by default” for casual users.
- The content quality is strong; this is primarily a presentation/polish concern.

---

## Prioritized ship list

### Priority 0 — before external release
1. Hide/gate debug section and diagnostic toggles from release builds.
2. Add explicit pre-import confirmation + preflight summary for backup restore.
3. Add UI smoke tests for core user loop (notes, lookup/save, study, backup import/export).

### Priority 1 — high-impact polish
4. Split Settings into "Basic" vs "Advanced" (or move advanced controls behind a secondary screen).
5. Apply progressive disclosure in dictionary detail UI to reduce first-pass cognitive load.

### Priority 2 — market-readiness hardening
6. Run an accessibility pass (VoiceOver labels, Dynamic Type scaling behavior, contrast).
7. Prepare App Store packaging artifacts and release QA checklist.

---

## Launch gate checklist (concise)

- [ ] No debug-only controls are visible in release settings.
- [ ] Backup import shows explicit destructive-impact confirmation before replacing data.
- [ ] Core user loop is covered by UI smoke tests.
- [ ] Settings top-level is beginner-friendly (advanced controls moved out of default path).
- [ ] Accessibility baseline validated.
- [ ] App Store submission artifacts complete.
