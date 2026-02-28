# Higher-quality, more granular karaoke alignment improvements

This plan focuses on improving two outcomes:
1. **Accuracy** (better timestamp placement for each lyric unit).
2. **Granularity** (moving from line-level timing to phrase/word/subword timing when possible).

## Current state (baseline)
- The aligner uses on-device speech recognition when available and falls back to line interpolation if recognition fails.
- Matching currently normalizes text and performs ordered substring matching from a moving cursor.
- Missing anchors are interpolated linearly between neighboring matched lines.

## Priority roadmap

### 1) Add phrase-level and token-level output tiers
**What to build**
- Extend the alignment model with optional nested segments:
  - line segments (existing)
  - phrase segments (split by punctuation / pause heuristics)
  - token segments (word or morpheme units)
- Keep line-level output for compatibility while adding richer optional tiers.

**Why it helps**
- UI can highlight at finer granularity without regressing existing rendering paths.
- Low-confidence regions can gracefully degrade to line-level while high-confidence regions show token highlighting.

**How to implement**
- Add `granularity` metadata and child ranges in `KaraokeAlignmentSegment` or a parallel structure.
- Start with token segmentation from existing tokenizer outputs (or MeCab where available) and map recognition spans to tokens.

**Acceptance checks**
- Alignment JSON remains backward-compatible for existing notes.
- New test fixture verifies token-level timestamps are monotonic and stay inside parent line bounds.

### 2) Replace strict substring search with robust sequence alignment
**What to build**
- Replace ordered `range(of:)` matching with dynamic programming alignment (Needleman-Wunsch / Smith-Waterman variant) over lyric tokens vs recognized tokens.
- Include insertion/deletion/substitution penalties and confidence-weighted costs.

**Why it helps**
- More resilient to ASR drift, repeated choruses, dropped particles, and small wording differences.
- Avoids failures when a line appears twice or when recognition emits bridge/filler content.

**How to implement**
- Build token arrays after normalization.
- Score matches using normalized text similarity + temporal continuity priors.
- Backtrack alignment path to derive anchors per lyric token and then aggregate upward.

**Acceptance checks**
- Add fixtures with repeated lines and minor lyric/ASR mismatches.
- Verify anchor recall and median absolute timing error improve over baseline.

### 3) Confidence-aware temporal smoothing and boundary constraints
**What to build**
- Run a second pass that smooths start/end times with constraints:
  - monotonic non-overlapping segments
  - minimum/maximum duration by token length
  - continuity penalty for sudden jumps
- Weight smoothing strength by confidence.

**Why it helps**
- Removes jitter and unrealistic short segments without flattening high-confidence anchors.
- Produces more stable karaoke playback highlights.

**How to implement**
- Use constrained optimization / Viterbi-style pass over candidate boundaries.
- Derive duration priors from character count, mora count, or empirical speech rate.

**Acceptance checks**
- No segment end before start, and no out-of-order segments.
- 95th-percentile boundary jump reduced on noisy clips.

### 4) Better fallback than uniform interpolation
**What to build**
- When recognition is partial, interpolate missing regions with **content-aware duration priors** instead of equal splits.
- Estimate duration weights from line length, punctuation, and known tempo/silence cues from audio energy.

**Why it helps**
- Even fallback output feels aligned to lyrical rhythm instead of mechanically uniform spacing.

**How to implement**
- Compute weights per unresolved lyric unit.
- Distribute available time proportionally to weights.
- Use simple energy-based pause detection to reserve longer gaps at likely line breaks.

**Acceptance checks**
- On no-ASR or sparse-ASR cases, weighted interpolation beats uniform interpolation in manual MOS review.

### 5) Instrumentation + evaluation harness
**What to build**
- Add offline evaluation scripts and a gold dataset of short clips with human-annotated boundaries.
- Track metrics per locale and song style.

**Why it helps**
- Prevents regressions and makes algorithm work data-driven.

**Core metrics**
- Boundary MAE (ms)
- Coverage (% lyric units with non-fallback anchors)
- Confidence calibration (ECE/Brier)
- UX metric: seek-to-highlight lag/jitter during playback

**Acceptance checks**
- CI job that runs alignment benchmarks and publishes trend summaries.
- Ship gates tied to metric thresholds.

## Near-term execution plan (2–3 iterations)
1. **Iteration A**: introduce token data model + evaluation harness + fixtures.
2. **Iteration B**: implement DP sequence aligner and compare against current baseline.
3. **Iteration C**: add temporal smoothing + weighted fallback interpolation.

## Practical implementation notes
- Keep the current on-device recognizer path as default for privacy and latency.
- Store strategy and algorithm version in saved alignment payloads for migration/debugging.
- Add debug overlays in dev builds to visualize recognized tokens, matched tokens, and final boundaries.

## Suggested backlog tasks
- [x] Add alignment payload versioning and granularity metadata.
- [x] Add tokenized lyric representation and per-token range mapping.
- [x] Implement DP matcher with confidence-weighted costs.
- [x] Add constrained smoothing pass.
- [x] Add weighted fallback interpolation using text/audio priors.
- [ ] Expand benchmark dataset and add CI evaluation job.
