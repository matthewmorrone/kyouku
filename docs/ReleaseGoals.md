# Release Goals (Stop-Iterating Criteria)

Use this list to decide when Kyouku is “done enough” for the current iteration. Each goal should be marked **Done**, **Deferred**, or **Won’t fix** with a short rationale.

## 1) Core workflow is stable
**Goal:** The four-tab flow works end-to-end without data loss or confusion.

- Paste → New Note → Dictionary lookup → Save Word → Cards review completes without crashes.
- Notes and Words persist across app restarts.

## 2) Known bugs resolved or deferred
**Goal:** No open “Known bugs” that affect core usage.

- Every item in `docs/Backlog.md` “Known bugs” is either fixed or explicitly deferred with a reason.

## 3) UX / performance rough edges addressed
**Goal:** Smooth, predictable interactions for the main flows.

- Every item in “Performance / UX issues” is fixed or deferred with a reason.
- Cards animations are acceptable (or removed if still janky).

## 4) Furigana / tokenization output acceptable
**Goal:** Tokenization issues are limited to edge cases that don’t distract daily use.

- High-severity items in “Furigana / tokenization issues” are fixed or deferred with a reason.
- At least one known limitation is documented in release notes.

## 5) Dictionary usability meets minimum bar
**Goal:** Saved words are useful without confusion.

- “Useful dictionary page for words” is implemented or deferred with a reason.
- Same-pronunciation/other-kanji confusion is addressed or deferred.

---

## Suggested Milestones

### Milestone A (MVP Freeze)
- Goal 1 complete.
- Goal 2 complete.
- At least one item in Goal 5 completed.

### Milestone B (Quality Bar)
- Goal 3 complete.
- Goal 4 complete.
