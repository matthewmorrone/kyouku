# Copilot instructions (kyouku)

## Scope
SwiftUI tab-based iOS app. App state is owned at the root and injected via `@EnvironmentObject`.

## Critical invariants

### Text / range rules (NON-NEGOTIABLE)
- All text ranges are `NSRange` in **UTF-16 code units**.
- Prefer `NSString` APIs.
- Use `rangeOfComposedCharacterSequence(at:)`.
- Do NOT index by `String.count`.

### Furigana rendering (performance-sensitive)
- Main entry point: `FuriganaPipelineService.render(...)`.
- Avoid unnecessary work during rendering.
- Do NOT touch SQLite during render paths unless explicitly required.

## Command execution rules (STRICT)

### Allowed
- Non-build shell commands: `ls`, `rg`, `sed`, `awk`, `cat`, `python`
- Non-destructive git commands: `bisect`, `diff`, `grep`, `log`, `show`, `status`, `branch list`, `fetch`, `pull`
- Destructive git commands with explicit permission: `branch delete`, `add`, `commit`, `merge`, `rebase`, `switch`, `push`
- Build-only verification:
  - `xcodebuild build`
  - Preferred:
    ```
    xcodebuild -project kyouku.xcodeproj -scheme kyouku -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    ```

### Forbidden
- Tests of any kind (`xcodebuild test`, `swift test`, XCTest)
- `swift build`
- Simulator or device install / launch flows
- Release or App Store signing flows
- Changing signing or provisioning settings
- Long-lived simulator or device sessions

## Change policy (NO legacy by default)
- When removing, renaming, or upgrading features/settings, do **not** add backwards compatibility layers.
- Avoid migrations, legacy fallbacks, version-gated behavior, deprecated aliases, or “keep old keys working” glue.
- Prefer a clean break: update call sites and delete old code/keys.
- Only implement compatibility/versioning if the user explicitly requests it.

## References (read only when relevant)
- Furigana pipeline details: `docs/FuriganaPipeline.md`
- Token panel geometry rules: `docs/TokenActionPanelGeometry.md`
- Build / iteration workflow: `docs/CopilotWorkflow.md`
- Release checklist: `docs/ReleaseGoals.md`