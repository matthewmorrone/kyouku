# Remaining Changes Scratch Report (Behavioral)

Date: 2026-02-28
Baseline for comparison: `origin/main`

## What this report is

This is the **functional summary** of what is still different in the branch after porting all non-suspect changes.

Only 15 files remain, and all 15 are in the segmentation/reading/paste interaction surface.

## High-level themes in the remaining delta

1. **Boundary policy and suffix/particle handling changes are not yet ported**
	 - affects where tokens split/merge
2. **Reading attachment fallback logic is not yet ported**
	 - affects which reading gets attached when primary paths fail
3. **Paste editor orchestration is still on older behavior**
	 - includes recompute/reuse paths and toolbar/control integration around segmentation state
4. **Overlay rendering/geometry differences remain**
	 - can change perceived segmentation (selection/line split behavior) even when core spans are similar

## File-by-file: what origin/main has that is still missing here

### Core segmentation + boundary rules

- `kyouku/DeinflectionHardStopMerger.swift`
	- New/expanded hard-stop boundary rules for deinflection merge decisions.
	- Risk impact: directly changes merge/split boundaries around particle/ending patterns.

- `kyouku/LexiconSuffixSplitter.swift`
	- Contextual suffix splitting refinements and related guard logic.
	- Risk impact: changes suffix segmentation outcomes for ambiguous surfaces.

- `kyouku/MeCabTokenBoundaryNormalizer.swift`
	- Boundary normalization updates (including newer rule-path cleanup and guards).
	- Risk impact: alters final normalized token boundaries from raw MeCab output.

- `kyouku/SegmentationService.swift`
	- Multiple logic updates across segmentation passes (not just cosmetic).
	- Risk impact: central tokenization/segmentation behavior shifts.

- `kyouku/SelectionSpanResolver.swift`
	- Small but direct resolver changes for span selection mapping.
	- Risk impact: user-selected ranges may resolve to different semantic spans.

### Reading attachment pipeline

- `kyouku/SpanReadingAttacher.swift`
	- Large behavior delta in reading assignment/attachment path.
	- Includes newer fallback/priority handling in origin/main.
	- Risk impact: reading choice and span grouping can differ substantially.

- `kyouku/SpanReadingAttacherInternals.swift`
	- Internal helper/refactor delta backing the attacher behavior above.
	- Risk impact: subtle rule precedence/heuristic behavior changes.

- `kyouku/FuriganaPipelineService.swift`
	- Pipeline orchestration changes (render pass structure + diagnostics/guards/tail behavior differences).
	- Risk impact: upstream/downstream span transformations can diverge from current branch.

- `kyouku/FuriganaAttributedTextBuilder.swift`
	- Ruby projection/assignment path differences (kanji reading fallback/logging and related handling).
	- Risk impact: attributed furigana output can differ even with similar base spans.

### Paste editor integration surface

- `kyouku/PasteView.swift`
	- Largest remaining delta.
	- Combines segmentation refresh orchestration with paste/karaoke wiring differences.
	- Risk impact: highest for reintroducing regression because this is the runtime integration hub.

- `kyouku/PasteViewControlsBar.swift`
	- Control bar integration differences tied to reset/segmentation-related actions.
	- Risk impact: can invoke different reset/recompute paths.

- `kyouku/PasteViewEditorColumn.swift`
	- Editor column plumbing differences for control callbacks/state propagation.
	- Risk impact: can route user actions to different segmentation refresh behaviors.

- `kyouku/PasteViewTokenEditing.swift`
	- Small but meaningful token-edit path differences.
	- Risk impact: edits may persist/apply boundary overrides differently.

- `kyouku/PasteViewToolbar.swift`
	- Toolbar behavior/context menu wiring differences around paste/karaoke/reset UX.
	- Risk impact: may alter which codepaths are reachable in normal usage.

### Overlay rendering/interaction

- `kyouku/TokenOverlayTextView.swift`
	- Geometry/selection/render invariant differences.
	- Risk impact: can present token splits differently and affect interactive selection boundaries.

## Why these are still withheld

These are exactly the files most likely to reintroduce the segmentation regression, based on:

- direct boundary policy deltas,
- reading attachment fallback deltas,
- large integration delta in `PasteView`, and
- overlay behavior changes affecting segmentation perception.

## Practical port guidance (next phase)

If we continue porting, safest order is:

1. Smallest rule files first:
	 - `SelectionSpanResolver` → `MeCabTokenBoundaryNormalizer` → `LexiconSuffixSplitter` → `DeinflectionHardStopMerger`
2. Then reading internals:
	 - `SpanReadingAttacherInternals` → `SpanReadingAttacher`
3. Then orchestration:
	 - `FuriganaPipelineService` → `FuriganaAttributedTextBuilder`
4. Paste/overlay last:
	 - `PasteView*` files + `TokenOverlayTextView`

Re-test segmentation behavior after each step.
